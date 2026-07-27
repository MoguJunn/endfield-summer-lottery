// @vitest-environment node

import { createHash, webcrypto } from 'node:crypto';
import { beforeAll, describe, expect, it } from 'vitest';
import { verifyPublicDraw } from './drawVerification.js';

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
    const randomness = createHash('sha256').update(Buffer.from('00', 'hex')).digest('hex');
    const result = await verifyPublicDraw({
      campaign: {
        seedReveal: seed,
        seedCommitment: sha256Text(seed),
        publicRandomness: randomness,
        publicRandomnessSignature: '00',
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
    const randomness = createHash('sha256').update(Buffer.from('00', 'hex')).digest('hex');
    const result = await verifyPublicDraw({
      campaign: {
        seedReveal: seed,
        seedCommitment: sha256Text(seed),
        publicRandomness: randomness,
        publicRandomnessSignature: '00',
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
