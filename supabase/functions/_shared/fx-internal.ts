/**
 * Shared FX helper – reads rates from currency_exchange_rates table.
 * No external API calls. Supports direct, inverse and USD-pivot lookups.
 * The rates in the table already include the 3% margin applied by african-fx-collect.
 */

interface FxResult {
  rate: number;
  source: "identity" | "table-direct" | "table-inverse" | "table-usd-pivot" | "table-gnf-pivot";
  fetched_at: string;
}

export async function getInternalFxRate(
  supabaseAdmin: any,
  from: string,
  to: string,
): Promise<FxResult> {
  const f = from.toUpperCase();
  const t = to.toUpperCase();

  if (f === t) return { rate: 1, source: "identity", fetched_at: new Date().toISOString() };

  // 1. Direct pair
  const { data: direct } = await supabaseAdmin
    .from("currency_exchange_rates")
    .select("rate, retrieved_at")
    .eq("from_currency", f)
    .eq("to_currency", t)
    .eq("is_active", true)
    .maybeSingle();

  if (direct?.rate && Number(direct.rate) > 0) {
    return { rate: Number(direct.rate), source: "table-direct", fetched_at: direct.retrieved_at || new Date().toISOString() };
  }

  // 2. Inverse pair
  const { data: inverse } = await supabaseAdmin
    .from("currency_exchange_rates")
    .select("rate, retrieved_at")
    .eq("from_currency", t)
    .eq("to_currency", f)
    .eq("is_active", true)
    .maybeSingle();

  if (inverse?.rate && Number(inverse.rate) > 0) {
    return { rate: 1 / Number(inverse.rate), source: "table-inverse", fetched_at: inverse.retrieved_at || new Date().toISOString() };
  }

  // 3. USD pivot: from→USD then USD→to
  const { data: fromUsd } = await supabaseAdmin
    .from("currency_exchange_rates")
    .select("rate")
    .eq("from_currency", "USD")
    .eq("to_currency", f)
    .eq("is_active", true)
    .maybeSingle();

  const { data: toUsd } = await supabaseAdmin
    .from("currency_exchange_rates")
    .select("rate")
    .eq("from_currency", "USD")
    .eq("to_currency", t)
    .eq("is_active", true)
    .maybeSingle();

  if (fromUsd?.rate && Number(fromUsd.rate) > 0 && toUsd?.rate && Number(toUsd.rate) > 0) {
    // from→USD = 1/USD→from, USD→to = USD→to  =>  from→to = (USD→to)/(USD→from)
    const rate = Number(toUsd.rate) / Number(fromUsd.rate);
    return { rate, source: "table-usd-pivot", fetched_at: new Date().toISOString() };
  }

  // 4. GNF bridge: f→GNF→t (fallback pour les devises sans taux USD)
  if (f !== "GNF" && t !== "GNF") {
    const [
      { data: fToGnf },
      { data: gnfToF },
      { data: gnfToT },
      { data: tToGnf },
    ] = await Promise.all([
      supabaseAdmin.from("currency_exchange_rates").select("rate").eq("from_currency", f).eq("to_currency", "GNF").eq("is_active", true).maybeSingle(),
      supabaseAdmin.from("currency_exchange_rates").select("rate").eq("from_currency", "GNF").eq("to_currency", f).eq("is_active", true).maybeSingle(),
      supabaseAdmin.from("currency_exchange_rates").select("rate").eq("from_currency", "GNF").eq("to_currency", t).eq("is_active", true).maybeSingle(),
      supabaseAdmin.from("currency_exchange_rates").select("rate").eq("from_currency", t).eq("to_currency", "GNF").eq("is_active", true).maybeSingle(),
    ]);

    const fromToGnfRate = fToGnf?.rate && Number(fToGnf.rate) > 0
      ? Number(fToGnf.rate)
      : gnfToF?.rate && Number(gnfToF.rate) > 0
        ? 1 / Number(gnfToF.rate)
        : null;

    const gnfToToRate = gnfToT?.rate && Number(gnfToT.rate) > 0
      ? Number(gnfToT.rate)
      : tToGnf?.rate && Number(tToGnf.rate) > 0
        ? 1 / Number(tToGnf.rate)
        : null;

    if (fromToGnfRate !== null && gnfToToRate !== null) {
      return { rate: fromToGnfRate * gnfToToRate, source: "table-gnf-pivot", fetched_at: new Date().toISOString() };
    }
  }

  throw new Error(`Taux de change introuvable pour ${f}→${t}. Vérifiez que les taux sont collectés.`);
}
