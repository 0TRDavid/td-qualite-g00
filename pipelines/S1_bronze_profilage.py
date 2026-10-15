# %% Paramètres et connexion
import sys
sys.path.append("../pipelines")          # notebook dans notebooks/ ; en terminal, le dossier pipelines/ est déjà dans le chemin
from aq import *                         # eng(), reader(), lire(), mesurer(), BATCH, DATE_REF... (voir pipelines/aq.py)

print("Lot :", BATCH, "| date de référence :", DATE_REF)
print(lire("SELECT VERSION() AS version, @@collation_server AS collation"))     # utf8mb4_nopad_bin : comparaisons exactes


# %% US-01 · Inventaire des sources cif et crm
# 1.1 Tables, colonnes et clé primaire, lues dans information_schema
cols = lire("""SELECT table_schema AS base, table_name AS `table`, COUNT(*) AS colonnes
               FROM information_schema.columns WHERE table_schema IN ('cif','crm') GROUP BY table_schema, table_name""")
cles = lire("""SELECT table_schema AS base, table_name AS `table`, GROUP_CONCAT(column_name ORDER BY ordinal_position) AS cle_primaire
               FROM information_schema.key_column_usage WHERE table_schema IN ('cif','crm') AND constraint_name = 'PRIMARY'
               GROUP BY table_schema, table_name""")
inventaire = cols.merge(cles, how="left", on=["base", "table"])
# 1.2 Comptage exact (table_rows d'information_schema n'est qu'une estimation) : une requête COUNT(*) par table
inventaire["lignes"] = [int(lire(f"SELECT COUNT(*) AS n FROM {b}.{t}").n[0]) for b, t in zip(inventaire.base, inventaire.table)]
print(inventaire.sort_values(["base", "table"]).to_string(index=False))
# 1.3 Tables sans clé primaire
print("\nTables sans clé primaire :", inventaire[inventaire.cle_primaire.isna()][["base", "table"]].values.tolist())
# À vous : une observation chiffrée par table (lignes, clé, colonnes) dans le livrable.


# %% US-02 · Ingestion dans bronze (copie fidèle + lot, source, horodatage, empreinte de ligne)
# Règles : types texte, aucune correction, aucun rejet, quatre métadonnées ajoutées. Les tables bronze existent déjà (initdb/00_medallion.sql) : ne les recréez pas.
# Idempotence : on supprime d'abord les lignes du lot, puis on les réinsère (relancer = même résultat, sans doublon).
# Lecture avec le compte reader (lecture seule). coerce_float=False : un montant 184,10 reste 184.10 (sinon la porte B échoue).
SOURCES = [("crm", "client", "crm_client"), ("crm", "contrat", "crm_contrat"), ("crm", "type_contrat", "crm_type_contrat"), ("crm", "sinistre", "crm_sinistre"),
           ("cif", "clients", "cif_clients"), ("cif", "compte", "cif_compte"), ("cif", "pays", "cif_pays")]

def ingerer(base, table, cible):
    src = reader(base)
    with src.connect() as c:
        df = pd.read_sql(text(f"SELECT * FROM {table}"), c, coerce_float=False).astype("string")      # tout en texte
    df = df.astype(object).where(df.notna(), None)
    h = pd.util.hash_pandas_object(df.fillna("\\N").astype(str), index=False)                         # empreinte AVANT les métadonnées
    df["_row_hash"] = [f"{v:016x}" for v in h]
    df["_batch_id"] = BATCH
    df["_source_system"] = base
    with eng().begin() as c:
        c.execute(text(f"DELETE FROM bronze.{cible} WHERE _batch_id = :b"), {"b": BATCH})
        df.to_sql(cible, c, schema="bronze", if_exists="append", index=False, chunksize=10_000)
    return len(df)

executer("INSERT INTO dq.lot_ingestion (batch_id, statut) VALUES (:b, 'EN_COURS') ON DUPLICATE KEY UPDATE statut='EN_COURS', finished_at=NULL", b=BATCH)
for base, table, cible in SOURCES:
    print(f"{base}.{table:<13} -> bronze.{cible:<17} {ingerer(base, table, cible):>7} lignes")
executer("UPDATE dq.lot_ingestion SET statut='TERMINE', finished_at=NOW() WHERE batch_id = :b", b=BATCH)


# %% US-03 · Porte B : réconciliation source → bronze (RQ-021) et métadonnées (RQ-022)
# RQ-021 : même nombre de lignes et même somme de contrôle (SUM des CRC32 de chaque ligne), table par table. Les colonnes sont lues dans information_schema.
def somme_controle(base, table, ou=""):
    colonnes = lire("SELECT column_name FROM information_schema.columns WHERE table_schema = :s AND table_name = :t AND column_name NOT LIKE '\\_%' "
                    "AND column_name <> 'bronze_row_id' ORDER BY ordinal_position", s=base, t=table).column_name.tolist()
    liste = ", ".join(colonnes)
    r = lire(f"SELECT COUNT(*) AS n, COALESCE(SUM(CRC32(CONCAT_WS('|', {liste}))), 0) AS crc FROM {base}.{table} {ou}")
    return int(r.n[0]), int(r.crc[0])

