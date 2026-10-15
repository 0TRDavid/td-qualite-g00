-- ============================================================================
-- US-02 · Ingestion dans bronze (copie fidèle + lot, source, horodatage, empreinte de ligne)
-- ============================================================================
-- Les tables bronze existent déjà (initdb/00_medallion.sql) : ne les recréez pas.
-- Règles : types texte (CAST ... AS CHAR garde 184.10 tel quel), aucune correction, aucun rejet, métadonnées ajoutées.
-- Idempotence : on supprime d'abord les lignes du lot, puis on les réinsère (relancer = même résultat, sans doublon).
-- Limite connue de l'empreinte : CONCAT_WS ignore les NULL (le script Python utilise un marqueur \N).
-- Lecture seule sur les sources : voir 2.4. Pour écrire dans bronze, la connexion doit être root.

INSERT INTO dq.lot_ingestion (batch_id, statut) VALUES (@batch, 'EN_COURS')
ON DUPLICATE KEY UPDATE statut = 'EN_COURS', finished_at = NULL;

-- 2.1 crm.client (modèle : lisez-le ligne à ligne)
DELETE FROM bronze.crm_client WHERE _batch_id = @batch;
INSERT INTO bronze.crm_client
      (client_id, type_personne, nom, prenom, raison_sociale, date_naissance, adresse, cp, ville, pays, telephone, email, date_creation,
       _batch_id, _source_system, _ingested_at, _row_hash)
SELECT client_id, type_personne, nom, prenom, raison_sociale, CAST(date_naissance AS CHAR), adresse, cp, ville, pays, telephone, email, CAST(date_creation AS CHAR),
       @batch, 'crm', NOW(),
       LEFT(SHA2(CONCAT_WS('|', client_id, type_personne, nom, prenom, raison_sociale, date_naissance, adresse, cp, ville, pays, telephone, email, date_creation), 256), 16)
FROM crm.client;

-- 2.2 Les six autres tables : même démarche
DELETE FROM bronze.crm_contrat WHERE _batch_id = @batch;
INSERT INTO bronze.crm_contrat
      (contrat_id, souscripteur_id, assure_id, code_type, date_debut, date_fin, duree_garantie_mois, prime_annuelle, date_derniere_cotisation,
       _batch_id, _source_system, _ingested_at, _row_hash)
SELECT contrat_id, souscripteur_id, assure_id, code_type, CAST(date_debut AS CHAR), CAST(date_fin AS CHAR), CAST(duree_garantie_mois AS CHAR),
       CAST(prime_annuelle AS CHAR), CAST(date_derniere_cotisation AS CHAR),
       @batch, 'crm', NOW(),
       LEFT(SHA2(CONCAT_WS('|', contrat_id, souscripteur_id, assure_id, code_type, date_debut, date_fin, duree_garantie_mois, prime_annuelle, date_derniere_cotisation), 256), 16)
FROM crm.contrat;

DELETE FROM bronze.crm_type_contrat WHERE _batch_id = @batch;
INSERT INTO bronze.crm_type_contrat (code_type, libelle, branche, _batch_id, _source_system, _ingested_at, _row_hash)
SELECT code_type, libelle, branche, @batch, 'crm', NOW(), LEFT(SHA2(CONCAT_WS('|', code_type, libelle, branche), 256), 16)
FROM crm.type_contrat;

DELETE FROM bronze.crm_sinistre WHERE _batch_id = @batch;
INSERT INTO bronze.crm_sinistre
      (sinistre_id, contrat_id, date_survenance, date_declaration, type_sinistre, montant_estime, adresse_sinistre, cp_sinistre, ville_sinistre, canal_saisie,
       _batch_id, _source_system, _ingested_at, _row_hash)
SELECT sinistre_id, contrat_id, CAST(date_survenance AS CHAR), CAST(date_declaration AS CHAR), type_sinistre, CAST(montant_estime AS CHAR),
       adresse_sinistre, cp_sinistre, ville_sinistre, canal_saisie,
       @batch, 'crm', NOW(),
       LEFT(SHA2(CONCAT_WS('|', sinistre_id, contrat_id, date_survenance, date_declaration, type_sinistre, montant_estime, adresse_sinistre, cp_sinistre, ville_sinistre, canal_saisie), 256), 16)
FROM crm.sinistre;

DELETE FROM bronze.cif_clients WHERE _batch_id = @batch;
INSERT INTO bronze.cif_clients (column0, column1, column2, column3, column4, column5, column6, column7, column8, column9, _batch_id, _source_system, _ingested_at, _row_hash)
SELECT column0, column1, column2, column3, column4, column5, column6, column7, column8, column9, @batch, 'cif', NOW(),
       LEFT(SHA2(CONCAT_WS('|', column0, column1, column2, column3, column4, column5, column6, column7, column8, column9), 256), 16)
FROM cif.clients;

DELETE FROM bronze.cif_compte WHERE _batch_id = @batch;
INSERT INTO bronze.cif_compte (column0, column1, column2, column3, _batch_id, _source_system, _ingested_at, _row_hash)
SELECT column0, column1, CAST(column2 AS CHAR), column3, @batch, 'cif', NOW(), LEFT(SHA2(CONCAT_WS('|', column0, column1, column2, column3), 256), 16)
FROM cif.compte;

DELETE FROM bronze.cif_pays WHERE _batch_id = @batch;
INSERT INTO bronze.cif_pays (code_pays, nom_pays, _batch_id, _source_system, _ingested_at, _row_hash)
SELECT code_pays, nom_pays, @batch, 'cif', NOW(), LEFT(SHA2(CONCAT_WS('|', code_pays, nom_pays), 256), 16)
FROM cif.pays;

UPDATE dq.lot_ingestion SET statut = 'TERMINE', finished_at = NOW() WHERE batch_id = @batch;

-- 2.3 Vérifier : une ligne bronze par ligne source, un seul lot, aucun doublon après une seconde exécution du bloc
SELECT 'crm_client' AS bronze, _batch_id, COUNT(*) AS lignes FROM bronze.crm_client GROUP BY _batch_id
UNION ALL SELECT 'crm_contrat',      _batch_id, COUNT(*) FROM bronze.crm_contrat      GROUP BY _batch_id
UNION ALL SELECT 'crm_type_contrat', _batch_id, COUNT(*) FROM bronze.crm_type_contrat GROUP BY _batch_id
UNION ALL SELECT 'crm_sinistre',     _batch_id, COUNT(*) FROM bronze.crm_sinistre     GROUP BY _batch_id
UNION ALL SELECT 'cif_clients',      _batch_id, COUNT(*) FROM bronze.cif_clients      GROUP BY _batch_id
UNION ALL SELECT 'cif_compte',       _batch_id, COUNT(*) FROM bronze.cif_compte       GROUP BY _batch_id
UNION ALL SELECT 'cif_pays',         _batch_id, COUNT(*) FROM bronze.cif_pays         GROUP BY _batch_id;

-- 2.4 Lecture seule sur les sources : ouvrez une seconde connexion avec reader / reader, puis tentez
--     DELETE FROM crm.client LIMIT 1;      -- attendu : erreur « command denied » ; ne jamais exécuter ceci avec root
-- Les droits du compte, vus depuis root :
SHOW GRANTS FOR 'reader'@'%';