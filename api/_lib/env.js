export const DEFAULT_CAMPAIGN_ID = 'community-lottery';
export const DEFAULT_SSO_AUDIENCE = 'open-lottery';

function normalizeString(value, maxLength = 4096) {
  return String(value || '').trim().slice(0, maxLength);
}

function normalizeOrigin(value) {
  try {
    const url = new URL(normalizeString(value));
    if (!['http:', 'https:'].includes(url.protocol)) {
      return '';
    }
    return url.origin;
  } catch {
    return '';
  }
}

function parsePositiveInteger(value, fallback) {
  const parsed = Number.parseInt(String(value || ''), 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function normalizeProvider(value) {
  const provider = normalizeString(value || 'main-site', 40).toLowerCase();
  return provider === 'demo' ? 'demo' : 'main-site';
}

function isStrongSecret(value) {
  const normalized = normalizeString(value, 8192);
  return normalized.length >= 43 && !normalized.toLowerCase().includes('replace-');
}

export function getRuntimeConfig(env = process.env) {
  const provider = normalizeProvider(env.LOTTERY_PROVIDER);
  const isDemo = provider === 'demo';
  const demoProductionBlocked = isDemo && (
    String(env.NODE_ENV || '').toLowerCase() === 'production'
    || String(env.VERCEL_ENV || '').toLowerCase() === 'production'
  );
  return {
    provider,
    isDemo,
    demoProductionBlocked,
    campaignId: normalizeString(env.LOTTERY_CAMPAIGN_ID || DEFAULT_CAMPAIGN_ID, 100),
    lotteryOrigin: normalizeOrigin(env.LOTTERY_SITE_URL),
    mainSiteOrigin: normalizeOrigin(env.MAIN_SITE_URL),
    backendSecret: normalizeString(env.LOTTERY_BACKEND_SECRET, 8192),
    sessionSecret: normalizeString(
      env.LOTTERY_SESSION_SECRET || (isDemo ? 'demo-only-session-secret-never-use-in-production-00000000' : ''),
      8192,
    ),
    sessionTtlSeconds: parsePositiveInteger(env.LOTTERY_SESSION_TTL_SECONDS, 7 * 24 * 60 * 60),
    audience: normalizeString(env.LOTTERY_SSO_AUDIENCE || DEFAULT_SSO_AUDIENCE, 100),
  };
}

export function getMissingRuntimeKeys(config) {
  const required = [
    ['LOTTERY_SITE_URL', config.lotteryOrigin],
    ['LOTTERY_SESSION_SECRET', isStrongSecret(config.sessionSecret)],
  ];

  if (config.demoProductionBlocked) {
    required.push(['LOTTERY_PROVIDER_DEMO_DISABLED_IN_PRODUCTION', false]);
  }

  if (!config.isDemo) {
    required.push(
      ['MAIN_SITE_URL', config.mainSiteOrigin],
      ['LOTTERY_BACKEND_SECRET', isStrongSecret(config.backendSecret)],
    );
  }

  return required.filter(([, value]) => !value).map(([key]) => key);
}
