export const AFRICAN_BANK_SOURCE_URLS: string[] = [
  'https://www.bcrg-guinee.org',
  'https://bcrg-guinee.org',
  'https://www.bcrg.org',
  'https://bcrg.org',
  'https://www.bceao.int',
  'https://www.beac.int',
  'https://www.bankofalgeria.dz',
  'https://www.bankofbotswana.bw',
  'https://www.banquecentrale.bi',
  'https://www.bankofcapeverde.cv',
  'https://www.beac.int/en',
  'https://www.bcc.cd',
  'https://www.bceao.int/en',
  'https://www.banque-centrale.mg',
  'https://www.banquecentraledjibouti.dj',
  'https://www.cbe.org.eg',
  'https://www.nbe.gov.et',
  'https://www.bdeac.org',
  'https://www.bog.gov.gh',
  'https://www.bsl.gov.gm',
  'https://www.bstp.st',
  'https://www.bankofuganda.co.ug',
  'https://www.centralbank.go.ke',
  'https://www.banquecentrale.tg',
  'https://www.bct.gov.tn',
  'https://www.bis.org/country/za.htm',
  'https://www.sarb.co.za',
  'https://www.resbank.co.za',
  'https://www.bankofzambia.co.zm',
  'https://www.rbz.co.zw',
  'https://www.cbn.gov.ng',
  'https://www.bou.or.ug',
  'https://www.bot.or.tz',
  'https://www.bnr.rw',
  'https://www.bcm.mg',
  'https://www.banquecentrale.ml',
  'https://www.banquecentrale.ne',
  'https://www.banquecentrale.sn',
  'https://www.banquecentrale.ci',
  'https://www.banquecentrale.cm',
  'https://www.banquecentrale.ga',
  'https://www.banquecentrale.cg',
  'https://www.banquecentrale.cf',
  'https://www.banquecentrale.td',
  'https://www.bankofmauritius.com',
  'https://www.bankofnamibia.com.na',
  'https://www.bankofsierraleone.org',
  'https://www.centralbank.org.sz',
  'https://www.bankofliberia.org.lr',
  'https://www.bankofsouthsudan.org',
  'https://www.bankoferitrea.org',
  'https://www.ecobank.com',
  'https://www.orabank.net',
  'https://www.afreximbank.com',
  'https://www.afdb.org',
];

const AFRICAN_BANK_HOSTS = new Set(
  AFRICAN_BANK_SOURCE_URLS.map((url) => {
    try {
      return new URL(url).hostname.toLowerCase();
    } catch {
      return '';
    }
  }).filter(Boolean)
);

const AFRICAN_COUNTRY_TLDS = new Set([
  'dz', 'ao', 'bj', 'bw', 'bf', 'bi', 'cm', 'cv', 'cf', 'td', 'km', 'cg', 'cd', 'ci',
  'dj', 'eg', 'gq', 'er', 'et', 'ga', 'gm', 'gh', 'gn', 'gw', 'ke', 'ls', 'lr', 'ly',
  'mg', 'mw', 'ml', 'mr', 'mu', 'ma', 'mz', 'na', 'ne', 'ng', 'rw', 'st', 'sn', 'sc',
  'sl', 'so', 'za', 'ss', 'sd', 'sz', 'tz', 'tg', 'tn', 'ug', 'zm', 'zw', 're', 'yt',
]);

const BANK_KEYWORDS = [
  'bank', 'banque', 'banco', 'centralbank', 'banquecentrale',
  'reservebank', 'resbank', 'cbn', 'bceao', 'beac', 'bcrg',
  'afreximbank', 'ecobank', 'orabank',
];

function hasBankKeyword(input: string): boolean {
  const normalized = input.toLowerCase();
  return BANK_KEYWORDS.some((keyword) => normalized.includes(keyword));
}

function hasAfricanCountryTld(hostname: string): boolean {
  const parts = hostname.toLowerCase().split('.').filter(Boolean);
  if (parts.length === 0) return false;

  const tld = parts[parts.length - 1];
  const secondLevel = parts.length >= 2 ? parts[parts.length - 2] : '';

  if (AFRICAN_COUNTRY_TLDS.has(tld)) return true;
  if (tld === 'uk' && AFRICAN_COUNTRY_TLDS.has(secondLevel)) return true;

  return false;
}

export function isAfricanBankSourceUrl(sourceUrl: string | null | undefined): boolean {
  if (!sourceUrl) return false;
  try {
    const url = new URL(sourceUrl);
    const host = url.hostname.toLowerCase();
    const hostAndPath = `${host}${url.pathname}`.toLowerCase();

    // 1) Explicit curated list (high confidence)
    if (AFRICAN_BANK_HOSTS.has(host)) return true;

    // 2) Subdomains of curated list
    for (const knownHost of AFRICAN_BANK_HOSTS) {
      if (host.endsWith(`.${knownHost}`)) return true;
    }

    // 2.1) Explicit Guinea central bank host aliases
    if (host.includes('bcrg')) {
      return true;
    }

    // 3) Generic coverage: african ccTLD + bank keyword
    if (hasAfricanCountryTld(host) && hasBankKeyword(hostAndPath)) {
      return true;
    }

    // 4) Regional institutions hosted on .org/.int/.com domains
    if (hasBankKeyword(hostAndPath) && /africa|african|uemoa|cemac|westafrica|eastafrica/i.test(hostAndPath)) {
      return true;
    }

    return false;
  } catch {
    return false;
  }
}
