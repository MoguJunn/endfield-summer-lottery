const DEFAULT_AUTH_CAPTCHA_ACTIONS = new Set(['lottery_enter']);

const PROVIDER_SCRIPT_URLS = {
  turnstile: 'https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit',
};

function splitList(rawValue) {
  return String(rawValue || '')
    .split(',')
    .map((value) => value.trim().toLowerCase())
    .filter(Boolean);
}

function normalizeMode(rawMode, rawEnabled) {
  const enabled = String(rawEnabled || '').trim().toLowerCase();
  const fallbackMode = ['1', 'true', 'yes', 'on'].includes(enabled) ? 'enforce' : 'off';
  const mode = String(rawMode || fallbackMode).trim().toLowerCase();
  return ['off', 'monitor', 'enforce'].includes(mode) ? mode : 'off';
}

function isPlaceholderSiteKey(siteKey) {
  const normalized = String(siteKey || '').trim().toUpperCase();
  return !normalized || normalized.includes('PASTE_') || normalized.includes('_HERE') || normalized.includes('YOUR_') || normalized === 'SITE_KEY';
}

export function getAuthCaptchaClientConfig({ action, env = import.meta.env } = {}) {
  const normalizedAction = String(action || '').trim().toLowerCase();
  const mode = normalizeMode(env?.VITE_AUTH_CAPTCHA_MODE, env?.VITE_AUTH_CAPTCHA_ENABLED);
  const configuredActions = splitList(env?.VITE_AUTH_CAPTCHA_REQUIRED_ACTIONS);
  const requiredActions = configuredActions.length ? new Set(configuredActions) : DEFAULT_AUTH_CAPTCHA_ACTIONS;
  const actionCovered = requiredActions.has(normalizedAction);
  const siteKey = String(env?.VITE_AUTH_CAPTCHA_SITE_KEY || env?.VITE_TURNSTILE_SITE_KEY || '').trim();
  return {
    action: normalizedAction,
    mode,
    provider: 'turnstile',
    siteKey,
    actionCovered,
    enabled: mode !== 'off' && actionCovered,
    required: mode === 'enforce' && actionCovered,
    monitoring: mode === 'monitor' && actionCovered,
    configured: !isPlaceholderSiteKey(siteKey),
  };
}

export function ensureAuthCaptchaProviderScriptLoaded(config, win, doc, timeoutMs = 8000) {
  if (win?.turnstile?.render) return Promise.resolve(true);
  if (!doc?.createElement || !doc?.querySelector) return Promise.resolve(false);
  const existing = doc.querySelector('script[data-auth-captcha-script="turnstile"]');
  if (existing) {
    return new Promise((resolve) => {
      const timer = win.setTimeout(() => resolve(Boolean(win?.turnstile?.render)), timeoutMs);
      existing.addEventListener?.('load', () => {
        win.clearTimeout(timer);
        resolve(Boolean(win?.turnstile?.render));
      }, { once: true });
      existing.addEventListener?.('error', () => {
        win.clearTimeout(timer);
        resolve(false);
      }, { once: true });
    });
  }
  return new Promise((resolve) => {
    const script = doc.createElement('script');
    const timer = win.setTimeout(() => resolve(Boolean(win?.turnstile?.render)), timeoutMs);
    script.src = PROVIDER_SCRIPT_URLS.turnstile;
    script.async = true;
    script.defer = true;
    script.setAttribute('data-auth-captcha-script', 'turnstile');
    script.onload = () => {
      win.clearTimeout(timer);
      resolve(Boolean(win?.turnstile?.render));
    };
    script.onerror = () => {
      win.clearTimeout(timer);
      resolve(false);
    };
    (doc.head || doc.body || doc.documentElement).appendChild(script);
  });
}
