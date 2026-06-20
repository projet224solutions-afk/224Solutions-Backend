/**
 * 💊 RAPPELS DE PRISE DE MÉDICAMENTS (Phase 6) — planificateur.
 * ---------------------------------------------------------------------------
 * Tourne UNIQUEMENT sur le worker (RUN_BACKGROUND_JOBS=true), comme la surveillance
 * et le dropship. Verrou Redis distribué → un seul conteneur exécute la fenêtre.
 *
 * À chaque tick : trouve les créneaux de prise « dus » (heure atteinte aujourd'hui,
 * traitement non expiré) et envoie UNE notification in-app par créneau. Le journal
 * medication_reminder_sent (clé primaire reminder_id+jour+heure) garantit l'idempotence :
 * aucun doublon même si le job repasse, redémarre, ou tourne sur plusieurs instances.
 *
 * Guinée = UTC+0 → l'heure TIME stockée == heure locale (REMINDER_TZ_OFFSET_MIN=0 par défaut).
 * Le rappel n'est PAS un conseil médical : on rappelle juste l'heure saisie par le client.
 */

import { logger } from '../config/logger.js';
import { locks, isRedisConnected } from '../config/redis.js';
import { supabaseAdmin } from '../config/supabase.js';
import { createNotification } from './notification.service.js';

interface ReminderRow {
  id: string; client_id: string | null; medication_name: string;
  times: string[]; duration_days: number | null; start_date: string; active: boolean;
}

class MedicationReminderScheduler {
  private interval: ReturnType<typeof setInterval> | null = null;
  private isRunning = false;
  private readonly intervalMs: number;
  private readonly tzOffsetMin: number;

  constructor() {
    this.intervalMs = Number(process.env.MEDICATION_REMINDER_INTERVAL_MS || 5 * 60_000);
    this.tzOffsetMin = Number(process.env.REMINDER_TZ_OFFSET_MIN || 0); // Guinée = UTC+0
  }

  start(): void {
    if (this.interval) return;
    logger.info(`[MedicationReminder] démarrage (toutes les ${this.intervalMs}ms)`);
    void this.tick('startup');
    this.interval = setInterval(() => void this.tick('interval'), this.intervalMs);
  }

  stop(): void {
    if (!this.interval) return;
    clearInterval(this.interval);
    this.interval = null;
    logger.info('[MedicationReminder] arrêté');
  }

  private async tick(trigger: string): Promise<void> {
    const ttl = Math.max(30, Math.floor(this.intervalMs / 1000) - 5);
    if (isRedisConnected()) {
      const got = await locks.acquire('pharmacy:medication-reminder:tick', ttl);
      if (!got) return; // une autre instance détient la fenêtre
    }
    await this.runOnce(trigger);
  }

  /** Heure locale (minutes depuis minuit) + date locale "YYYY-MM-DD". */
  private nowLocal(): { dateStr: string; minutes: number } {
    const local = new Date(Date.now() + this.tzOffsetMin * 60_000);
    const dateStr = local.toISOString().slice(0, 10);
    const minutes = local.getUTCHours() * 60 + local.getUTCMinutes();
    return { dateStr, minutes };
  }

  private toMinutes(t: string): number {
    const [h, m] = String(t).split(':');
    return (Number(h) || 0) * 60 + (Number(m) || 0);
  }

  async runOnce(trigger = 'manual'): Promise<{ scanned: number; sent: number }> {
    if (this.isRunning) { logger.info('[MedicationReminder] cycle précédent en cours, skip'); return { scanned: 0, sent: 0 }; }
    this.isRunning = true;
    let scanned = 0; let sent = 0;
    try {
      const { dateStr, minutes } = this.nowLocal();
      const windowMin = Math.ceil(this.intervalMs / 60_000) + 1; // tolérance si tick en retard
      const { data, error } = await supabaseAdmin
        .from('medication_reminders')
        .select('id, client_id, medication_name, times, duration_days, start_date, active')
        .eq('active', true)
        .lte('start_date', dateStr);
      if (error) { logger.error(`[MedicationReminder] scan échoué: ${error.message}`); return { scanned: 0, sent: 0 }; }

      for (const r of (data || []) as ReminderRow[]) {
        scanned += 1;
        if (!r.client_id) continue;
        // Traitement expiré ?
        if (r.duration_days && r.duration_days > 0) {
          const end = new Date(r.start_date + 'T00:00:00Z');
          end.setUTCDate(end.getUTCDate() + r.duration_days);
          if (new Date(dateStr + 'T00:00:00Z') >= end) continue;
        }
        for (const slot of r.times || []) {
          const slotMin = this.toMinutes(slot);
          // Créneau « dû » : heure atteinte dans la fenêtre écoulée [now-window, now].
          if (slotMin > minutes || slotMin < minutes - windowMin) continue;
          const slotTime = slot.length === 5 ? `${slot}:00` : slot;
          // Idempotence : insère le journal AVANT d'envoyer (ON CONFLICT = déjà notifié → skip).
          const { data: ins, error: insErr } = await supabaseAdmin
            .from('medication_reminder_sent')
            .upsert({ reminder_id: r.id, slot_date: dateStr, slot_time: slotTime }, { onConflict: 'reminder_id,slot_date,slot_time', ignoreDuplicates: true })
            .select('reminder_id');
          if (insErr) { logger.error(`[MedicationReminder] journal échoué: ${insErr.message}`); continue; }
          if (!ins || ins.length === 0) continue; // déjà envoyé pour ce créneau
          const ok = await createNotification({
            userId: r.client_id,
            title: '💊 Rappel de prise',
            message: `C'est l'heure de prendre : ${r.medication_name} (${slot.slice(0, 5)}).`,
            type: 'medication_reminder',
            metadata: { route: '/pharmacie', reminder_id: r.id, slot: slot.slice(0, 5) },
          });
          if (ok) sent += 1;
        }
      }
      if (sent > 0 || trigger === 'manual') logger.info(`[MedicationReminder] cycle ${trigger}: scannés=${scanned}, envoyés=${sent}`);
      return { scanned, sent };
    } catch (e: any) {
      logger.error(`[MedicationReminder] cycle échoué: ${e?.message}`);
      return { scanned, sent };
    } finally {
      this.isRunning = false;
    }
  }
}

export const medicationReminderScheduler = new MedicationReminderScheduler();
