-- ============================================================================
-- 🔎 INVESTIGATION — ARGENT HORS CIRCUIT (à exécuter dans Supabase par le PDG)
-- ----------------------------------------------------------------------------
-- LECTURE SEULE. Aucune écriture, aucune correction de solde. Ce script éclaire les
-- décisions ; les corrections (geler / régulariser avec trace / documenter) sont des
-- décisions humaines du PDG (cf. bloc « DÉCISIONS À PRENDRE » en fin de fichier).
--
-- Contexte : alertes du 9 juil 2026 — untraced_increase (3), treasury_balance_vs_ledger (1),
-- payout_without_treasury_debit (1), commission_without_treasury_debit (1).
-- La cause racine du mint (fonction credit_user_wallet_safe sans garde FX ni idempotence,
-- corps du 8 juin) a été CORRIGÉE le 9 juil (migration 20260709140000). Ce script sert à
-- mesurer les dégâts survenus AVANT le correctif et à décider cas par cas.
--
-- Mode d'emploi (3 lignes) :
--   1) Ouvrir le SQL editor Supabase, coller ce fichier, exécuter section par section.
--   2) Chaque section a un commentaire « → LIRE » expliquant comment interpréter le résultat.
--   3) Reporter les décisions dans le bloc final ; aucune écriture n'est faite par ce script.
-- ============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 1 — Les hausses de solde SANS transaction (untraced_increase)
-- Source = wallet_balance_audit (même critère que le monitor : delta>0, 7 jours,
-- aucune wallet_transactions reçue à ±10 min). → LIRE : chaque ligne = de l'argent
-- apparu sur un wallet sans trace de crédit. `txns_pm10 = 0` confirme l'absence de trace.
-- ─────────────────────────────────────────────────────────────────────────────
SELECT
  a.id                                   AS audit_id,
  a.wallet_id,
  a.user_id,
  '••• ' || right(regexp_replace(coalesce(p.phone, ''), '[^0-9]', '', 'g'), 3) AS phone_masque,
  p.role,
  a.old_balance,
  a.new_balance,
  a.delta,
  a.currency,
  a.changed_at,
  (SELECT count(*) FROM public.wallet_transactions wt
     WHERE wt.receiver_user_id = a.user_id
       AND wt.created_at BETWEEN a.changed_at - interval '10 minutes'
                             AND a.changed_at + interval '10 minutes') AS txns_pm10
FROM public.wallet_balance_audit a
LEFT JOIN public.profiles p ON p.id = a.user_id
WHERE a.delta > 0
  AND a.changed_at > now() - interval '7 days'
  AND NOT EXISTS (
    SELECT 1 FROM public.wallet_transactions wt
    WHERE wt.receiver_user_id = a.user_id
      AND wt.created_at BETWEEN a.changed_at - interval '10 minutes'
                            AND a.changed_at + interval '10 minutes')
ORDER BY a.changed_at DESC;

-- 1b — Contexte : 10 dernières transactions de CHAQUE wallet concerné (pour comprendre).
-- → LIRE : cherche un motif (crédit escrow/commission juste avant/après la hausse ?).
SELECT wt.receiver_user_id AS user_id, wt.transaction_id, wt.transaction_type, wt.amount,
       wt.net_amount, wt.currency, wt.status, wt.created_at, wt.description
