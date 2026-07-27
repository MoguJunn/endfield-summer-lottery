import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { solvePowChallenge } from '../src/utils/powChallengeCore.js';

const stateText = await readFile(resolve('.local-e2e/state.json'), 'utf8');
const state = JSON.parse(stateText.replace(/^\uFEFF/u, ''));
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

async function request(url, options = {}) {
  const headers = new Headers(options.headers || {});
  if (cookies.size) {
    headers.set('Cookie', [...cookies].map(([name, value]) => `${name}=${value}`).join('; '));
  }
  const response = await fetch(url, { ...options, headers, redirect: 'manual' });
  captureCookies(response);
  return response;
}

async function json(response, label) {
  const body = await response.json().catch(() => null);
  if (!response.ok || body?.success === false) {
    throw new Error(`${label} failed (${response.status}): ${JSON.stringify(body)}`);
  }
  return body;
}

const loginResponse = await fetch(`${state.apiUrl}/auth/v1/token?grant_type=password`, {
  method: 'POST',
  headers: {
    apikey: state.anonKey,
    'Content-Type': 'application/json',
  },
  body: JSON.stringify({ email: state.email, password: state.password }),
});
const login = await loginResponse.json();
if (!loginResponse.ok || !login.access_token) {
  throw new Error(`Supabase password login failed: ${JSON.stringify(login)}`);
}

const bootstrapResponse = await request(`${state.mainUrl}api/auth/session`, {
  method: 'POST',
  headers: {
    Authorization: `Bearer ${login.access_token}`,
    Origin: state.mainUrl.replace(/\/$/u, ''),
  },
});
await json(bootstrapResponse, 'main-site session bootstrap');

const ssoStart = await request(`${state.lotteryUrl}api/auth/sso/start`);
if (ssoStart.status !== 303) {
  throw new Error(`lottery SSO start failed (${ssoStart.status})`);
}
const mainSsoUrl = new URL(ssoStart.headers.get('location'));

const mainSso = await request(mainSsoUrl);
if (mainSso.status !== 303) {
  throw new Error(`main-site ticket issue failed (${mainSso.status})`);
}
const callback = new URL(mainSso.headers.get('location'));
const fragment = new URLSearchParams(callback.hash.slice(1));
const ticket = fragment.get('sso_ticket');
const stateValue = fragment.get('state');
if (!ticket || !stateValue) {
  throw new Error('main-site ticket redirect did not contain the expected fragment');
}

const exchangeResponse = await request(`${state.lotteryUrl}api/auth/sso/callback`, {
  method: 'POST',
  headers: {
    'Content-Type': 'application/json',
    Origin: state.lotteryUrl.replace(/\/$/u, ''),
  },
  body: JSON.stringify({ ticket, state: stateValue }),
});
await json(exchangeResponse, 'lottery SSO exchange');

const snapshotResponse = await request(`${state.lotteryUrl}api/lottery`);
const snapshot = await json(snapshotResponse, 'authenticated snapshot');
if (snapshot.data?.user?.username !== 'Demo Participant') {
  throw new Error(`unexpected lottery user: ${JSON.stringify(snapshot.data?.user)}`);
}
if (snapshot.data?.campaign?.prizePlan?.second !== 2) {
  throw new Error(`unexpected second-prize count: ${JSON.stringify(snapshot.data?.campaign?.prizePlan)}`);
}

const csrf = decodeURIComponent(cookies.get('summer_lottery_csrf') || '');
if (!csrf) throw new Error('lottery CSRF cookie was not created');
const entryHeaders = {
  'Content-Type': 'application/json',
  Origin: state.lotteryUrl.replace(/\/$/u, ''),
  'x-csrf-token': csrf,
};
const challengeResponse = await request(`${state.lotteryUrl}api/auth-pow-challenge`, {
  method: 'POST',
  headers: {
    'Content-Type': 'application/json',
    Origin: state.lotteryUrl.replace(/\/$/u, ''),
  },
  body: JSON.stringify({ action: 'lottery_enter' }),
});
const challengePayload = await json(challengeResponse, 'lottery PoW challenge');
const powPayload = await solvePowChallenge(challengePayload.data.challenge);
const entryBody = JSON.stringify({
  contactValue: 'demo-contact',
  notificationConfirmed: true,
  captchaProvider: 'pow',
  powPayload,
});
const firstEntryResponse = await request(`${state.lotteryUrl}api/lottery/enter`, {
  method: 'POST', headers: entryHeaders, body: entryBody,
});
const firstEntry = await json(firstEntryResponse, 'first entry');
if (JSON.stringify(firstEntry).includes('demo-contact')) {
  throw new Error('private delivery contact leaked into the browser response');
}
const secondEntryResponse = await request(`${state.lotteryUrl}api/lottery/enter`, {
  method: 'POST', headers: entryHeaders, body: entryBody,
});
const secondEntry = await json(secondEntryResponse, 'idempotent entry retry');
if (firstEntry.data?.entry?.publicId !== secondEntry.data?.entry?.publicId || secondEntry.data?.entryCount !== 1) {
  throw new Error('entry retry was not idempotent');
}

const storedContactResponse = await fetch(
  `${state.apiUrl}/rest/v1/rpc/inspect_summer_lottery_contact_storage`,
  {
    method: 'POST',
    headers: {
      apikey: state.serviceRoleKey,
      Authorization: `Bearer ${state.serviceRoleKey}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ p_campaign_id: 'community-lottery' }),
  },
);
const storedContact = await storedContactResponse.json().catch(() => null);
if (
  !storedContactResponse.ok
  || Number(storedContact?.entryCount) !== 1
  || Number(storedContact?.encryptedCount) !== 1
  || Number(storedContact?.invalidCount) !== 0
  || JSON.stringify(storedContact).includes('demo-contact')
  || JSON.stringify(storedContact).includes('olc1.')
) {
  throw new Error('database did not persist the expected encrypted contact envelope');
}

const directContactResponse = await fetch(
  `${state.apiUrl}/rest/v1/summer_lottery_entries?select=contact_value&campaign_id=eq.community-lottery&limit=1`,
  {
    headers: {
      apikey: state.serviceRoleKey,
      Authorization: `Bearer ${state.serviceRoleKey}`,
    },
  },
);
if (directContactResponse.ok) {
  throw new Error('service_role unexpectedly bypassed audited contact access');
}

console.log(JSON.stringify({
  success: true,
  user: snapshot.data.user.username,
  entryNumber: firstEntry.data.entry.entryNumber,
  entryCount: secondEntry.data.entryCount,
  checks: [
    'password_login',
    'main_site_session',
    'sso_ticket',
    'lottery_session',
    'csrf',
    'pow_captcha',
    'private_delivery_contact',
    'encrypted_contact_storage',
    'audited_contact_column_boundary',
    'entry_idempotency',
  ],
}, null, 2));
