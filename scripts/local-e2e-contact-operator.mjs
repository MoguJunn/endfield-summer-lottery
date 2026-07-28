import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';

const stateText = await readFile(resolve('.local-e2e/state.json'), 'utf8');
const state = JSON.parse(stateText.replace(/^\uFEFF/u, ''));
const mainOrigin = state.mainUrl.replace(/\/$/u, '');
const campaignId = 'community-lottery';

async function login(email, password) {
  const response = await fetch(`${state.apiUrl}/auth/v1/token?grant_type=password`, {
    method: 'POST',
    headers: {
      apikey: state.anonKey,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ email, password }),
  });
  const body = await response.json().catch(() => null);
  if (!response.ok || !body?.access_token) {
    throw new Error(`operator login failed (${response.status}): ${JSON.stringify(body)}`);
  }
  return body.access_token;
}

async function request(path, token, options = {}) {
  const headers = new Headers(options.headers || {});
  headers.set('Authorization', `Bearer ${token}`);
  headers.set('Origin', mainOrigin);
  const response = await fetch(`${mainOrigin}${path}`, { ...options, headers });
  const body = await response.json().catch(() => null);
  return { response, body };
}

const participantToken = await login(state.email, state.password);
const superAdminAttempt = await request(
  `/api/admin-summer-lottery-contacts?campaignId=${campaignId}`,
  participantToken,
);
if (
  superAdminAttempt.response.status !== 403
  || superAdminAttempt.body?.code !== 'lottery_operator_capability_required'
) {
  throw new Error(
    `super-admin unexpectedly inherited contact access: ${JSON.stringify(superAdminAttempt.body)}`,
  );
}

const operatorToken = await login(
  state.contactOperatorEmail,
  state.contactOperatorPassword,
);
const profileResponse = await fetch(
  `${state.apiUrl}/rest/v1/profiles?select=id,role&email=eq.${encodeURIComponent(state.contactOperatorEmail)}`,
  {
    headers: {
      apikey: state.serviceRoleKey,
      Authorization: `Bearer ${state.serviceRoleKey}`,
    },
  },
);
const profiles = await profileResponse.json().catch(() => null);
if (!profileResponse.ok || profiles?.[0]?.role !== 'user') {
  throw new Error(`contact operator is not a normal user profile: ${JSON.stringify(profiles)}`);
}

const targetResult = await request(
  `/api/admin-summer-lottery-contacts?campaignId=${campaignId}`,
  operatorToken,
);
if (!targetResult.response.ok || targetResult.body?.success !== true) {
  throw new Error(
    `contact operator target list failed (${targetResult.response.status}): ${JSON.stringify(targetResult.body)}`,
  );
}
if (
  targetResult.body?.permissions?.canRead !== true
  || targetResult.body?.permissions?.canPurge !== true
  || !Array.isArray(targetResult.body?.targets)
  || targetResult.body.targets.length !== 1
  || JSON.stringify(targetResult.body).includes('demo-contact')
  || JSON.stringify(targetResult.body).includes('olc1.')
) {
  throw new Error(`contact target boundary failed: ${JSON.stringify(targetResult.body)}`);
}

const entryId = targetResult.body.targets[0].entryId;
const readResult = await request('/api/admin-summer-lottery-contacts', operatorToken, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({
    campaignId,
    entryId,
    reason: 'winner_notification',
  }),
});
if (
  !readResult.response.ok
  || readResult.body?.contact?.contactValue !== 'demo-contact'
  || JSON.stringify(readResult.body).includes('olc1.')
) {
  throw new Error(
    `contact operator read failed (${readResult.response.status}): ${JSON.stringify(readResult.body)}`,
  );
}

const purgeResult = await request('/api/admin-summer-lottery-contacts', operatorToken, {
  method: 'DELETE',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({
    campaignId,
    entryId,
    reason: 'manual_privacy_request',
  }),
});
if (!purgeResult.response.ok || purgeResult.body?.result?.cleared !== true) {
  throw new Error(
    `contact operator purge failed (${purgeResult.response.status}): ${JSON.stringify(purgeResult.body)}`,
  );
}

const afterPurge = await request(
  `/api/admin-summer-lottery-contacts?campaignId=${campaignId}`,
  operatorToken,
);
if (
  !afterPurge.response.ok
  || afterPurge.body?.targets?.[0]?.contactAvailable !== false
) {
  throw new Error(`purged contact remained available: ${JSON.stringify(afterPurge.body)}`);
}

console.log(JSON.stringify({
  success: true,
  operatorRole: profiles[0].role,
  entryId,
  checks: [
    'super_admin_has_no_implicit_contact_access',
    'normal_user_contact_read_capability',
    'normal_user_contact_purge_capability',
    'single_contact_plaintext_only',
    'encrypted_envelope_not_returned',
    'purged_contact_unavailable',
  ],
}, null, 2));