FROM public.wallet_transactions wt
WHERE wt.receiver_user_id IN (
  SELECT DISTINCT a.user_id FROM public.wallet_balance_audit a
  WHERE a.delta > 0 AND a.changed_at > now() - interval '7 days'
    AND NOT EXISTS (SELECT 1 FROM public.wallet_transactions w2
      WHERE w2.receiver_user_id = a.user_id
        AND w2.created_at BETWEEN a.changed_at - interval '10 minutes' AND a.changed_at + interval '10 minutes')
)
ORDER BY wt.receiver_user_id, wt.created_at DESC
LIMIT 200;   -- borne : jusqu'à ~10 par wallet sur un petit nombre de wallets


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 2 — Corrélation avec la fonction écrasée
-- → LIRE : si les `changed_at` des hausses sont POSTÉRIEURS à la bascule vers le vieux
-- corps (fonction sans garde), la cause est très probablement l'ancienne fonction
-- (crédit sans trace/idempotence), PAS une intrusion. Le correctif du 9 juil coupe la source.
-- NB : l'horodatage exact de la régression n'est pas tracé rétroactivement (l'event trigger
-- installé le 9 juil datera TOUTE régression future). Repère approximatif = date de l'alerte.
-- ─────────────────────────────────────────────────────────────────────────────
SELECT
  min(a.changed_at) AS premiere_hausse_non_tracee,
  max(a.changed_at) AS derniere_hausse_non_tracee,
  count(*)          AS nb_hausses,
  sum(a.delta)      AS total_injecte_brut
FROM public.wallet_balance_audit a
WHERE a.delta > 0
  AND a.changed_at > now() - interval '30 days'
  AND NOT EXISTS (SELECT 1 FROM public.wallet_transactions wt
    WHERE wt.receiver_user_id = a.user_id
      AND wt.created_at BETWEEN a.changed_at - interval '10 minutes' AND a.changed_at + interval '10 minutes');


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 3 — Écart du coffre (treasury_balance_vs_ledger)
-- Formule COPIÉE de pdg_treasury_monitor_report() :
--   attendu = Σ crédits(net_amount) − Σ débits(net_amount) − Σ|payouts agents platform_revenue|
--   écart   = solde_coffre − attendu − baseline(ledger_offset)
-- → LIRE : `ecart` ≠ 0 (au-delà de ±1) = mouvement hors circuit. Signe + = argent en trop
-- (mint), signe − = argent manquant. Croiser avec la Section 4 et les 20 derniers mouvements.
-- ─────────────────────────────────────────────────────────────────────────────
WITH pdg AS (
  SELECT user_id FROM public.pdg_management WHERE is_active = true ORDER BY created_at NULLS LAST LIMIT 1
),
w AS (
  SELECT id AS wallet_id, COALESCE(balance,0) AS balance
  FROM public.wallets WHERE user_id = (SELECT user_id FROM pdg) AND currency = 'GNF'
),
agg AS (
  SELECT
    (SELECT COALESCE(sum(net_amount),0) FROM public.wallet_transactions WHERE receiver_wallet_id = (SELECT wallet_id FROM w) AND status='completed') AS credits,
    (SELECT COALESCE(sum(net_amount),0) FROM public.wallet_transactions WHERE sender_wallet_id   = (SELECT wallet_id FROM w) AND status='completed') AS debits,
    (SELECT COALESCE(sum(abs(amount)),0) FROM public.platform_revenue WHERE revenue_type='agent_commission_payout' AND amount < 0) AS agent_payouts,
    (SELECT COALESCE(ledger_offset,0) FROM public.pdg_treasury_baseline WHERE id = 1) AS baseline
)
SELECT
  (SELECT balance FROM w)                              AS solde_coffre,
  agg.credits, agg.debits, agg.agent_payouts, agg.baseline,
  (agg.credits - agg.debits - agg.agent_payouts)       AS attendu_hors_baseline,
  round((SELECT balance FROM w) - (agg.credits - agg.debits - agg.agent_payouts) - agg.baseline, 2) AS ecart
FROM agg;

-- 3b — 20 derniers mouvements du coffre (autour de la rupture).
-- → LIRE : repère un crédit sans contrepartie ou un débit dupliqué.
SELECT wt.transaction_id, wt.transaction_type,
       CASE WHEN wt.receiver_wallet_id = (SELECT id FROM public.wallets w2
              JOIN public.pdg_management pm ON pm.user_id=w2.user_id AND pm.is_active
              WHERE w2.currency='GNF' LIMIT 1) THEN 'CRÉDIT' ELSE 'DÉBIT' END AS sens,
       wt.amount, wt.net_amount, wt.currency, wt.status, wt.created_at, wt.description
