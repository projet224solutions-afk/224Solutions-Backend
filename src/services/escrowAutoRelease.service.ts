/**
 * 💰 AUTO-LIBÉRATION DES ESCROWS — migrée de l'Edge Function vers le backend (08/08/2026).
 *
 * POURQUOI CETTE MIGRATION (décision PDG) : la libération d'escrow est de la FINANCE. Elle
 * vivait dans une Edge Function, 3e lieu de déploiement, avec une dérive PROUVÉE — la version
 * déployée datait d'avril alors que le code source était corrigé : pendant ~2 mois, des
 * escrows sont passés à `released` SANS que le vendeur soit payé (5 cas, 401 000 GNF).
 * Ici, le code déployé suit `git push` et le job est leader-gardé comme les autres.
 *
 * RÈGLE ABSOLUE : aucune logique de crédit n'est réécrite. On APPELLE `release_escrow_to_seller`
 * — le MÊME primitif que la confirmation manuelle de l'acheteur. Un seul chemin de libération
 * dans tout le système, atomique et fail-closed.
 *
 * SÉCURITÉ DE BASCULE : le primitif refuse tout escrow qui n'est plus en `pending`/`held`
 * (`IF v_escrow.status NOT IN ('pending','held') THEN RETURN skipped`) — même si l'Edge
 * Function et ce job tournaient en même temps, un escrow ne peut pas être payé deux fois.
 */
import { logger } from '../config/logger.js';
import { supabaseAdmin } from '../config/supabase.js';

const BATCH_LIMIT = Number(process.env.ESCROW_AUTO_RELEASE_BATCH || 50);
/** Interrupteur de bascule : le job ne tourne QUE si explicitement activé. */
export const escrowAutoReleaseEnabled = (): boolean =>
  String(process.env.ESCROW_AUTO_RELEASE_BACKEND || '').toLowerCase() === 'true';

interface RunResult { released: number; failed: number; scanned: number }

/**
 * Un passage : lot borné, isolation d'erreur PAR escrow, journal + heartbeat Fatome.
 * Ne lève JAMAIS : un échec est une donnée, pas un crash de cycle.
 */
export async function runEscrowAutoRelease(): Promise<RunResult> {
  const t0 = Date.now();
  const res: RunResult = { released: 0, failed: 0, scanned: 0 };
  let ok = true;
  let err: string | null = null;

  try {
    // Mêmes critères que l'Edge Function : échu, confirmé par le vendeur, hors litige.
    const { data: due, error } = await supabaseAdmin
      .from('escrow_transactions')
      .select('id, order_id')
      .eq('status', 'held')
      .lt('auto_release_at', new Date().toISOString())
      .not('seller_confirmed_at', 'is', null)
      .is('dispute_status', null)
      .limit(BATCH_LIMIT);                    // lot BORNÉ : jamais de balayage infini
    if (error) throw new Error(`sélection: ${error.message}`);

    res.scanned = (due || []).length;

    for (const escrow of (due || []) as { id: string; order_id: string | null }[]) {
      try {
        const { data: rel, error: relErr } = await supabaseAdmin.rpc('release_escrow_to_seller' as any, {
          p_escrow_id: escrow.id,
          p_reason: 'auto_release_backend',
        });
        // Le primitif gère idempotence + autorisation. On n'avance QUE sur un vrai succès.
        if (relErr || (rel as any)?.success === false) {
          res.failed++;
          logger.warn(`[EscrowAutoRelease] échec ${escrow.id}: ${relErr?.message || (rel as any)?.error || 'inconnu'}`);
          continue;
        }
        if ((rel as any)?.skipped === true) continue;   // déjà libéré ailleurs → ni succès ni échec
        res.released++;

        // La commande suit — APRÈS le succès du primitif seulement (jamais l'inverse).
        if (escrow.order_id) {
          const nowIso = new Date().toISOString();
          await supabaseAdmin
            .from('orders')
            .update({ status: 'delivered', delivered_at: nowIso, updated_at: nowIso })
            .eq('id', escrow.order_id)
            .in('status', ['shipped', 'confirmed', 'preparing']);
        }
      } catch (e: any) {
        // Isolation PAR escrow : un cas qui casse n'arrête pas le lot.
        res.failed++;
        logger.warn(`[EscrowAutoRelease] exception ${escrow.id}: ${e?.message || e}`);
      }
    }

    if (res.released > 0 || res.failed > 0) {
      logger.info(`[EscrowAutoRelease] ${res.released} libéré(s), ${res.failed} échec(s) sur ${res.scanned} échu(s)`);
    }
  } catch (e: any) {
    ok = false;
    err = String(e?.message || e).slice(0, 500);
    logger.warn(`[EscrowAutoRelease] cycle en erreur: ${err}`);
  } finally {
    // Contrat commun du registre Fatome : le Général supervise ce job comme les autres.
    try {
      await supabaseAdmin.rpc('fatome_beat' as any, {
        p_key: 'escrow_auto_release', p_ok: ok && res.failed === 0,
        p_error: err || (res.failed > 0 ? `${res.failed} libération(s) en échec` : null),
      });
    } catch (e: any) { logger.warn(`[EscrowAutoRelease] beat: ${e?.message || e}`); }
    try {
      await supabaseAdmin.from('fatome_activity_log').insert({
        fatome_key: 'escrow_auto_release',
        duration_ms: Date.now() - t0,
        ok: ok && res.failed === 0,
        message: ok
          ? `${res.released} escrow(s) libéré(s), ${res.failed} échec(s) sur ${res.scanned} échu(s)`
          : `Cycle en erreur : ${err}`,
        volume: { scanned: res.scanned, released: res.released, failed: res.failed, batch_limit: BATCH_LIMIT },
      });
    } catch { /* best-effort */ }
  }

  return res;
}

class EscrowAutoReleaseService {
  private interval: ReturnType<typeof setInterval> | null = null;
  private running = false;

  start(): void {
    if (this.interval) return;
    if (!escrowAutoReleaseEnabled()) {
      logger.info('[EscrowAutoRelease] DÉSACTIVÉ (ESCROW_AUTO_RELEASE_BACKEND != true) — bascule non activée');
      return;
    }
    logger.info('[EscrowAutoRelease] actif — libération automatique toutes les 15 min (leader)');
    void this.tick();
    this.interval = setInterval(() => { void this.tick(); }, 15 * 60_000);
  }
  stop(): void { if (this.interval) { clearInterval(this.interval); this.interval = null; } }

  private async tick(): Promise<void> {
    if (this.running) return;
    this.running = true;
    try { await runEscrowAutoRelease(); } finally { this.running = false; }
  }
}

export const escrowAutoReleaseService = new EscrowAutoReleaseService();
