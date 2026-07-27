// @vitest-environment node

import { afterEach, describe, expect, it } from 'vitest';
import { callDemoProvider, createDemoPowChallenge, resetDemoProvider } from './demoProvider.js';

const ENV = {
  LOTTERY_PROVIDER: 'demo',
  LOTTERY_CAMPAIGN_ID: 'demo-campaign',
  LOTTERY_CONTACT_FORMAT: 'text',
  LOTTERY_NOTIFICATION_REQUIRED: 'true',
};

describe('demo provider', () => {
  afterEach(() => resetDemoProvider());

  it('runs login and idempotent entry without a main site', async () => {
    await callDemoProvider('demo-login', { sessionTokenHash: 'session' }, ENV);
    const first = await callDemoProvider('enter', {
      sessionTokenHash: 'session',
      contactValue: 'private-contact',
      notificationConfirmed: true,
    }, ENV);
    const second = await callDemoProvider('enter', {
      sessionTokenHash: 'session',
      contactValue: 'changed-contact',
      notificationConfirmed: true,
    }, ENV);
    const snapshot = await callDemoProvider('snapshot', { sessionTokenHash: 'session' }, ENV);

    expect(first.alreadyEntered).toBe(false);
    expect(second).toEqual(expect.objectContaining({ id: first.id, alreadyEntered: true }));
    expect(snapshot).toEqual(expect.objectContaining({ entryCount: 1 }));
    expect(snapshot.entry.id).toBe(first.id);
  });

  it('issues a lightweight challenge clearly marked as demo-only', () => {
    expect(createDemoPowChallenge()).toEqual(expect.objectContaining({
      action: 'lottery_enter',
      algorithm: 'sha256-chain-v1',
      signature: 'demo-only-not-verified',
    }));
  });
});
