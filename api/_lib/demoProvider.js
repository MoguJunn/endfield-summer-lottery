import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { getRuntimeConfig } from './env.js';
import { getPublicSiteConfig, validateContactValue } from './publicConfig.js';

const STORE_KEY = Symbol.for('open-lottery.demo-store.v1');

function getStore() {
  if (!globalThis[STORE_KEY]) {
    globalThis[STORE_KEY] = {
      sessions: new Set(),
      entries: new Map(),
      drawnAt: null,
      winners: [],
    };
  }
  return globalThis[STORE_KEY];
}

function hash(value) {
  return createHash('sha256').update(String(value), 'utf8').digest('hex');
}

function isoDate(value, fallback) {
  const date = new Date(value || fallback);
  return Number.isFinite(date.getTime()) ? date.toISOString() : new Date(fallback).toISOString();
}

function getDemoCampaign(env = process.env) {
  const runtime = getRuntimeConfig(env);
  const store = getStore();
  const now = Date.now();
  const startsAt = isoDate(env.LOTTERY_CAMPAIGN_STARTS_AT, now - 60 * 60 * 1000);
  const closesAt = isoDate(env.LOTTERY_CAMPAIGN_CLOSES_AT, now + 30 * 24 * 60 * 60 * 1000);
  const drawsAt = isoDate(env.LOTTERY_CAMPAIGN_DRAWS_AT, new Date(closesAt).getTime());
  let prizePlan = { first: 2, second: 2 };
  try {
    const parsed = JSON.parse(env.LOTTERY_PRIZE_PLAN_JSON || '{}');
    prizePlan = {
      first: Math.max(0, Number.parseInt(parsed.first, 10) || 0),
      second: Math.max(0, Number.parseInt(parsed.second, 10) || 0),
    };
  } catch {
    // Keep the safe demo defaults.
  }
  const currentTime = Date.now();
  const phase = store.drawnAt
    ? 'drawn'
    : currentTime < new Date(startsAt).getTime()
      ? 'scheduled'
      : currentTime < new Date(closesAt).getTime()
        ? 'open'
        : currentTime < new Date(drawsAt).getTime()
          ? 'waiting_draw'
          : 'ready_to_draw';
  return {
    id: runtime.campaignId,
    title: String(env.LOTTERY_CAMPAIGN_TITLE || 'Open Lottery Demo').slice(0, 160),
    startsAt,
    closesAt,
    drawsAt,
    drawnAt: store.drawnAt,
    phase,
    prizePlan,
    seedCommitment: hash('open-lottery-demo-seed'),
    seedReveal: store.drawnAt ? 'open-lottery-demo-seed' : null,
    publicRandomnessChain: 'demo-provider',
    publicRandomnessRound: 1,
    publicRandomness: store.drawnAt ? hash('open-lottery-demo-randomness') : null,
    publicRandomnessSignature: store.drawnAt ? 'demo-only-not-a-public-beacon-signature' : null,
    candidateManifestHash: store.drawnAt
      ? hash([...store.entries.values()].map((entry) => entry.publicId).sort().join('\n'))
      : null,
  };
}

function getDemoUser(sessionTokenHash) {
  if (!sessionTokenHash || !getStore().sessions.has(sessionTokenHash)) return null;
  return {
    id: 'demo-participant',
    username: 'Demo Participant',
    role: 'user',
  };
}

function loadSnapshot(payload, env) {
  const store = getStore();
  const sessionTokenHash = String(payload.sessionTokenHash || '');
  const user = getDemoUser(sessionTokenHash);
  const entry = user ? store.entries.get(user.id) || null : null;
  const campaign = getDemoCampaign(env);
  const ownWinner = campaign.phase === 'drawn' && entry
    ? store.winners.find((winner) => winner.publicId === entry.publicId) || {
      prizeTier: 'participation',
      winnerOrder: null,
      claimStatus: 'granted',
    }
    : null;
  return {
    campaign,
    entryCount: store.entries.size,
    user,
    entry,
    ownWinner,
    publicWinners: campaign.phase === 'drawn' ? store.winners : [],
    publicCandidateIds: campaign.phase === 'drawn'
      ? [...store.entries.values()].map((item) => item.publicId).sort()
      : [],
  };
}

