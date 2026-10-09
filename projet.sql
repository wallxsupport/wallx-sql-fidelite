-- =============================================================================
-- Projet SQL avancé — Programme de fidélité « WallX »
-- PostgreSQL 16
-- Groupe : <À COMPLÉTER : nom du groupe + membres>
--
-- Ce script s'exécute sur une base VIDE, d'un bloc :
--     psql -U wallx -d projet -f projet.sql
-- Ordre imposé par le sujet : tables, données, fonction/procédure, trigger,
-- vues, rôles, index.
--
-- Domaine : une carte de fidélité par (client, commerçant). Chaque achat
-- crédite des points (1 € = 10 points). Le client échange ses points contre
-- des récompenses. La base garantit elle-même qu'on ne dépense pas plus de
-- points qu'on n'en a — quel que soit le canal (caisse, appli, web).
-- =============================================================================


-- --- Rejouabilité : on repart propre si le script a déjà tourné ---------------
-- (le correcteur relance tout ; les rôles sont globaux au serveur)
DROP VIEW  IF EXISTS vue_caissier, vue_analyste;
DROP TABLE IF EXISTS echanges, transactions, recompenses, cartes, clients, commercants CASCADE;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'emma')     THEN DROP ROLE emma;     END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'hugo')     THEN DROP ROLE hugo;     END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'caissier') THEN DROP ROLE caissier; END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'analyste') THEN DROP ROLE analyste; END IF;
END $$;


