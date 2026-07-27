// @vitest-environment node

import { describe, expect, it } from 'vitest';
import { sanitizeSnapshot } from './contracts.js';

describe('public gateway contract', () => {
  it('keeps only explicitly public fields', () => {
    const result = sanitizeSnapshot({
      campaign: {
        id: 'campaign',
        title: 'Campaign',
        phase: 'open',
        prizePlan: { first: 1, second: 2 },
        privateSeed: 'must-not-leak',
      },
      user: { id: 'user', username: 'Participant', role: 'user', email: 'private@example.test' },
      entry: {
        id: 'entry',
        publicId: 'public-entry',
        entryNumber: 1,
        eligible: true,
        contactValue: 'private-contact',
      },
      entryCount: 1,
      internalNotes: 'must-not-leak',
    }, {
      site: { brand: { name: 'Open Lottery' } },
      mainSiteUrl: 'https://main.example.test',
    });

    const serialized = JSON.stringify(result);
    expect(result.contractVersion).toBe(1);
    expect(result.entry).toEqual(expect.objectContaining({ publicId: 'public-entry' }));
    expect(result.entry).not.toHaveProperty('id');
    expect(result.user).not.toHaveProperty('id');
    expect(result.user).not.toHaveProperty('role');
    expect(serialized).not.toContain('private-contact');
    expect(serialized).not.toContain('private@example.test');
    expect(serialized).not.toContain('must-not-leak');
  });
});