porte_b = []
for base, table, cible in SOURCES:
    n_src, crc_src = somme_controle(base, table)
    n_brz, crc_brz = somme_controle("bronze", cible, f"WHERE _batch_id = '{BATCH}'")
    ecarts = abs(n_src - n_brz) + int(crc_src != crc_brz)
    porte_b.append(mesurer("BRONZE", "RQ-021", cible, n_src, ecarts))
    # RQ-022 : chaque ligne porte lot, source, horodatage et empreinte
    meta = lire(f"""SELECT COUNT(*) AS n, COALESCE(SUM(_batch_id IS NULL OR _batch_id = '' OR _source_system IS NULL OR _source_system = ''
                    OR _ingested_at IS NULL OR _row_hash IS NULL OR _row_hash = ''), 0) AS ko FROM bronze.{cible} WHERE _batch_id = '{BATCH}'""")
    porte_b.append(mesurer("BRONZE", "RQ-022", cible, int(meta.n[0]), int(meta.ko[0])))
print(pd.DataFrame(porte_b).sort_values(["rule_id", "table"]).to_string(index=False))      # aucun écart attendu

# Épreuve de l'écart volontaire : sur une COPIE, jamais sur bronze elle-même, et sans écrire le résultat dans dq.dq_history
executer("DROP TABLE IF EXISTS bronze.crm_client_test")
executer("CREATE TABLE bronze.crm_client_test LIKE bronze.crm_client")
executer("INSERT INTO bronze.crm_client_test SELECT * FROM bronze.crm_client")
# À vous : altérez la copie (un UPDATE ... LIMIT ..., une suppression, un doublon inséré), par exemple :
executer("""
    UPDATE bronze.crm_client_test
    SET nom = 'Mongi'
    WHERE adresse = '31 rue Anatole France'
    LIMIT 1
""")
n_t, crc_t = somme_controle("bronze", "crm_client_test")
n_s, crc_s = somme_controle("crm", "client")
print("PREUVE DE VERIFICATION - copie contre source : écarts =", abs(n_s - n_t) + int(crc_s != crc_t), "(0 tant que la copie n'est pas altérée)")
executer("DROP TABLE bronze.crm_client_test")                      # à la fin, dans tous les cas


# %% US-06 · Profil complet de crm.client avec YData-Profiling (rapport HTML), puis constats chiffrés
# Le rapport montre, il ne dit pas si une valeur est valide : chaque constat se chiffre ensuite par une requête.
from ydata_profiling import ProfileReport
import os
df = lire("SELECT * FROM crm.client", reader("crm"))             # 100 000 lignes, colonnes texte telles que livrées par la source
DOSSIER_RAPPORTS = "/home/jovyan/work/reports" if os.path.isdir("/home/jovyan/work/reports") else "reports"
os.makedirs(DOSSIER_RAPPORTS, exist_ok=True)
profil = ProfileReport(df, title="AssurConnect — Profilage crm.client (100 000 lignes)", explorative=True)
profil.to_file(f"{DOSSIER_RAPPORTS}/ydata_profiling_client.html")      # à ouvrir dans un navigateur : onglets Overview, Variables, Alerts
print("rapport écrit :", f"{DOSSIER_RAPPORTS}/ydata_profiling_client.html")

# Constats chiffrés sur bronze (le lot courant)
b = lire("SELECT * FROM bronze.crm_client WHERE _batch_id = :b", b=BATCH)
b = b[[c for c in b.columns if not c.startswith("_") and c != "bronze_row_id"]]
stats = pd.DataFrame({"nuls": b.isna().sum(), "vides": (b == "").sum(), "blancs": ((b.apply(lambda s: s.str.strip()) == "") & (b != "")).sum(),
                      "distincts": b.nunique(), "long_min": b.apply(lambda s: s.str.len().min()).astype("Int64"), "long_max": b.apply(lambda s: s.str.len().max()).astype("Int64")})
