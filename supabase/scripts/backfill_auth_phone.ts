/**
 * 🔁 BACKFILL — téléphone comme IDENTIFIANT auth pour les profils existants.
 *
 * Objectif : permettre le login « email OU téléphone + mot de passe » aux comptes déjà créés
 * (avant l'ajout du téléphone auth). Parcourt `profiles` ayant un téléphone, normalise en E.164
 * selon le pays du profil (`country_code`) et pose `phone` + `phone_confirm:true` sur le compte
 * auth via `admin.updateUserById`.
 *
 * SÉCURITÉ / PRUDENCE :
 *   • DRY-RUN par défaut : n'écrit RIEN. Passer `--apply` pour exécuter réellement.
 *   • IGNORE et LISTE : formats invalides + doublons (2 profils → même numéro, ou numéro déjà
 *     lié à un AUTRE compte auth). Ces comptes gardent le login par email uniquement.
 *   • Pagination + petit délai (rate-limit doux) pour ménager l'API Auth.
 *   • Idempotent : un profil dont le compte a déjà ce téléphone est sauté (no-op).
 *
 * Usage (NON exécuté automatiquement) :
 *   cd backend && npx tsx supabase/scripts/backfill_auth_phone.ts            # dry-run
 *   cd backend && npx tsx supabase/scripts/backfill_auth_phone.ts --apply    # applique
 *   LANGS/BATCH n/a. Variables lues depuis backend/.env (service_role).
 */
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';
import { formatPhoneIntl } from '../../src/services/phoneFormat.js';

const APPLY = process.argv.includes('--apply');
const PAGE = 500;
const SLEEP_MS = 40; // rate-limit doux entre écritures Auth

const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
if (!url || !key) { console.error('❌ SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY manquants (backend/.env)'); process.exit(1); }
const sb = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const isValidE164 = (p: string) => /^\+[1-9]\d{6,14}$/.test(p);

interface ProfRow { id: string; phone: string | null; country_code: string | null; email: string | null; }

async function loadProfilesWithPhone(): Promise<ProfRow[]> {
  const rows: ProfRow[] = [];
  let from = 0;
  for (;;) {
    const { data, error } = await sb
      .from('profiles')
      .select('id, phone, country_code, email')
      .not('phone', 'is', null)
      .range(from, from + PAGE - 1);
    if (error) throw new Error(`lecture profiles: ${error.message}`);
    if (!data || data.length === 0) break;
    rows.push(...(data as ProfRow[]));
    if (data.length < PAGE) break;
    from += PAGE;
  }
  return rows;
}

async function main() {
  console.log(`\n🔁 Backfill auth phone — mode ${APPLY ? 'APPLY (écriture réelle)' : 'DRY-RUN (aucune écriture)'}\n`);

  const profiles = await loadProfilesWithPhone();
  console.log(`Profils avec téléphone : ${profiles.length}`);

  const invalid: Array<{ id: string; email: string | null; phone: string | null; reason: string }> = [];
  const candidates: Array<{ id: string; email: string | null; e164: string }> = [];

  for (const p of profiles) {
    const e164 = formatPhoneIntl(String(p.phone || ''), p.country_code || undefined);
    if (!isValidE164(e164)) {
      invalid.push({ id: p.id, email: p.email, phone: p.phone, reason: `format invalide → ${e164}` });
      continue;
    }
    candidates.push({ id: p.id, email: p.email, e164 });
  }

  // Détection des doublons INTRA-profils : 2 profils → même numéro normalisé → ambigu, on saute les deux.
  const byPhone = new Map<string, string[]>();
  for (const c of candidates) byPhone.set(c.e164, [...(byPhone.get(c.e164) || []), c.id]);
  const dupPhones = new Set([...byPhone.entries()].filter(([, ids]) => ids.length > 1).map(([e]) => e));

  const toApply = candidates.filter((c) => !dupPhones.has(c.e164));
  const intraDuplicates = candidates.filter((c) => dupPhones.has(c.e164));

  let applied = 0, skippedSame = 0, alreadyRegistered = 0, failed = 0;
  const conflicts: Array<{ id: string; email: string | null; e164: string; reason: string }> = [];

  for (const c of toApply) {
    if (!APPLY) { applied++; continue; } // dry-run : preview rapide (pas d'appel Auth par profil)

    // Idempotence : compte a-t-il déjà ce téléphone ?
    const { data: got } = await sb.auth.admin.getUserById(c.id);
    const current = got?.user?.phone ? `+${String(got.user.phone).replace(/^\+/, '')}` : null;
    if (current && current === c.e164) { skippedSame++; continue; }

    const { error } = await sb.auth.admin.updateUserById(c.id, { phone: c.e164, phone_confirm: true } as any);
    if (error) {
      if (/phone/i.test(error.message) && /(already|registered|exists|taken)/i.test(error.message)) {
        alreadyRegistered++;
        conflicts.push({ id: c.id, email: c.email, e164: c.e164, reason: 'numéro déjà lié à un autre compte' });
      } else {
        failed++;
        conflicts.push({ id: c.id, email: c.email, e164: c.e164, reason: error.message });
      }
    } else {
      applied++;
    }
    await sleep(SLEEP_MS);
  }

  // ── Rapport ──
  console.log('\n────────── RÉSUMÉ ──────────');
  console.log(`À traiter (numéro unique valide) : ${toApply.length}`);
  console.log(`${APPLY ? 'Appliqués' : 'Seraient appliqués'} : ${applied}`);
  console.log(`Déjà à jour (sautés)             : ${skippedSame}`);
  console.log(`Doublons intra-profils (sautés)  : ${intraDuplicates.length}`);
  console.log(`Numéro déjà pris ailleurs        : ${alreadyRegistered}`);
  console.log(`Formats invalides (sautés)       : ${invalid.length}`);
  console.log(`Échecs divers                    : ${failed}`);

  const csv: string[] = ['type,profile_id,email,phone_or_e164,reason'];
  for (const d of intraDuplicates) csv.push(`intra_duplicate,${d.id},${d.email || ''},${d.e164},plusieurs profils meme numero`);
  for (const d of invalid) csv.push(`invalid,${d.id},${d.email || ''},${d.phone || ''},${d.reason}`);
  for (const d of conflicts) csv.push(`conflict,${d.id},${d.email || ''},${d.e164},${d.reason}`);
  if (csv.length > 1) {
    console.log('\n────────── LIGNES IGNORÉES (CSV) ──────────');
    console.log(csv.join('\n'));
  }

  if (!APPLY) console.log('\nℹ️  DRY-RUN : aucune écriture. Relancer avec --apply pour exécuter.');
}

main().catch((e) => { console.error('❌', e?.message || e); process.exit(1); });
