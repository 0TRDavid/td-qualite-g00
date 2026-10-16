-- ============================================================================
-- US-07 · Motifs de code postal, téléphone et pays, puis expressions régulières
-- ============================================================================
-- 7.1 Motifs (changez la colonne : cp, telephone, pays, email)
SELECT REGEXP_REPLACE(REGEXP_REPLACE(cp, '[0-9]', '9'), '[A-Za-z]', 'A') AS motif, COUNT(*) AS lignes
FROM bronze.crm_client WHERE _batch_id = @batch
GROUP BY motif ORDER BY lignes DESC LIMIT 12;

-- 7.2 Conformité d'une expression régulière : mesurez-la sur les adresses françaises (RQ-005 : 5 chiffres exactement)
SELECT COUNT(*) AS lignes_fr,
       SUM(cp REGEXP '^[0-9]{5}$')      AS conformes,
       SUM(NOT (cp REGEXP '^[0-9]{5}$') OR cp IS NULL) AS non_conformes
FROM bronze.crm_client WHERE pays = 'FR' AND _batch_id = @batch;

-- 7.3 Anomalie A01 (zéro initial perdu) : un code postal français à quatre chiffres
SELECT cp, ville, COUNT(*) AS lignes
FROM bronze.crm_client WHERE pays = 'FR' AND cp REGEXP '^[0-9]{4}$' AND _batch_id = @batch
GROUP BY cp, ville ORDER BY lignes DESC LIMIT 10;

-- 7.4 Téléphone : proposez vous-même la ou les expressions, puis mesurez leur conformité de la même façon.
--     Squelette (remplacez <regex>) ; pensez aux formats +33 et 0033 et aux numéros étrangers valides :
-- SELECT COUNT(*) AS renseignes, SUM(telephone REGEXP '<regex>') AS conformes
-- FROM bronze.crm_client WHERE telephone IS NOT NULL AND TRIM(telephone) <> '' AND _batch_id = @batch;

-- 7.5 Pays : valide = présent dans le référentiel silver.ref_pays (le référentiel est chargé par load_sources.py)
SELECT COUNT(*) AS lignes, SUM(pays IN (SELECT code_pays FROM silver.ref_pays)) AS valides
FROM bronze.crm_client WHERE _batch_id = @batch;
SELECT pays, COUNT(*) AS lignes FROM bronze.crm_client
WHERE _batch_id = @batch AND (pays IS NULL OR pays NOT IN (SELECT code_pays FROM silver.ref_pays))
GROUP BY pays ORDER BY lignes DESC LIMIT 15;