function enterDemo(payload, env) {
  const store = getStore();
  const site = getPublicSiteConfig(env);
  const sessionTokenHash = String(payload.sessionTokenHash || '');
  const user = getDemoUser(sessionTokenHash);
  if (!user) throw Object.assign(new Error('lottery_session_invalid'), { code: 'lottery_session_invalid' });
  if (!validateContactValue(payload.contactValue, site.contact.format)) {
    throw Object.assign(new Error('invalid_contact_value'), { code: 'invalid_contact_value' });
  }
  if (site.contact.notificationRequired && payload.notificationConfirmed !== true) {
    throw Object.assign(new Error('notification_confirmation_required'), { code: 'notification_confirmation_required' });
  }
  const existing = store.entries.get(user.id);
  if (existing) return { ...existing, alreadyEntered: true };
  const campaign = getDemoCampaign(env);
  if (campaign.phase !== 'open') throw Object.assign(new Error('campaign_not_open'), { code: 'campaign_not_open' });
  const entryNumber = store.entries.size + 1;
  const entry = {
    id: randomBytes(16).toString('hex'),
    publicId: randomUUID(),
    entryNumber,
    eligible: true,
    createdAt: new Date().toISOString(),
    alreadyEntered: false,
  };
  store.entries.set(user.id, {
    ...entry,
    contactType: site.contact.format,
    contactValue: String(payload.contactValue),
    notificationConfirmedAt: payload.notificationConfirmed ? new Date().toISOString() : null,
  });
  return entry;
}

function drawDemo(env) {
  const store = getStore();
  const campaign = getDemoCampaign(env);
  const ranked = [...store.entries.values()].sort((left, right) => hash(left.publicId).localeCompare(hash(right.publicId)));
  store.winners = ranked.slice(0, campaign.prizePlan.first + campaign.prizePlan.second).map((entry, index) => ({
    prizeTier: index < campaign.prizePlan.first ? 'first' : 'second',
    winnerOrder: index < campaign.prizePlan.first ? index + 1 : index - campaign.prizePlan.first + 1,
    entryNumber: entry.entryNumber,
    publicId: entry.publicId,
    displayName: 'D***t',
    claimStatus: 'pending',
  }));
  store.drawnAt = new Date().toISOString();
  return { campaignId: campaign.id, entryCount: store.entries.size, winners: store.winners };
}

export async function callDemoProvider(action, payload = {}, env = process.env) {
  const store = getStore();
  if (action === 'snapshot') return loadSnapshot(payload, env);
  if (action === 'demo-login') {
    store.sessions.add(String(payload.sessionTokenHash || ''));
    return { authenticated: true };
  }
  if (action === 'enter') return enterDemo(payload, env);
  if (action === 'logout') {
    const sessionTokenHash = String(payload.sessionTokenHash || '');
    store.sessions.delete(sessionTokenHash);
    return { revoked: true };
  }
  if (action === 'prepare') return { campaignId: getRuntimeConfig(env).campaignId, status: 'open' };
  if (action === 'draw') return drawDemo(env);
  if (action === 'health') return { schemaReady: true, campaignPrepared: true, provider: 'demo' };
  throw Object.assign(new Error('action_not_allowed'), { code: 'action_not_allowed' });
}

export function createDemoPowChallenge() {
  const difficulty = 1;
  const issuedAt = Date.now();
  return {
    action: 'lottery_enter',
    algorithm: 'sha256-chain-v1',
    challengeId: `demo-${randomBytes(8).toString('hex')}`,
    difficulty,
    expiresAt: issuedAt + 10 * 60 * 1000,
    issuedAt,
    seed: randomBytes(16).toString('hex'),
    signature: 'demo-only-not-verified',
    totalSteps: 1800,
  };
}

export function resetDemoProvider() {
  delete globalThis[STORE_KEY];
}
