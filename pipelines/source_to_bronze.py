#!/usr/bin/env python3


from __future__ import annotations

import hashlib
import json
import os
import sys
import uuid
from datetime import date, datetime, time
from decimal import Decimal
from typing import Any

from sqlalchemy import (
    Column,
    MetaData,
    Table,
    create_engine,
    inspect,
    select,
    text,
)
from sqlalchemy.engine import Engine
from sqlalchemy.sql.sqltypes import NullType
from sqlalchemy.exc import SQLAlchemyError
from urllib.parse import quote_plus


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

DB_HOST = os.getenv("DB_HOST", "localhost")
DB_PORT = os.getenv("DB_PORT", "3306")
DB_USER = os.getenv("DB_USER", "root")
DB_PASSWORD = os.getenv("DB_PASSWORD", "root")
DB_CRM_NAME = os.getenv("DB_CRM_NAME", "crm")
DB_CIF_NAME = os.getenv("DB_CIF_NAME", "cif")
DB_BRONZE_NAME = os.getenv("DB_BRONZE_NAME", "bronze")

BATCH_SIZE = int(os.getenv("BATCH_SIZE", "1000"))


def creer_engine(nom_base: str) -> Engine:
    """Crée un moteur SQLAlchemy vers une base MariaDB/MySQL."""
    mot_de_passe = quote_plus(DB_PASSWORD)
    url = (
        f"mysql+pymysql://{DB_USER}:{mot_de_passe}"
        f"@{DB_HOST}:{DB_PORT}/{nom_base}?charset=utf8mb4"
    )
    return create_engine(
        url,
        pool_pre_ping=True,
        future=True,
    )


def normaliser_valeur(valeur: Any) -> Any:
    """Convertit les types Python en valeurs sérialisables de manière stable."""
    if valeur is None:
        return None
    if isinstance(valeur, (datetime, date, time)):
        return valeur.isoformat()
    if isinstance(valeur, Decimal):
        return str(valeur)
    if isinstance(valeur, bytes):
        return {"__bytes__": valeur.hex()}
    if isinstance(valeur, (str, int, float, bool)):
        return valeur
    return str(valeur)


def calculer_hash(ligne: dict[str, Any], colonnes: list[str]) -> str:
    """Calcule une empreinte stable de 16 caractères pour une ligne source."""
    donnees = {nom: normaliser_valeur(ligne.get(nom)) for nom in colonnes}
    contenu = json.dumps(
        donnees,
        sort_keys=True,
        ensure_ascii=False,
        separators=(",", ":"),
    )
    return hashlib.sha256(contenu.encode("utf-8")).hexdigest()[:16]


def creer_table_cible(
    engine_source: Engine,
    engine_bronze: Engine,
    table_source: str,
    table_cible: str,
    source_system: str,
) -> Table:
    """Crée la table cible si nécessaire, en reprenant les colonnes source."""
    inspecteur = inspect(engine_source)
    colonnes_source = inspecteur.get_columns(table_source)
    cles_primaires = inspecteur.get_pk_constraint(table_source).get(
        "constrained_columns"
    ) or []

    metadata = MetaData()
    colonnes_cibles = []

    for info in colonnes_source:
        nom = info["name"]
        type_sql = info["type"]

        # Un type SQLAlchemy NullType ne peut pas être utilisé pour créer une table.
        if isinstance(type_sql, NullType):
            type_sql = type_sql.copy()

        options = {
            "nullable": info.get("nullable", True),
        }
        if nom in cles_primaires:
            options["primary_key"] = True

        # Conserver les valeurs par défaut côté serveur uniquement lorsque
        # SQLAlchemy a pu les refléter sans ambiguïté n'est pas garanti.
        colonnes_cibles.append(Column(nom, type_sql, **options))

    colonnes_cibles.extend(
        [
            Column("_batch_id", __import__("sqlalchemy").String(20), nullable=False),
            Column(
                "_source_system",
                __import__("sqlalchemy").String(20),
                nullable=False,
                server_default=f"'{source_system}'",
            ),
            Column(
                "_ingested_at",
                __import__("sqlalchemy").DateTime(),
                nullable=False,
                server_default=text("CURRENT_TIMESTAMP"),
            ),
            Column("_row_hash", __import__("sqlalchemy").String(16), nullable=False),
        ]
    )

    table = Table(table_cible, metadata, *colonnes_cibles)
    metadata.create_all(engine_bronze, tables=[table], checkfirst=True)

    # Si la table existait déjà, vérifier qu'elle possède les colonnes techniques.
    colonnes_existantes = {
        col["name"] for col in inspect(engine_bronze).get_columns(table_cible)
    }
    colonnes_techniques = {
        "_batch_id",
        "_source_system",
        "_ingested_at",
        "_row_hash",
    }
    manquantes = colonnes_techniques - colonnes_existantes
    if manquantes:
        raise RuntimeError(
            f"La table cible '{table_cible}' existe déjà mais ne possède pas "
            f"les colonnes techniques : {', '.join(sorted(manquantes))}. "
            "Ajoutez-les ou renommez/supprimez la table avant de relancer."
        )

    return table


