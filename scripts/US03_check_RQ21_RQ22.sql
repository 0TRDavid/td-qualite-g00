-- ============================================================================
-- US-03 · Porte B : réconciliation source → bronze (RQ-021) et métadonnées (RQ-022)
-- ============================================================================
-- RQ-021 : même nombre de lignes et même somme de contrôle (SUM des CRC32 de chaque ligne), table par table.
-- Les colonnes sont lues dans information_schema.columns : la requête est donc écrite pour les sept tables, puis exécutée.
SET @sql = (
  SELECT CONCAT('INSERT INTO dq.dq_history (batch_id, couche, rule_id, table_cible, nb_testees, nb_echecs) ',
                GROUP_CONCAT(CONCAT(
                  'SELECT @batch, ''BRONZE'', ''RQ-021'', ''', m.cible, ''', s.n, ABS(s.n - b.n) + (s.crc <> b.crc) FROM ',
                  '(SELECT COUNT(*) AS n, COALESCE(SUM(CRC32(CONCAT_WS(''|'', ', c.cols, '))), 0) AS crc FROM ', m.base, '.', m.tbl, ') s, ',
                  '(SELECT COUNT(*) AS n, COALESCE(SUM(CRC32(CONCAT_WS(''|'', ', c.cols, '))), 0) AS crc FROM bronze.', m.cible, ' WHERE _batch_id = @batch) b')
                  ORDER BY m.cible SEPARATOR ' UNION ALL '))
  FROM (SELECT 'crm' AS base, 'client' AS tbl, 'crm_client' AS cible UNION ALL SELECT 'crm', 'contrat', 'crm_contrat'
        UNION ALL SELECT 'crm', 'type_contrat', 'crm_type_contrat' UNION ALL SELECT 'crm', 'sinistre', 'crm_sinistre'
        UNION ALL SELECT 'cif', 'clients', 'cif_clients' UNION ALL SELECT 'cif', 'compte', 'cif_compte' UNION ALL SELECT 'cif', 'pays', 'cif_pays') m
  JOIN (SELECT table_schema, table_name, GROUP_CONCAT(column_name ORDER BY ordinal_position) AS cols
          FROM information_schema.columns WHERE table_schema IN ('cif', 'crm') GROUP BY table_schema, table_name) c
    ON c.table_schema = m.base AND c.table_name = m.tbl);
-- SELECT @sql;   -- lisez la requête générée avant de l'exécuter
DELETE FROM dq.dq_history WHERE batch_id = @batch AND couche = 'BRONZE' AND rule_id = 'RQ-021';
PREPARE st FROM @sql;  EXECUTE st;  DEALLOCATE PREPARE st;

-- RQ-022 : chaque ligne bronze porte lot, source, horodatage et empreinte
DELETE FROM dq.dq_history WHERE batch_id = @batch AND couche = 'BRONZE' AND rule_id = 'RQ-022';
INSERT INTO dq.dq_history (batch_id, couche, rule_id, table_cible, nb_testees, nb_echecs)
SELECT @batch, 'BRONZE', 'RQ-022', t, n, ko FROM (
  SELECT 'crm_client' AS t, COUNT(*) AS n, COALESCE(SUM(_batch_id IS NULL OR _batch_id = '' OR _source_system IS NULL OR _source_system = '' OR _ingested_at IS NULL OR _row_hash IS NULL OR _row_hash = ''), 0) AS ko FROM bronze.crm_client WHERE _batch_id = @batch
  UNION ALL SELECT 'crm_contrat', COUNT(*), COALESCE(SUM(_batch_id IS NULL OR _batch_id = '' OR _source_system IS NULL OR _source_system = '' OR _ingested_at IS NULL OR _row_hash IS NULL OR _row_hash = ''), 0) FROM bronze.crm_contrat WHERE _batch_id = @batch
  UNION ALL SELECT 'crm_type_contrat', COUNT(*), COALESCE(SUM(_batch_id IS NULL OR _batch_id = '' OR _source_system IS NULL OR _source_system = '' OR _ingested_at IS NULL OR _row_hash IS NULL OR _row_hash = ''), 0) FROM bronze.crm_type_contrat WHERE _batch_id = @batch
  UNION ALL SELECT 'crm_sinistre', COUNT(*), COALESCE(SUM(_batch_id IS NULL OR _batch_id = '' OR _source_system IS NULL OR _source_system = '' OR _ingested_at IS NULL OR _row_hash IS NULL OR _row_hash = ''), 0) FROM bronze.crm_sinistre WHERE _batch_id = @batch
  UNION ALL SELECT 'cif_clients', COUNT(*), COALESCE(SUM(_batch_id IS NULL OR _batch_id = '' OR _source_system IS NULL OR _source_system = '' OR _ingested_at IS NULL OR _row_hash IS NULL OR _row_hash = ''), 0) FROM bronze.cif_clients WHERE _batch_id = @batch
  UNION ALL SELECT 'cif_compte', COUNT(*), COALESCE(SUM(_batch_id IS NULL OR _batch_id = '' OR _source_system IS NULL OR _source_system = '' OR _ingested_at IS NULL OR _row_hash IS NULL OR _row_hash = ''), 0) FROM bronze.cif_compte WHERE _batch_id = @batch
  UNION ALL SELECT 'cif_pays', COUNT(*), COALESCE(SUM(_batch_id IS NULL OR _batch_id = '' OR _source_system IS NULL OR _source_system = '' OR _ingested_at IS NULL OR _row_hash IS NULL OR _row_hash = ''), 0) FROM bronze.cif_pays WHERE _batch_id = @batch
) x;

-- Lecture de la porte B : aucun écart attendu, table par table
SELECT rule_id, table_cible, nb_testees, nb_echecs, taux_conformite
FROM dq.dq_history WHERE batch_id = @batch AND couche = 'BRONZE' AND rule_id IN ('RQ-021', 'RQ-022')
ORDER BY rule_id, table_cible;

-- Épreuve de l'écart volontaire : sur une COPIE, jamais sur bronze elle-même, et sans écrire le résultat dans dq_history
DROP TABLE IF EXISTS bronze.crm_client_test;
CREATE TABLE bronze.crm_client_test LIKE bronze.crm_client;
INSERT INTO bronze.crm_client_test SELECT * FROM bronze.crm_client;
-- À vous : altérez la copie (un UPDATE ... LIMIT ..., une suppression, un doublon inséré) :
-- UPDATE bronze.crm_client_test SET ... WHERE ... LIMIT ...;
-- Même somme de contrôle que la porte B, comparée à crm.client :
SELECT s.n AS lignes_source, b.n AS lignes_copie, s.crc AS somme_source, b.crc AS somme_copie,
       ABS(s.n - b.n) + (s.crc <> b.crc) AS ecarts
FROM (SELECT COUNT(*) AS n, SUM(CRC32(CONCAT_WS('|', client_id, type_personne, nom, prenom, raison_sociale, date_naissance, adresse, cp, ville, pays, telephone, email, date_creation))) AS crc FROM crm.client) s,
     (SELECT COUNT(*) AS n, SUM(CRC32(CONCAT_WS('|', client_id, type_personne, nom, prenom, raison_sociale, date_naissance, adresse, cp, ville, pays, telephone, email, date_creation))) AS crc FROM bronze.crm_client_test) b;
DROP TABLE bronze.crm_client_test;     -- à la fin, dans tous les cas