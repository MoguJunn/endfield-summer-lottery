// @vitest-environment node

import { afterEach, describe, expect, it, vi } from 'vitest';
import { callLotteryBackend } from './backend.js';

const ENV = {
  LOTTERY_PROVIDER: 'main-site',
  LOTTERY_SITE_URL: 'https://lottery.example.test',
  MAIN_SITE_URL: 'https://main.example.test',
  LOTTERY_SESSION_SECRET: 's'.repeat(43),
  LOTTERY_BACKEND_SECRET: 'user-data-secret'.padEnd(43, 'u'),
};

describe('main-site backend client', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('uses the user data secret and sends contract version 1', async () => {
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: vi.fn().mockResolvedValue({ success: true, data: { ok: true } }),
    });
    vi.stubGlobal('fetch', fetchMock);

    await callLotteryBackend('snapshot', {}, ENV);

    const userRequest = fetchMock.mock.calls[0][1];
    expect(userRequest.headers.Authorization).toBe(`Bearer ${ENV.LOTTERY_BACKEND_SECRET}`);
    expect(JSON.parse(userRequest.body)).toEqual(expect.objectContaining({
      version: 1,
      action: 'snapshot',
    }));
  });

  it('sends only the generic contact contract without legacy QQ aliases', async () => {
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: vi.fn().mockResolvedValue({ success: true, data: { id: 'entry-1' } }),
    });
    vi.stubGlobal('fetch', fetchMock);

    await callLotteryBackend('enter', {
      contactType: 'email',
      contactValue: 'winner@example.test',
      notificationConfirmed: true,
    }, ENV);

    const requestBody = JSON.parse(fetchMock.mock.calls[0][1].body);
    expect(requestBody.payload).toEqual({
      contactType: 'email',
      contactValue: 'winner@example.test',
      notificationConfirmed: true,
    });
    expect(requestBody.payload).not.toHaveProperty('contactQq');
    expect(requestBody.payload).not.toHaveProperty('groupJoined');
  });
});
