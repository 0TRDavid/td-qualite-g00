-- ============================================================================
-- US-06 · Profil complet de bronze.crm_client
-- ============================================================================
-- 6.1 Statistiques par colonne (même générateur que 4.1)
SET @schema = 'bronze';  SET @table = 'crm_client';
SET @sql = (SELECT GROUP_CONCAT(CONCAT(
    'SELECT ''', column_name, ''' AS colonne, COUNT(*) AS lignes, SUM(', column_name, ' IS NULL) AS nuls, SUM(', column_name, ' = '''') AS vides, ',
    'SUM(TRIM(', column_name, ') = '''' AND ', column_name, ' <> '''') AS blancs, COUNT(DISTINCT ', column_name, ') AS distincts, ',
    'MIN(CHAR_LENGTH(', column_name, ')) AS long_min, MAX(CHAR_LENGTH(', column_name, ')) AS long_max FROM ', @schema, '.', @table, ' WHERE _batch_id = @batch')
    ORDER BY ordinal_position SEPARATOR ' UNION ALL ')
  FROM information_schema.columns
  WHERE table_schema = @schema AND table_name = @table AND column_name NOT LIKE '\_%' AND column_name <> 'bronze_row_id');
PREPARE st FROM @sql;  EXECUTE st;  DEALLOCATE PREPARE st;

-- 6.2 Doublons de clé et lignes sans clé
SELECT COUNT(*) AS lignes, COUNT(DISTINCT client_id) AS cles_distinctes, SUM(client_id IS NULL) AS cles_nulles
FROM bronze.crm_client WHERE _batch_id = @batch;

-- 6.3 Cardinalité des colonnes à domaine fermé : toutes les valeurs, avec leur fréquence
SELECT type_personne AS valeur, COUNT(*) AS lignes FROM bronze.crm_client WHERE _batch_id = @batch GROUP BY type_personne ORDER BY lignes DESC;
SELECT pays          AS valeur, COUNT(*) AS lignes FROM bronze.crm_client WHERE _batch_id = @batch GROUP BY pays          ORDER BY lignes DESC;

-- 6.4 Valeurs manquantes normales ou défauts ? nom et raison_sociale se complètent : une personne morale n'a pas de nom
SELECT SUM(nom IS NULL AND raison_sociale IS NULL)         AS ni_nom_ni_raison,
       SUM(nom IS NOT NULL AND raison_sociale IS NOT NULL) AS les_deux,
       SUM(nom IS NULL)            AS nom_nul,
       SUM(raison_sociale IS NULL) AS raison_nulle
FROM bronze.crm_client WHERE _batch_id = @batch;

-- 6.5 Bornes d'une date (les dates sont du texte en bronze : le tri alphabétique suit l'ordre chronologique au format aaaa-mm-jj)
SELECT MIN(date_naissance) AS plus_ancienne, MAX(date_naissance) AS plus_recente, MIN(date_creation) AS creation_min, MAX(date_creation) AS creation_max
FROM bronze.crm_client WHERE _batch_id = @batch;