FROM public.wallet_transactions wt
WHERE (wt.receiver_wallet_id = (SELECT id FROM public.wallets w2 JOIN public.pdg_management pm ON pm.user_id=w2.user_id AND pm.is_active WHERE w2.currency='GNF' LIMIT 1)
    OR wt.sender_wallet_id   = (SELECT id FROM public.wallets w2 JOIN public.pdg_management pm ON pm.user_id=w2.user_id AND pm.is_active WHERE w2.currency='GNF' LIMIT 1))
ORDER BY wt.created_at DESC
LIMIT 20;


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 4 — Les 2 « mints » (versements sans débit du coffre)
-- Requêtes COPIÉES du monitor. → LIRE : chaque ligne = argent versé sans débit tracé du
-- coffre. Le suggested_fix indique que l'historique DOCUMENTÉ est attendu (chantier coffre
-- du 4 juil) → distinguer ANCIEN (avant 2026-07-04) vs NOUVEAU (après) : le nouveau doit
-- être régularisé, l'ancien peut être ignoré s'il est documenté.
-- ─────────────────────────────────────────────────────────────────────────────

-- 4a — Versements actionnaires SANS débit coffre (payout_without_treasury_debit)
SELECT sp.id, sp.amount, sp.status, sp.created_at,
       '••• ' || right(coalesce(sp.shareholder_id::text, ''), 4) AS beneficiaire_masque,
       (sp.created_at >= timestamptz '2026-07-04') AS apres_chantier_coffre
FROM public.shareholder_payments sp
WHERE sp.status = 'sent_to_wallet'
  AND NOT EXISTS (SELECT 1 FROM public.wallet_transactions wt
                  WHERE wt.transaction_id = 'shareholder_payout:' || sp.id::text)
ORDER BY sp.created_at DESC;

-- 4b — Commissions agents SANS trace de débit coffre (commission_without_treasury_debit)
SELECT acl.transaction_id, sum(acl.amount) AS montant_total, min(acl.created_at) AS premiere,
       max(acl.created_at) AS derniere, count(*) AS nb_lignes,
       (max(acl.created_at) >= timestamptz '2026-07-04') AS apres_chantier_coffre
FROM public.agent_commissions_log acl
WHERE acl.status = 'validated' AND acl.transaction_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM public.platform_revenue pr
                  WHERE pr.revenue_type = 'agent_commission_payout'
                    AND pr.source_transaction_id = acl.transaction_id)
GROUP BY acl.transaction_id
ORDER BY derniere DESC;


-- ============================================================================
-- 🧭 DÉCISIONS À PRENDRE (PDG) — aucune n'est exécutée par ce script
-- ----------------------------------------------------------------------------
-- SECTION 1/2 (3 hausses non tracées) :
--   • Si postérieures au correctif → anomalie NOUVELLE : geler le wallet (wallet_status),
--     ouvrir un dossier, décider régularisation (créer la wallet_transactions manquante
--     avec trace + justification) OU reprise (débiter le montant injecté).
--   • Si antérieures et explicables par l'ancienne fonction → régulariser en traçant, pas de gel.
-- SECTION 3 (écart coffre) :
--   • Écart + (mint) → identifier le crédit sans contrepartie (Section 3b) ; régulariser via
--     débit tracé OU ajuster le baseline (pdg_treasury_baseline.ledger_offset) SI l'écart est
--     un historique connu/documenté — décision PDG explicite, jamais automatique.
--   • Écart − (manquant) → chercher un débit dupliqué / une libération non créditée.
-- SECTION 4 (2 mints) :
--   • ANCIEN + documenté (avant 2026-07-04) → ignorer (attendu, historique connu).
--   • NOUVEAU (après) → régulariser : journaliser le débit coffre correspondant (platform_revenue
--     / wallet_transactions) pour rétablir l'invariant, ou annuler le versement s'il est indu.
-- ============================================================================
