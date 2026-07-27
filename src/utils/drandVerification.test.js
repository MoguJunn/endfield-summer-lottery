// @vitest-environment node

import { describe, expect, it } from 'vitest';
import { QUICKNET_CHAIN_INFO, verifyQuicknetBeacon } from './drandVerification.js';

const BEACON = {
  chainHash: QUICKNET_CHAIN_INFO.hash,
  round: 1000,
  randomness: 'fe290beca10872ef2fb164d2aa4442de4566183ec51c56ff3cd603d930e54fdd',
  signature: 'b44679b9a59af2ec876b1a6b1ad52ea9b1615fc3982b19576350f93447cb1125e342b73a8dd2bacbe47e4b6b63ed5e39',
};

describe('drand Quicknet verification', () => {
  it('verifies an official Quicknet RFC9380 BLS beacon offline', async () => {
    await expect(verifyQuicknetBeacon(BEACON)).resolves.toBe(true);
  });

  it('rejects a changed signature, randomness, round, or chain', async () => {
    const variants = [
      { ...BEACON, signature: `a${BEACON.signature.slice(1)}` },
      { ...BEACON, randomness: `a${BEACON.randomness.slice(1)}` },
      { ...BEACON, round: BEACON.round + 1 },
      { ...BEACON, chainHash: 'a'.repeat(64) },
    ];
    const results = await Promise.all(variants.map(verifyQuicknetBeacon));
    expect(results).toEqual([false, false, false, false]);
  });
});
