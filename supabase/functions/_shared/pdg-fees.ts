/**
 * 🏦 PDG FEES - Lecture dynamique des frais depuis pdg_settings
 * Toutes les Edge Functions doivent utiliser ce module pour obtenir les taux de frais.
 * Les valeurs sont configurables par le PDG dans l'interface d'administration.
 */

// Clés des paramètres dans pdg_settings
export const FEE_KEYS = {
  DEPOSIT: 'deposit_fee_percentage',
  WITHDRAWAL: 'withdrawal_fee_percentage',
  WALLET_TRANSFER: 'wallet_fee_percentage',
  INTERNATIONAL_TRANSFER: 'international_transfer_fee_percentage',
  PURCHASE_COMMISSION: 'commission_achats',
  SERVICE_COMMISSION: 'commission_services',
  // Transfer limits
  MIN_TRANSFER_AMOUNT: 'min_transfer_amount',
  MAX_TRANSFER_AMOUNT: 'max_transfer_amount',
  MAX_DAILY_TRANSFER: 'max_daily_transfer_amount',
  MAX_INTERNATIONAL_TRANSFER: 'max_international_transfer_amount',
  MIN_INTERNATIONAL_TRANSFER: 'min_international_transfer_amount',
} as const;

// Valeurs par défaut (fallback si pdg_settings est vide)
const DEFAULT_FEES: Record<string, number> = {
  [FEE_KEYS.DEPOSIT]: 2,
  [FEE_KEYS.WITHDRAWAL]: 1.5,
  [FEE_KEYS.WALLET_TRANSFER]: 2.5,
  [FEE_KEYS.INTERNATIONAL_TRANSFER]: 1,
  [FEE_KEYS.PURCHASE_COMMISSION]: 5,
  [FEE_KEYS.SERVICE_COMMISSION]: 0.5,
  [FEE_KEYS.MIN_TRANSFER_AMOUNT]: 100,
  [FEE_KEYS.MAX_TRANSFER_AMOUNT]: 50000000,
  [FEE_KEYS.MAX_DAILY_TRANSFER]: 50000000,
  [FEE_KEYS.MAX_INTERNATIONAL_TRANSFER]: 50000000,
  [FEE_KEYS.MIN_INTERNATIONAL_TRANSFER]: 500,
};

/**
 * Lire un taux de frais depuis pdg_settings
 * @param supabaseAdmin - Client Supabase avec service_role_key
 * @param settingKey - Clé du paramètre (utiliser FEE_KEYS)
 * @returns Le taux en pourcentage (ex: 2.5 pour 2.5%)
 */
export async function getPdgFeeRate(
  supabaseAdmin: any,
  settingKey: string
): Promise<number> {
  const defaultValue = DEFAULT_FEES[settingKey] ?? 0;

  try {
    const { data, error } = await supabaseAdmin
      .from('pdg_settings')
      .select('setting_value')
      .eq('setting_key', settingKey)
      .maybeSingle();

    if (error || !data) {
      console.log(`[PDG-FEES] No pdg_settings for '${settingKey}', using default: ${defaultValue}%`);
      return defaultValue;
    }

    // setting_value peut être { value: X } ou directement X
    const raw = data.setting_value;
    const rate = typeof raw === 'object' && raw !== null && 'value' in raw
      ? Number(raw.value)
      : Number(raw);

    if (isNaN(rate) || rate < 0) {
      console.log(`[PDG-FEES] Invalid value for '${settingKey}': ${raw}, using default: ${defaultValue}%`);
      return defaultValue;
    }

    console.log(`[PDG-FEES] '${settingKey}' = ${rate}% (from pdg_settings)`);
    return rate;
  } catch (err) {
    console.error(`[PDG-FEES] Error reading '${settingKey}':`, err);
    return defaultValue;
  }
}

/**
 * Calculer le montant des frais
 */
export function calculateFee(amount: number, feeRate: number): { feeAmount: number; netAmount: number } {
  const feeAmount = Math.round(amount * (feeRate / 100) * 100) / 100;
  const netAmount = Math.round((amount - feeAmount) * 100) / 100;
  return { feeAmount, netAmount };
}