-- =============================================================================
-- 1. LES TABLES  (on crée d'abord les tables référencées, puis celles qui pointent)
-- =============================================================================

CREATE TABLE commercants (
    id      serial PRIMARY KEY,
    nom     text NOT NULL,
    ville   text NOT NULL
);

CREATE TABLE clients (
    id       serial PRIMARY KEY,
    prenom   text NOT NULL,
    nom      text NOT NULL,
    email    text NOT NULL UNIQUE,          -- UNIQUE => indexé automatiquement
    ville    text NOT NULL,
    cree_le  timestamp NOT NULL DEFAULT now()
);

CREATE TABLE cartes (
    id             serial PRIMARY KEY,
    client_id      integer NOT NULL REFERENCES clients (id),
    commercant_id  integer NOT NULL REFERENCES commercants (id),
    statut         text NOT NULL DEFAULT 'active'
                   CHECK (statut IN ('active', 'bloquee')),
    cree_le        timestamp NOT NULL DEFAULT now(),
    UNIQUE (client_id, commercant_id)        -- une seule carte par client et commerçant
);

CREATE TABLE recompenses (
    id             serial PRIMARY KEY,
    commercant_id  integer NOT NULL REFERENCES commercants (id),
    libelle        text NOT NULL,
    cout_points    integer NOT NULL CHECK (cout_points > 0),
    actif          boolean NOT NULL DEFAULT true
);

-- La plus grosse table : chaque achat crédite des points sur une carte.
CREATE TABLE transactions (
    id             serial PRIMARY KEY,
    carte_id       integer NOT NULL REFERENCES cartes (id),
    montant_euros  numeric(8,2) NOT NULL CHECK (montant_euros > 0),
    points         integer NOT NULL CHECK (points >= 0),
    canal          text NOT NULL CHECK (canal IN ('caisse', 'app', 'web')),
    cree_le        timestamp NOT NULL DEFAULT now()
);

-- Un échange = une dépense de points contre une récompense.
CREATE TABLE echanges (
    id               serial PRIMARY KEY,
    carte_id         integer NOT NULL REFERENCES cartes (id),
    recompense_id    integer NOT NULL REFERENCES recompenses (id),
    points_depenses  integer NOT NULL CHECK (points_depenses > 0),
    cree_le          timestamp NOT NULL DEFAULT now()
);


-- =============================================================================
-- 2. LES DONNÉES  (> 10 000 lignes dans « transactions » via generate_series)
-- =============================================================================

-- 5 commerçants
INSERT INTO commercants (nom, ville) VALUES
    ('Café Central',   'Strasbourg'),
    ('Burger 235',     'Strasbourg'),
    ('Pizza Nova',     'Lyon'),
    ('Sushi Bar',      'Paris'),
    ('Épicerie Verte', 'Nantes');

-- 500 clients
INSERT INTO clients (prenom, nom, email, ville)
SELECT 'Prenom' || i,
       'Nom' || i,
       'client' || i || '@exemple.fr',
       (ARRAY['Strasbourg','Lyon','Paris','Nantes','Lille'])[1 + (i % 5)]
FROM generate_series(1, 500) AS g(i);

-- 500 cartes : une par client, répartie sur les 5 commerçants.
-- Une carte sur 50 est bloquée (pour la démo du trigger "carte active").
INSERT INTO cartes (client_id, commercant_id, statut)
SELECT i,
       1 + ((i - 1) % 5),
       CASE WHEN i % 50 = 0 THEN 'bloquee' ELSE 'active' END
FROM generate_series(1, 500) AS g(i);

-- 15 récompenses : 3 par commerçant, à 500 / 1000 / 2000 points.
INSERT INTO recompenses (commercant_id, libelle, cout_points)
SELECT 1 + ((i - 1) % 5),
       'Recompense ' || i,
       (ARRAY[500, 1000, 2000])[1 + ((i - 1) % 3)]
FROM generate_series(1, 15) AS g(i);

-- 20 000 transactions. Montant entre 5 et 50 €, points = montant x 10.
INSERT INTO transactions (carte_id, montant_euros, points, canal, cree_le)
SELECT 1 + (i % 500) AS carte_id,
       montant,
       (montant * 10)::int,
       (ARRAY['caisse','app','web'])[1 + (i % 3)],
       date '2026-01-01' + ((i % 280) || ' days')::interval
FROM generate_series(1, 20000) AS g(i),
     LATERAL (SELECT (5 + (random() * 45))::numeric(8,2) AS montant) m;

-- 400 échanges cohérents : récompense du même commerçant que la carte.
-- (chaque carte a ~40 transactions => largement de quoi payer un échange)
INSERT INTO echanges (carte_id, recompense_id, points_depenses)
SELECT ca.id, r.id, r.cout_points
FROM generate_series(1, 400) AS g(i)
JOIN cartes ca ON ca.id = 1 + (g.i % 500)
JOIN LATERAL (
    SELECT rr.id, rr.cout_points
    FROM recompenses rr
    WHERE rr.commercant_id = ca.commercant_id AND rr.actif
    ORDER BY (g.i + rr.id) % 7
    LIMIT 1
) r ON true;


-- =============================================================================
-- 3. LA FONCTION ET LA PROCÉDURE
-- =============================================================================

-- FONCTION : le solde de points d'une carte = points gagnés - points dépensés.
-- Elle calcule et renvoie une valeur ; on s'en sert comme d'une colonne,
-- dans le trigger comme dans les vues.
CREATE OR REPLACE FUNCTION solde_points(p_carte_id int)
RETURNS integer
LANGUAGE sql
AS $$
    SELECT COALESCE((SELECT sum(points)          FROM transactions WHERE carte_id = p_carte_id), 0)
         - COALESCE((SELECT sum(points_depenses) FROM echanges     WHERE carte_id = p_carte_id), 0);
$$;

-- PROCÉDURE : échanger une récompense. Elle AGIT (elle écrit) et REFUSE les cas
-- invalides. Le contrôle du solde, lui, est délégué au trigger (section 4) :
-- ainsi la règle tient même si quelqu'un insère un échange sans passer par ici.
CREATE OR REPLACE PROCEDURE echanger_recompense(p_carte_id int, p_recompense_id int)
LANGUAGE plpgsql
AS $$
DECLARE
    v_cout        integer;
    v_commercant  integer;
    v_statut      text;
BEGIN
    SELECT statut, commercant_id INTO v_statut, v_commercant
    FROM cartes WHERE id = p_carte_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Carte % inconnue', p_carte_id;
    END IF;
    IF v_statut <> 'active' THEN
        RAISE EXCEPTION 'Carte % bloquée : échange impossible', p_carte_id;
    END IF;

    SELECT cout_points INTO v_cout
    FROM recompenses
    WHERE id = p_recompense_id AND actif AND commercant_id = v_commercant;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Récompense % indisponible pour cette carte', p_recompense_id;
    END IF;

    -- L'insertion déclenche le trigger qui vérifie le solde (section 4).
    INSERT INTO echanges (carte_id, recompense_id, points_depenses)
    VALUES (p_carte_id, p_recompense_id, v_cout);
END;
$$;


-- =============================================================================
-- 4. LES TRIGGERS  (un trigger protège, il ne pilote pas)
-- =============================================================================

-- Trigger 1 — REFUSER de dépenser plus de points que le solde.
-- En base, car la règle doit tenir quel que soit le canal : si chaque appli
-- (caisse, mobile, web) la vérifiait de son côté, un oubli suffirait à créer
-- des points à partir de rien.
CREATE OR REPLACE FUNCTION verifier_solde_echange()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF solde_points(NEW.carte_id) < NEW.points_depenses THEN
        RAISE EXCEPTION 'Solde insuffisant pour la carte % : solde = %, demandé = %',
            NEW.carte_id, solde_points(NEW.carte_id), NEW.points_depenses;
    END IF;
    RETURN NEW;      -- BEFORE INSERT : on laisse passer la ligne
END;
$$;

CREATE TRIGGER echanges_verifier_solde
    BEFORE INSERT ON echanges
    FOR EACH ROW
    EXECUTE FUNCTION verifier_solde_echange();

-- Trigger 2 — une carte bloquée ne gagne plus de points.
CREATE OR REPLACE FUNCTION verifier_carte_active()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF (SELECT statut FROM cartes WHERE id = NEW.carte_id) = 'bloquee' THEN
        RAISE EXCEPTION 'Carte % bloquée : aucun point ne peut être crédité', NEW.carte_id;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER transactions_carte_active
    BEFORE INSERT ON transactions
    FOR EACH ROW
    EXECUTE FUNCTION verifier_carte_active();


-- =============================================================================
-- 5. LES VUES  (une par rôle ; le droit ira sur la vue, pas sur les tables)
-- =============================================================================

-- Vue du CAISSIER : le solde d'une carte et le client, nom masqué (RGPD).
-- Il n'a pas besoin de l'e-mail ni du nom complet pour faire son travail.
CREATE VIEW vue_caissier AS
SELECT ca.id                                     AS carte_id,
       co.nom                                    AS commercant,
       cl.prenom || ' ' || left(cl.nom, 1) || '.' AS client,
       ca.statut,
       solde_points(ca.id)                       AS solde
FROM cartes ca
JOIN clients cl     ON cl.id = ca.client_id
JOIN commercants co ON co.id = ca.commercant_id;

-- Vue de l'ANALYSTE : des statistiques agrégées par commerçant, aucune donnée
-- nominative. Idéal pour un tableau de bord, sans accès aux tables brutes.
CREATE VIEW vue_analyste AS
SELECT co.id                                    AS commercant_id,
       co.nom                                   AS commercant,
       count(DISTINCT ca.id)                    AS cartes,
       count(t.id)                              AS nb_transactions,
       COALESCE(sum(t.points), 0)               AS points_distribues,
       COALESCE(sum(t.montant_euros), 0)        AS ca_euros
FROM commercants co
LEFT JOIN cartes ca      ON ca.commercant_id = co.id
LEFT JOIN transactions t ON t.carte_id = ca.id
GROUP BY co.id, co.nom;


-- =============================================================================
-- 6. LES RÔLES ET LES PRIVILÈGES  (moindre privilège ; droits au rôle-métier)
-- =============================================================================

-- Deux rôles-métiers, sans connexion : on leur donne les droits.
CREATE ROLE caissier NOLOGIN;
CREATE ROLE analyste NOLOGIN;

-- Un utilisateur par rôle : il se connecte, et hérite des droits du rôle.
CREATE ROLE emma LOGIN PASSWORD 'emma' IN ROLE caissier;
CREATE ROLE hugo LOGIN PASSWORD 'hugo' IN ROLE analyste;

-- CAISSIER : fait le travail courant. Il lit le catalogue et l'historique,
-- crédite des points et enregistre des échanges. Il ne touche PAS la table
-- clients (données personnelles) : il passe par sa vue.
GRANT SELECT ON commercants, recompenses, cartes, transactions, echanges TO caissier;
GRANT INSERT ON transactions, echanges TO caissier;
GRANT USAGE, SELECT ON SEQUENCE transactions_id_seq, echanges_id_seq TO caissier;
GRANT SELECT ON vue_caissier TO caissier;

-- ANALYSTE : contrôle sans rien modifier. Il n'a AUCUN droit sur les tables,
-- seulement sur sa vue agrégée : il ne peut pas lire une ligne nominative.
GRANT SELECT ON vue_analyste TO analyste;


-- =============================================================================
-- 7. LES INDEX  (chacun justifié par une mesure avant / après — voir README)
-- =============================================================================

-- PostgreSQL n'indexe pas les clés étrangères tout seul.
-- Index 1 : l'historique d'une carte — WHERE carte_id = ?
CREATE INDEX transactions_carte_idx ON transactions (carte_id);

-- Index 2 : les transactions d'une période — WHERE cree_le BETWEEN ? AND ?
CREATE INDEX transactions_cree_le_idx ON transactions (cree_le);

-- NB (README) : un index sur transactions(montant_euros) pour un filtre qui
-- ramène (presque) toutes les lignes (ex. montant_euros > 0) n'apporte rien :
-- PostgreSQL garde un Seq Scan. C'est l'exemple de l'index inutile.


-- =============================================================================
-- FIN. Démo rapide (à lancer à la main, pas exécutée ici) :
--   SELECT solde_points(1);
--   CALL echanger_recompense(1, 1);
--   SET ROLE emma;  SELECT * FROM vue_caissier LIMIT 3;  SELECT * FROM clients;  -- refusé
--   SET ROLE hugo;  SELECT * FROM vue_analyste;          SELECT * FROM transactions;  -- refusé
--   RESET ROLE;
-- =============================================================================
