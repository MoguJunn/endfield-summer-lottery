export const GATEWAY_CONTRACT_VERSION = 1;

function text(value, maxLength = 8192) {
  return String(value || '').trim().slice(0, maxLength);
}

function nullableText(value, maxLength = 8192) {
  if (value === null || value === undefined || value === '') return null;
  return text(value, maxLength);
}

function finiteNumber(value, fallback = null) {
  if (value === null || value === undefined || value === '') return fallback;
  const number = Number(value);
  return Number.isFinite(number) ? number : fallback;
}

function sanitizeEntry(entry) {
  if (!entry || typeof entry !== 'object') return null;
  return {
    publicId: text(entry.publicId, 100),
    entryNumber: finiteNumber(entry.entryNumber),
    eligible: entry.eligible !== false,
    createdAt: nullableText(entry.createdAt, 80),
  };
}

function sanitizeWinner(winner, { own = false } = {}) {
  if (!winner || typeof winner !== 'object') return null;
  const result = {
    prizeTier: text(winner.prizeTier, 40),
    winnerOrder: finiteNumber(winner.winnerOrder),
  };
  if (own) {
    result.claimStatus = text(winner.claimStatus, 40);
    return result;
  }
  return {
    ...result,
    entryNumber: finiteNumber(winner.entryNumber),
    publicId: text(winner.publicId, 100),
    displayName: text(winner.displayName, 120),
  };
}

function sanitizeCampaign(campaign) {
  if (!campaign || typeof campaign !== 'object') return null;
  return {
    id: text(campaign.id, 100),
    title: text(campaign.title, 160),
    startsAt: nullableText(campaign.startsAt, 80),
    closesAt: nullableText(campaign.closesAt, 80),
    drawsAt: nullableText(campaign.drawsAt, 80),
    drawnAt: nullableText(campaign.drawnAt, 80),
    phase: text(campaign.phase, 40),
    prizePlan: {
      first: Math.max(0, finiteNumber(campaign.prizePlan?.first, 0)),
      second: Math.max(0, finiteNumber(campaign.prizePlan?.second, 0)),
    },
    seedCommitment: nullableText(campaign.seedCommitment, 128),
    seedReveal: nullableText(campaign.seedReveal, 8192),
    publicRandomnessChain: nullableText(campaign.publicRandomnessChain, 128),
    publicRandomnessRound: finiteNumber(campaign.publicRandomnessRound),
    publicRandomness: nullableText(campaign.publicRandomness, 128),
    publicRandomnessSignature: nullableText(campaign.publicRandomnessSignature, 1024),
    candidateManifestHash: nullableText(campaign.candidateManifestHash, 128),
  };
}

export function sanitizeSnapshot(snapshot, { site, mainSiteUrl = '' } = {}) {
  const publicCandidateIds = Array.isArray(snapshot?.publicCandidateIds)
    ? snapshot.publicCandidateIds.slice(0, 1_000_000).map((value) => text(value, 100)).filter(Boolean)
    : [];
  const publicWinners = Array.isArray(snapshot?.publicWinners)
    ? snapshot.publicWinners.slice(0, 1000).map((winner) => sanitizeWinner(winner)).filter(Boolean)
    : [];
  return {
    contractVersion: GATEWAY_CONTRACT_VERSION,
    campaign: sanitizeCampaign(snapshot?.campaign),
    entryCount: Math.max(0, finiteNumber(snapshot?.entryCount, 0)),
    user: snapshot?.user && typeof snapshot.user === 'object'
      ? {
        username: text(snapshot.user.username, 120),
      }
      : null,
    entry: sanitizeEntry(snapshot?.entry),
    ownWinner: sanitizeWinner(snapshot?.ownWinner, { own: true }),
    publicWinners,
    publicCandidateIds,
    site,
    mainSiteUrl: text(mainSiteUrl, 500),
  };
}

export function sanitizeEntryResult(result) {
  return {
    entry: sanitizeEntry(result?.entry),
    entryCount: Math.max(0, finiteNumber(result?.entryCount, 0)),
  };
}
