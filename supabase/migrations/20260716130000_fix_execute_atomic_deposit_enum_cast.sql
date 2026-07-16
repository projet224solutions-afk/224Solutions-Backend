-- ============================================================================
-- FIX RECHARGE WALLET — execute_atomic_deposit N'A JAMAIS FONCTIONNÉ.
--
-- PREUVES (prod, 16/07/2026)
--   • Appel direct → {"success":false,"error":"column \"transaction_type\" is of
--     type transaction_type but expression is of type text"} ;
--   • 0 ligne wallet_transactions avec metadata->>'source'='execute_atomic_deposit'
--     depuis la création de la RPC (20260621030000) → AUCUN dépôt via
--     /api/v2/wallet/deposit n'a abouti depuis ~1 mois.
--
-- CAUSES RACINES (même famille que le 42804 _acash_agent_wallet)
--   1. INSERT ... VALUES (..., p_source_type, ...) : p_source_type est une
--      VARIABLE text → PostgreSQL n'applique PAS de cast implicite text→enum
--      (seuls les littéraux le sont) → 42804 systématique, avalé par le
--      EXCEPTION WHEN OTHERS → success:false.
--   2. Latent : net_amount était v_credited alors que le CHECK impose
--      net_amount = amount - fee (fee=0). Dès qu'une quarantaine AML retient
--      une partie (v_credited < p_amount), le CHECK aurait annulé TOUT le
--      dépôt. On trace amount = net_amount = p_amount (l'argent du client,
--      quarantaine incluse) ; le détail quarantaine reste en metadata.
--
-- Corps par ailleurs STRICTEMENT identique à 20260621030000 (idempotence
-- double couche, rollback ledger→crédit, grants service_role uniquement).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.execute_atomic_deposit(
  p_user_id     uuid,
  p_amount      numeric,
  p_description text DEFAULT 'Dépôt',
  p_reference   text DEFAULT NULL,
  p_source_type text DEFAULT 'deposit'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_res       jsonb;
  v_credited  numeric;
  v_quar      numeric;
  v_wallet_id bigint;
  v_cur       text;
  v_tx_id     text;
  v_type      public.transaction_type;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Montant invalide');
  END IF;

  -- Cast EXPLICITE text→enum (LE fix). Valeur inconnue → erreur claire, pas de crédit.
  BEGIN
    v_type := p_source_type::public.transaction_type;
  EXCEPTION WHEN invalid_text_representation THEN
    RETURN jsonb_build_object('success', false,
      'error', 'p_source_type invalide pour transaction_type: ' || COALESCE(p_source_type, 'NULL'));
  END;

  -- Crédit + plafond/quarantaine AML (idempotent par source_txn_id), DANS cette transaction.
  v_res := public.credit_user_wallet_safe(p_user_id, p_amount, NULL, p_source_type, p_reference);

  -- Déjà crédité (idempotent) ou rien crédité → pas de nouvelle ligne d'historique.
  IF COALESCE((v_res->>'skipped')::boolean, false) THEN
    RETURN jsonb_build_object('success', true, 'skipped', true,
      'credited', COALESCE((v_res->>'credited')::numeric, 0),
      'wallet_id', (v_res->>'wallet_id'), 'currency', v_res->>'currency');
  END IF;

  v_credited  := COALESCE((v_res->>'credited')::numeric, 0);
  v_quar      := COALESCE((v_res->>'quarantined')::numeric, 0);
  v_wallet_id := (v_res->>'wallet_id')::bigint;
  v_cur       := COALESCE(v_res->>'currency', 'GNF');
  v_tx_id     := public.generate_transaction_id();

  -- Ledger dans la MÊME transaction (si échec → rollback du crédit ci-dessus).
  INSERT INTO public.wallet_transactions (
    transaction_id, sender_wallet_id, receiver_wallet_id, sender_user_id, receiver_user_id,
    transaction_type, amount, net_amount, status, currency, description, metadata)
  VALUES (
    v_tx_id, NULL, v_wallet_id, NULL, p_user_id,
    v_type, p_amount, p_amount, 'completed', v_cur, p_description,
    jsonb_build_object('reference', p_reference, 'source', 'execute_atomic_deposit',
                       'credited', v_credited, 'quarantined', v_quar));

  RETURN jsonb_build_object('success', true, 'credited', v_credited, 'quarantined', v_quar,
    'wallet_id', v_wallet_id, 'currency', v_cur, 'transaction_id', v_tx_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION public.execute_atomic_deposit(uuid, numeric, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.execute_atomic_deposit(uuid, numeric, text, text, text) TO service_role;
