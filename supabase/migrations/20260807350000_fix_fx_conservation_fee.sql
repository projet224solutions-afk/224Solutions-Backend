-- ═══════════════════════════════════════════════════════════════════════════
-- FATOME étage A — le contrôle de conservation FX doit DÉDUIRE LA COMMISSION.
--
-- TROUVÉ PAR LE TEST DU CORRIDOR DIASPORA (07/08/2026) : un transfert EUR→GNF parfait
-- (100 EUR envoyés + 5 EUR de commission = 105 débités ; 1 011 557 GNF crédités au taux mid
-- 10 115,5653) levait DEUX anomalies `fx_transfer_conservation` de sévérité CRITIQUE.
-- Cause : le trigger compare `credit_amount` à `amount × rate` où `amount` est le débit TOTAL
-- (commission comprise). Or le destinataire reçoit la conversion du montant ENVOYÉ, pas des
-- frais — qui restent à la plateforme. 105 × 10 115 = 1 062 134 ≠ 1 011 557 → fausse alerte.
--
-- CONSÉQUENCE SI ON NE CORRIGE PAS : chaque virement de la diaspora avec commission déclenche
-- une alerte critique (et un SMS). C'est exactement ce qui apprend à ignorer les alertes.
--
-- CORRECTIF : base de conversion = `amount − fee_amount` (les deux sont déjà dans la metadata
-- écrite par la primitive FX). Le contrôle reste STRICT (tolérance = 1 unité de la plus petite
-- décimale de la devise cible) et détecte toujours une vraie rupture de conservation.
-- Migration NOUVELLE. Trigger non bloquant (EXCEPTION → RETURN NULL) inchangé.
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

CREATE OR REPLACE FUNCTION public.fatome_check_fx_transfer()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_rate numeric; v_credit numeric; v_dst text; v_tol numeric;
  v_fee numeric; v_base numeric;
BEGIN
  IF COALESCE(NEW.metadata->>'fx', 'false') <> 'true' THEN RETURN NULL; END IF;

  v_rate := (NEW.metadata->>'rate_used')::numeric;
  IF v_rate IS NULL OR v_rate <= 0 THEN
    PERFORM public.fatome_raise('fx_transfer_no_rate', NEW.id::text, 'high',
      jsonb_build_object('metadata', NEW.metadata));
    RETURN NULL;
  END IF;

  v_credit := (NEW.metadata->>'credit_amount')::numeric;
  v_dst    := NEW.metadata->>'receiver_currency';
  -- 💡 La commission est débitée EN PLUS et reste à la plateforme : elle n'est JAMAIS convertie.
  v_fee    := COALESCE((NEW.metadata->>'fee_amount')::numeric, 0);
  v_base   := COALESCE(NEW.amount, 0) - GREATEST(v_fee, 0);

  IF v_credit IS NOT NULL AND v_base > 0 AND v_dst IS NOT NULL THEN
    v_tol := power(10, -public._ccy_decimals(v_dst));   -- 1 unité de la plus petite décimale
    IF abs(v_credit - round(v_base * v_rate, public._ccy_decimals(v_dst))) > v_tol THEN
      PERFORM public.fatome_raise('fx_transfer_conservation', NEW.id::text, 'critical',
        jsonb_build_object('amount', NEW.amount, 'fee', v_fee, 'base', v_base,
          'rate', v_rate, 'credit', v_credit, 'to', v_dst));
    END IF;
  END IF;

  RETURN NULL;
EXCEPTION WHEN OTHERS THEN RETURN NULL;
END; $$;

-- Le trigger trg_fatome_fx_transfer (AFTER INSERT ON enhanced_transactions) pointe déjà
-- sur cette fonction : rien à recréer (il resterait détecté « manquant » par la santé des
-- triggers si on le droppait sans le remettre).

COMMIT;
