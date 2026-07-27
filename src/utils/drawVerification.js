import { verifyQuicknetBeacon } from './drandVerification.js';

function bytesToHex(bytes) {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('');
}

async function sha256Hex(value) {
  const input = value instanceof Uint8Array ? value : new TextEncoder().encode(String(value));
  const digest = await globalThis.crypto.subtle.digest('SHA-256', input);
  return bytesToHex(new Uint8Array(digest));
}

export async function verifyPublicDraw(snapshot) {
  const campaign = snapshot?.campaign || {};
  const candidates = [...(snapshot?.publicCandidateIds || [])].map(String).sort();
  const winners = snapshot?.publicWinners || [];
  const checks = {
    seedCommitment: false,
    beaconSignature: false,
    candidateManifest: false,
    winnerRanking: false,
  };
  try {
    checks.seedCommitment = await sha256Hex(campaign.seedReveal) === campaign.seedCommitment;
    checks.beaconSignature = await verifyQuicknetBeacon({
      chainHash: campaign.publicRandomnessChain,
      round: campaign.publicRandomnessRound,
      randomness: campaign.publicRandomness,
      signature: campaign.publicRandomnessSignature,
    });
    checks.candidateManifest = await sha256Hex(candidates.join('\n')) === campaign.candidateManifestHash;

    const ranked = await Promise.all(candidates.map(async (publicId) => ({
      publicId,
      score: await sha256Hex(`${campaign.seedReveal}:${campaign.publicRandomness}:${publicId}`),
    })));
    ranked.sort((left, right) => left.score.localeCompare(right.score)
      || left.publicId.localeCompare(right.publicId));
    const firstCount = Math.max(0, Number(campaign.prizePlan?.first || 0));
    const secondCount = Math.max(0, Number(campaign.prizePlan?.second || 0));
    const expected = ranked.slice(0, firstCount + secondCount).map((item, index) => ({
      publicId: item.publicId,
      prizeTier: index < firstCount ? 'first' : 'second',
      winnerOrder: index < firstCount ? index + 1 : index - firstCount + 1,
    }));
    const actual = [...winners]
      .map(({ publicId, prizeTier, winnerOrder }) => ({ publicId, prizeTier, winnerOrder }))
      .sort((left, right) => left.prizeTier.localeCompare(right.prizeTier)
        || left.winnerOrder - right.winnerOrder);
    checks.winnerRanking = JSON.stringify(actual) === JSON.stringify(expected);
  } catch {
    return { valid: false, checks };
  }
  return { valid: Object.values(checks).every(Boolean), checks };
}
