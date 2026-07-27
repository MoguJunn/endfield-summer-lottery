import { solvePowChallenge } from '../src/utils/powChallengeCore.js';

const origin = String(process.env.LOTTERY_DEMO_URL || 'http://localhost:5175').replace(/\/$/u, '');
const cookies = new Map();

function captureCookies(response) {
  const values = typeof response.headers.getSetCookie === 'function'
    ? response.headers.getSetCookie()
    : [];
  for (const value of values) {
    const pair = value.split(';', 1)[0];
    const separator = pair.indexOf('=');
    if (separator <= 0) continue;
    const name = pair.slice(0, separator);
    const content = pair.slice(separator + 1);
    if (content) cookies.set(name, content);
    else cookies.delete(name);
  }
}

async function request(path, options = {}) {
  const headers = new Headers(options.headers || {});
  if (cookies.size) {
    headers.set('Cookie', [...cookies].map(([name, value]) => `${name}=${value}`).join('; '));
  }
  const response = await fetch(`${origin}${path}`, {
    ...options,
    headers,
    redirect: options.redirect || 'manual',
  });
  captureCookies(response);
  return response;
}

async function readSuccess(response, label) {
  const body = await response.json().catch(() => null);
  if (!response.ok || body?.success !== true) {
    throw new Error(`${label} failed (${response.status}): ${JSON.stringify(body)}`);
  }
  return body.data;
}

const guest = await readSuccess(await request('/api/lottery'), 'guest snapshot');
if (guest.user !== null || guest.contractVersion !== 1) {
  throw new Error(`unexpected guest contract: ${JSON.stringify(guest)}`);
}

const login = await request('/api/auth/sso/start');
if (login.status !== 303 || !cookies.has('summer_lottery_session') || !cookies.has('summer_lottery_csrf')) {
  throw new Error('demo login did not create the expected host-only session cookies');
}

const authenticated = await readSuccess(await request('/api/lottery'), 'authenticated snapshot');
if (authenticated.user?.username !== 'Demo Participant') {
  throw new Error(`unexpected demo identity: ${JSON.stringify(authenticated.user)}`);
}

const challenge = await readSuccess(await request('/api/auth-pow-challenge', {
  method: 'POST',
  headers: { Origin: origin, 'Content-Type': 'application/json' },
  body: JSON.stringify({ action: 'lottery_enter' }),
}), 'PoW challenge');
const powPayload = await solvePowChallenge(challenge.challenge);
const csrf = decodeURIComponent(cookies.get('summer_lottery_csrf') || '');
const entered = await readSuccess(await request('/api/lottery/enter', {
  method: 'POST',
  headers: {
    Origin: origin,
    'Content-Type': 'application/json',
    'x-csrf-token': csrf,
  },
  body: JSON.stringify({
    contactValue: 'demo-contact',
    notificationConfirmed: false,
    captchaProvider: 'pow',
    powPayload,
  }),
}), 'entry');

if (!entered.entry?.publicId || entered.entryCount !== 1 || JSON.stringify(entered).includes('demo-contact')) {
  throw new Error(`entry response violated the public contract: ${JSON.stringify(entered)}`);
}

const repeated = await readSuccess(await request('/api/lottery/enter', {
  method: 'POST',
  headers: {
    Origin: origin,
    'Content-Type': 'application/json',
    'x-csrf-token': csrf,
  },
  body: JSON.stringify({
    contactValue: 'demo-contact',
    notificationConfirmed: false,
    captchaProvider: 'pow',
    powPayload,
  }),
}), 'idempotent entry');
if (repeated.entry?.publicId !== entered.entry.publicId || repeated.entryCount !== 1) {
  throw new Error('entry retry was not idempotent');
}

console.log(JSON.stringify({
  success: true,
  provider: 'demo',
  contractVersion: authenticated.contractVersion,
  entryNumber: entered.entry.entryNumber,
  checks: ['login', 'pow', 'entry', 'privacy_whitelist', 'entry_idempotency'],
}, null, 2));
