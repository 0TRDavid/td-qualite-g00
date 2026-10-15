-- ============================================================================
-- US-05 · Recouvrement CIF / CRM (priorité Should)
-- ============================================================================
-- Rapprochement exact sur une clé d'identité (nom, prénom, date de naissance), en majuscules. Le CIF stocke la date en jj/mm/aaaa : elle est convertie.
-- Cette clé est volontairement stricte : elle sous-estime le recouvrement réel. Dites pourquoi.
-- Les clés sont d'abord calculées dans deux tables temporaires indexées : une jointure sur des expressions (UPPER, STR_TO_DATE) ne peut pas utiliser d'index et durerait très longtemps.
DROP TEMPORARY TABLE IF EXISTS dq.tmp_cif;
DROP TEMPORARY TABLE IF EXISTS dq.tmp_crm;
CREATE TEMPORARY TABLE dq.tmp_cif AS
  SELECT column0 AS id, UPPER(column1) AS nom, UPPER(column2) AS prenom, STR_TO_DATE(column3, '%d/%m/%Y') AS naissance,
         column8 AS telephone, column9 AS email, column5 AS cp, column7 AS pays
  FROM bronze.cif_clients WHERE _batch_id = @batch;
CREATE TEMPORARY TABLE dq.tmp_crm AS
  SELECT client_id AS id, UPPER(nom) AS nom, UPPER(prenom) AS prenom, date_naissance AS naissance,
         telephone, email, cp, pays
  FROM bronze.crm_client WHERE _batch_id = @batch AND nom IS NOT NULL;
CREATE INDEX ix_cif ON dq.tmp_cif (nom, prenom, naissance);
CREATE INDEX ix_crm ON dq.tmp_crm (nom, prenom, naissance);

SELECT COUNT(DISTINCT c.id) AS personnes_cif_retrouvees_dans_crm, COUNT(DISTINCT k.id) AS lignes_crm_concernees
FROM dq.tmp_cif c JOIN dq.tmp_crm k ON k.nom = c.nom AND k.prenom = c.prenom AND k.naissance = c.naissance;

-- Par attribut, sur les paires rapprochées : identique, différent, ou renseigné d'un seul côté. Base du choix de la source de vérité.
SELECT 'telephone' AS attribut, SUM(c.telephone = k.telephone) AS identiques, SUM(c.telephone <> k.telephone) AS differents,
       SUM((c.telephone IS NULL) <> (k.telephone IS NULL)) AS renseigne_d_un_seul_cote
FROM dq.tmp_cif c JOIN dq.tmp_crm k ON k.nom = c.nom AND k.prenom = c.prenom AND k.naissance = c.naissance
UNION ALL
SELECT 'email', SUM(c.email = k.email), SUM(c.email <> k.email), SUM((c.email IS NULL) <> (k.email IS NULL))
FROM dq.tmp_cif c JOIN dq.tmp_crm k ON k.nom = c.nom AND k.prenom = c.prenom AND k.naissance = c.naissance;
-- À vous : cp, pays, adresse. Pensez que 'FR' et 'France' ne sont pas encore normalisés en bronze.