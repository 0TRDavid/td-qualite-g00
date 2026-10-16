-- ============================================================================
-- US-01 · Inventaire des sources cif et crm
-- ============================================================================
-- 1.1 Tables, lignes estimées et clé primaire (table_rows est une estimation pour InnoDB)
SELECT t.table_schema AS base, t.table_name AS `table`, t.table_rows AS lignes_estimees,
       (SELECT GROUP_CONCAT(k.column_name ORDER BY k.ordinal_position)
          FROM information_schema.key_column_usage k
         WHERE k.table_schema = t.table_schema AND k.table_name = t.table_name AND k.constraint_name = 'PRIMARY') AS cle_primaire
FROM information_schema.tables t
WHERE t.table_schema IN ('cif', 'crm') AND t.table_type = 'BASE TABLE'
ORDER BY t.table_schema, t.table_name;

-- 1.2 Comptage exact : la requête est écrite par une requête, puis exécutée
SET @sql = (SELECT GROUP_CONCAT(CONCAT('SELECT ''', table_schema, '.', table_name, ''' AS `table`, COUNT(*) AS lignes FROM ', table_schema, '.', table_name)
                                ORDER BY table_schema, table_name SEPARATOR ' UNION ALL ')
            FROM information_schema.tables WHERE table_schema IN ('cif', 'crm') AND table_type = 'BASE TABLE');
PREPARE st FROM @sql;  EXECUTE st;  DEALLOCATE PREPARE st;
-- SELECT @sql;   -- pour lire la requête générée

-- 1.3 Tables sans clé primaire
SELECT t.table_schema AS base, t.table_name AS `table`
FROM information_schema.tables t
LEFT JOIN information_schema.table_constraints c
       ON c.table_schema = t.table_schema AND c.table_name = t.table_name AND c.constraint_type = 'PRIMARY KEY'
WHERE t.table_schema IN ('cif', 'crm') AND t.table_type = 'BASE TABLE' AND c.constraint_name IS NULL;

-- 1.4 Colonnes : type déclaré, nullabilité
SELECT table_schema AS base, table_name AS `table`, ordinal_position AS rang, column_name AS colonne, column_type AS type, is_nullable AS nullable
FROM information_schema.columns
WHERE table_schema IN ('cif', 'crm')
ORDER BY table_schema, table_name, ordinal_position;