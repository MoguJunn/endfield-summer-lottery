// @vitest-environment node

import { createHash, webcrypto } from 'node:crypto';
import { beforeAll, describe, expect, it } from 'vitest';
import { verifyPublicDraw } from './drawVerification.js';

const QUICKNET_CHAIN = '52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971';
const QUICKNET_ROUND = 1000;
const QUICKNET_RANDOMNESS = 'fe290beca10872ef2fb164d2aa4442de4566183ec51c56ff3cd603d930e54fdd';
const QUICKNET_SIGNATURE = 'b44679b9a59af2ec876b1a6b1ad52ea9b1615fc3982b19576350f93447cb1125e342b73a8dd2bacbe47e4b6b63ed5e39';

function sha256Text(value) {
  return createHash('sha256').update(value, 'utf8').digest('hex');
}

describe('public draw verification', () => {
  beforeAll(() => {
    if (!globalThis.crypto) globalThis.crypto = webcrypto;
  });

  it('independently verifies the seed, beacon, manifest, and winner ranking', async () => {
    const publicId = '11111111-1111-4111-8111-111111111111';
    const seed = 'local-public-seed';
    const result = await verifyPublicDraw({
      campaign: {
        seedReveal: seed,
        seedCommitment: sha256Text(seed),
        publicRandomnessChain: QUICKNET_CHAIN,
        publicRandomnessRound: QUICKNET_ROUND,
        publicRandomness: QUICKNET_RANDOMNESS,
        publicRandomnessSignature: QUICKNET_SIGNATURE,
        candidateManifestHash: sha256Text(publicId),
        prizePlan: { first: 2, second: 2 },
      },
      publicCandidateIds: [publicId],
      publicWinners: [{ publicId, prizeTier: 'first', winnerOrder: 1 }],
    });

    expect(result.valid).toBe(true);
    expect(result.checks).toEqual({
      seedCommitment: true,
      beaconSignature: true,
      candidateManifest: true,
      winnerRanking: true,
    });
  });

  it('fails when a published winner was changed', async () => {
    const publicId = '11111111-1111-4111-8111-111111111111';
    const seed = 'local-public-seed';
    const result = await verifyPublicDraw({
      campaign: {
        seedReveal: seed,
        seedCommitment: sha256Text(seed),
        publicRandomnessChain: QUICKNET_CHAIN,
        publicRandomnessRound: QUICKNET_ROUND,
        publicRandomness: QUICKNET_RANDOMNESS,
        publicRandomnessSignature: QUICKNET_SIGNATURE,
        candidateManifestHash: sha256Text(publicId),
        prizePlan: { first: 1, second: 0 },
      },
      publicCandidateIds: [publicId],
      publicWinners: [{
        publicId: '22222222-2222-4222-8222-222222222222',
        prizeTier: 'first',
        winnerOrder: 1,
      }],
    });

    expect(result.valid).toBe(false);
    expect(result.checks.winnerRanking).toBe(false);
  });
});
