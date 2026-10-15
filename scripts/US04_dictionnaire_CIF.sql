-- ============================================================================
-- US-04 · Dictionnaire du CIF (colonnes column0 à column9, anonymes)
-- ============================================================================
-- 4.1 Statistiques par colonne, générées pour toutes les colonnes de la table choisie (changez @schema / @table pour cif_compte, cif_pays)
SET @schema = 'bronze';  SET @table = 'cif_clients';
SET @sql = (SELECT GROUP_CONCAT(CONCAT(
    'SELECT ''', column_name, ''' AS colonne, COUNT(*) AS lignes, SUM(', column_name, ' IS NULL) AS nuls, SUM(', column_name, ' = '''') AS vides, ',
    'COUNT(DISTINCT ', column_name, ') AS distincts, MIN(CHAR_LENGTH(', column_name, ')) AS long_min, MAX(CHAR_LENGTH(', column_name, ')) AS long_max, ',
    'MIN(', column_name, ') AS valeur_min, MAX(', column_name, ') AS valeur_max FROM ', @schema, '.', @table)
    ORDER BY ordinal_position SEPARATOR ' UNION ALL ')
  FROM information_schema.columns
  WHERE table_schema = @schema AND table_name = @table AND column_name NOT LIKE '\_%' AND column_name <> 'bronze_row_id');
PREPARE st FROM @sql;  EXECUTE st;  DEALLOCATE PREPARE st;

-- 4.2 Motifs d'une colonne : 9 remplace un chiffre, A une lettre (à répéter pour chaque colonne qui vous intrigue)
SELECT REGEXP_REPLACE(REGEXP_REPLACE(column3, '[0-9]', '9'), '[A-Za-z]', 'A') AS motif, COUNT(*) AS lignes
FROM bronze.cif_clients
GROUP BY motif ORDER BY lignes DESC LIMIT 15;

-- 4.3 Valeurs les plus fréquentes d'une colonne (utile pour un code pays, un indicateur, un statut)
SELECT column7 AS valeur, COUNT(*) AS lignes FROM bronze.cif_clients GROUP BY column7 ORDER BY lignes DESC LIMIT 15;

-- 4.4 Lien entre les deux tables CIF : quelle part des valeurs d'une colonne de cif_compte se retrouve dans une colonne de cif_clients ?
--     Remplacez <colonne_compte> et <colonne_clients> par le couple que vous voulez tester (une clé étrangère probable se reconnaît à un taux proche de 100 %).
-- SELECT COUNT(*) AS lignes, SUM(c.<colonne_compte> IN (SELECT <colonne_clients> FROM bronze.cif_clients)) AS retrouvees
-- FROM bronze.cif_compte c;