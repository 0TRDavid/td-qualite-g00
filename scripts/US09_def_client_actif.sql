-- ============================================================================
-- US-09 · Trois définitions du « client actif »
-- ============================================================================
-- Les trois directions comptent des clients différents. Définitions (fiche CD-001, onglet Gouvernance) :
--   Direction commerciale : au moins un contrat
--   Direction des sinistres : un contrat en cours à la date de référence
--   Direction des risques (CD-001) : un contrat en cours ET une cotisation à jour sur les trois derniers mois
-- En bronze, les dates sont du texte au format aaaa-mm-jj : la comparaison de textes suit l'ordre chronologique.
SET @cotisation_min = DATE_FORMAT(DATE_SUB(@date_ref, INTERVAL 3 MONTH), '%Y-%m-%d');
SELECT @date_ref AS date_ref, @cotisation_min AS cotisation_depuis;

-- À écrire : un COUNT(DISTINCT ...) par définition, sur le souscripteur du contrat. Squelette :
-- SELECT COUNT(DISTINCT souscripteur_id) AS clients_directions_commerciale
-- FROM bronze.crm_contrat WHERE _batch_id = @batch AND <condition>;
-- (répéter pour les sinistres : condition sur date_debut et date_fin ; puis pour les risques : ajouter date_derniere_cotisation)

-- Tableau des écarts : rapport de chaque définition à la plus large (à compléter avec vos trois résultats)
-- SELECT def, nb, ROUND(nb / MAX(nb) OVER (), 3) AS rapport FROM (SELECT 'commerciale' AS def, <n1> AS nb UNION ALL ...) t;