print(stats)
print("\nClé client_id : lignes", len(b), "| distinctes", b.client_id.nunique(), "| nulles", int(b.client_id.isna().sum()))
print("\nDomaine de type_personne :\n", b.type_personne.value_counts(dropna=False))
print("\nPays (valeurs distinctes) :", b.pays.nunique(), "\n", b.pays.value_counts(dropna=False).head(12))
# Valeurs manquantes normales ou défauts ? nom et raison_sociale se complètent : une personne morale n'a pas de nom
print("\nni nom ni raison :", int((b.nom.isna() & b.raison_sociale.isna()).sum()), "| les deux :", int((b.nom.notna() & b.raison_sociale.notna()).sum()),
      "| nom nul :", int(b.nom.isna().sum()), "| raison nulle :", int(b.raison_sociale.isna().sum()))
print("\nBornes de date de naissance :", b.date_naissance.dropna().min(), "→", b.date_naissance.dropna().max(), "| création :", b.date_creation.dropna().min(), "→", b.date_creation.dropna().max())
# À vous : au moins cinq constats chiffrés, dont trois que le rapport révèle sans requête et un qu'il ne signale pas (par exemple le zéro initial perdu).



# %% US-07 · Motifs de code postal, téléphone et pays, puis expressions régulières
def motif(s):
    """9 remplace un chiffre, A une lettre : on voit la forme d'une valeur, pas la valeur."""
    return s.fillna("<NULL>").str.replace(r"[0-9]", "9", regex=True).str.replace(r"[A-Za-z]", "A", regex=True)

for colonne in ["cp", "telephone", "pays"]:
    print(f"\nMotifs de {colonne} :\n", motif(b[colonne]).value_counts().head(12))

def conformite(serie, regex):
    """(testées, en échec) pour une expression régulière complète ; une valeur nulle est en échec."""
    ok = serie.fillna("").str.fullmatch(regex)
    return len(serie), int((~ok).sum())

fr = b[b.pays == "FR"]
n, ko = conformite(fr.cp, r"[0-9]{5}")
print(f"\nRQ-005 : code postal à 5 chiffres, adresses FR : {ko} écarts sur {n} ({100*ko/n:.3f} %)")           # 1 456 sur 95 437
print("A01 (zéro initial perdu) :\n", fr[fr.cp.fillna("").str.fullmatch(r"[0-9]{4}")].groupby(["cp", "ville"]).size().sort_values(ascending=False).head(10))

# Téléphone : proposez vous-même la ou les expressions, puis mesurez leur conformité (pensez aux formats +33 et 0033 et aux numéros étrangers valides).
regex_telephone = (
    r"(?:"
    r"0[1-9](?:[ .-]?\d{2}){4}"
    r"|(?:\+|00)[1-9]\d{0,2}(?:[ .-]?\d){6,14}"
    r")"
)       # à vous, par exemple r"..." ; None tant que vous n'avez pas proposé d'expression
renseignes = b[b.telephone.notna() & (b.telephone.str.strip() != "")]
if regex_telephone:
    n, ko = conformite(renseignes.telephone, regex_telephone)
    print(f"téléphone : {ko} écarts sur {n} numéros renseignés")

# Pays : valide = présent dans le référentiel silver.ref_pays (chargé par load_sources.py)
ref_pays = set(lire("SELECT code_pays FROM silver.ref_pays").code_pays)
hors = b[~b.pays.isin(ref_pays)]
print(f"pays hors référentiel : {len(hors)} sur {len(b)}\n", hors.pays.value_counts(dropna=False).head(15))



# %% US-04 · Dictionnaire du CIF (colonnes column0 à column9, anonymes)
cif = lire("SELECT * FROM bronze.cif_clients WHERE _batch_id = :b", b=BATCH)
cif = cif[[c for c in cif.columns if c.startswith("column")]]
dico = pd.DataFrame({
    "nuls": cif.isna().sum(), "distincts": cif.nunique(), "long_min": cif.apply(lambda s: s.str.len().min()).astype("Int64"), "long_max": cif.apply(lambda s: s.str.len().max()).astype("Int64"),
    "motif_dominant": cif.apply(lambda s: motif(s).value_counts().index[0]), "exemples": cif.apply(lambda s: " | ".join(s.dropna().sample(3, random_state=1).tolist()))})
print(dico.to_string())
# À vous : un nom, un type et une justification chiffrée par colonne, déduits de ces mesures et non devinés.

# Lien entre les deux tables du CIF : quelle part des valeurs d'une colonne de cif_compte se retrouve dans une colonne de cif_clients ?
compte = lire("SELECT * FROM bronze.cif_compte WHERE _batch_id = :b", b=BATCH)
compte = compte[[c for c in compte.columns if c.startswith("column")]]
liens = [(a, k, round(100 * compte[a].isin(set(cif[k].dropna())).mean(), 1)) for a in compte.columns for k in cif.columns]
print(pd.DataFrame(liens, columns=["colonne_compte", "colonne_clients", "pct_retrouvees"]).sort_values("pct_retrouvees", ascending=False).head(5))
# Une clé étrangère probable se reconnaît à un taux proche de 100 %.