def ingerer_table(
    engine_source: Engine,
    engine_bronze: Engine,
    table_source: str,
    prefixe_cible: str,
    source_system: str,
    batch_id: str,
) -> int:
    """Ingère une table source par lots et retourne le nombre de lignes lues."""
    table_cible_nom = f"{prefixe_cible}_{table_source}"
    table_cible = creer_table_cible(
        engine_source=engine_source,
        engine_bronze=engine_bronze,
        table_source=table_source,
        table_cible=table_cible_nom,
        source_system=source_system,
    )

    colonnes_source = [
        col["name"] for col in inspect(engine_source).get_columns(table_source)
    ]
    nb_lignes = 0

    with engine_source.connect() as connexion_source:
        requete = select(text("*")).select_from(
            Table(table_source, MetaData(), autoload_with=engine_source)
        )
        resultat = connexion_source.execution_options(
            stream_results=True,
            yield_per=BATCH_SIZE,
        ).execute(requete)

        while True:
            lot = resultat.fetchmany(BATCH_SIZE)
            if not lot:
                break

            lignes_a_inserer = []
            for row in lot:
                ligne = dict(row._mapping)
                ligne["_batch_id"] = batch_id
                ligne["_source_system"] = source_system
                ligne["_ingested_at"] = datetime.now()
                ligne["_row_hash"] = calculer_hash(ligne, colonnes_source)
                lignes_a_inserer.append(ligne)

            if lignes_a_inserer:
                with engine_bronze.begin() as connexion_bronze:
                    connexion_bronze.execute(table_cible.insert(), lignes_a_inserer)
                nb_lignes += len(lignes_a_inserer)

    return nb_lignes


def lister_tables(engine: Engine) -> list[str]:
    """Retourne les tables utilisateur d'une base source."""
    return inspect(engine).get_table_names()


def ingerer_base(
    engine_source: Engine,
    engine_bronze: Engine,
    prefixe_cible: str,
    source_system: str,
    batch_id: str,
) -> list[dict[str, Any]]:
    """Ingère toutes les tables d'une base et retourne un journal d'exécution."""
    journal = []
    tables = lister_tables(engine_source)

    print(f"\nBase source : {source_system} — {len(tables)} table(s)")

    for nom_table in tables:
        debut = datetime.now()
        try:
            nb = ingerer_table(
                engine_source=engine_source,
                engine_bronze=engine_bronze,
                table_source=nom_table,
                prefixe_cible=prefixe_cible,
                source_system=source_system,
                batch_id=batch_id,
            )
            statut = "OK"
            erreur = None
            print(f"  [OK] {nom_table} -> {prefixe_cible}_{nom_table} : {nb} ligne(s)")
        except Exception as exc:
            nb = 0
            statut = "ERREUR"
            erreur = str(exc)
            print(f"  [ERREUR] {nom_table} : {exc}", file=sys.stderr)

        journal.append(
            {
                "source": source_system,
                "table_source": nom_table,
                "table_cible": f"{prefixe_cible}_{nom_table}",
                "lignes_ingerees": nb,
                "statut": statut,
                "erreur": erreur,
                "debut": debut,
                "fin": datetime.now(),
                "batch_id": batch_id,
            }
        )

    return journal


def main() -> int:
    """Point d'entrée du script."""
    batch_id = datetime.now().strftime("%Y%m%d%H%M%S") + uuid.uuid4().hex[:6]
    print(f"Début de l'ingestion — batch_id={batch_id}")

    engine_crm = creer_engine(DB_CRM_NAME)
    engine_cif = creer_engine(DB_CIF_NAME)
    engine_bronze = creer_engine(DB_BRONZE_NAME)

    try:
        # Vérifier les connexions avant de commencer.
        for nom, engine in (
            (DB_CRM_NAME, engine_crm),
            (DB_CIF_NAME, engine_cif),
            (DB_BRONZE_NAME, engine_bronze),
        ):
            with engine.connect() as connexion:
                connexion.execute(text("SELECT 1"))
            print(f"Connexion OK : {nom}")

        journal = []
        journal.extend(
            ingerer_base(
                engine_source=engine_crm,
                engine_bronze=engine_bronze,
                prefixe_cible="crm",
                source_system="crm",
                batch_id=batch_id,
            )
        )
        journal.extend(
            ingerer_base(
                engine_source=engine_cif,
                engine_bronze=engine_bronze,
                prefixe_cible="cif",
                source_system="cif",
                batch_id=batch_id,
            )
        )

        nb_ok = sum(1 for ligne in journal if ligne["statut"] == "OK")
        nb_erreurs = sum(1 for ligne in journal if ligne["statut"] == "ERREUR")
        total_lignes = sum(ligne["lignes_ingerees"] for ligne in journal)

        print("\n--- Résumé ---")
        print(f"Batch ID       : {batch_id}")
        print(f"Tables traitées: {len(journal)}")
        print(f"Tables OK      : {nb_ok}")
        print(f"Tables en erreur: {nb_erreurs}")
        print(f"Lignes ingérées: {total_lignes}")

        if nb_erreurs:
            print("\nCertaines tables n'ont pas été ingérées. Consultez les erreurs ci-dessus.")
            return 1
        return 0

    except SQLAlchemyError as exc:
        print(f"Erreur de connexion/base de données : {exc}", file=sys.stderr)
        return 2
    finally:
        engine_crm.dispose()
        engine_cif.dispose()
        engine_bronze.dispose()


if __name__ == "__main__":
    raise SystemExit(main())
