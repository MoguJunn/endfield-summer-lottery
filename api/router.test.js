// @vitest-environment node

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  callLotteryProvider: vi.fn(),
  createProviderPowChallenge: vi.fn(),
}));
vi.mock('./_lib/provider.js', () => ({
  callLotteryProvider: mocks.callLotteryProvider,
  createProviderPowChallenge: mocks.createProviderPowChallenge,
}));

import handler from './router.js';

function responseRecorder() {
  return {
    statusCode: 200,
    headers: {},
    body: null,
    ended: false,
    getHeader(name) { return this.headers[name]; },
    setHeader(name, value) { this.headers[name] = value; },
    status(code) { this.statusCode = code; return this; },
    json(payload) { this.body = payload; return this; },
    end() { this.ended = true; return this; },
  };
}

function request(path, { method = 'POST', body = {}, headers = {} } = {}) {
  return {
    method,
    url: path,
    body,
    headers: {
      origin: 'https://lottery.example.com',
      'x-forwarded-proto': 'https',
      ...headers,
    },
  };
}

describe('lottery same-origin API router', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    Object.assign(process.env, {
      LOTTERY_SITE_URL: 'https://lottery.example.com',
      MAIN_SITE_URL: 'https://main.example.com',
      LOTTERY_BACKEND_SECRET: 'backend-secret-which-is-at-least-forty-three-characters-long',
      LOTTERY_SESSION_SECRET: 'session-secret-which-is-at-least-forty-three-characters-long',
      LOTTERY_DRAW_SECRET: 'draw-secret-which-is-at-least-forty-three-characters-long',
      LOTTERY_DRAW_SEED: 'draw-seed-which-is-at-least-forty-three-characters-long',
      LOTTERY_CONTACT_FORMAT: 'qq',
      LOTTERY_NOTIFICATION_REQUIRED: 'true',
    });
  });

  afterEach(() => {
    delete process.env.LOTTERY_SITE_URL;
    delete process.env.MAIN_SITE_URL;
    delete process.env.LOTTERY_BACKEND_SECRET;
    delete process.env.LOTTERY_SESSION_SECRET;
    delete process.env.LOTTERY_DRAW_SECRET;
    delete process.env.LOTTERY_DRAW_SEED;
    delete process.env.LOTTERY_CONTACT_FORMAT;
    delete process.env.LOTTERY_NOTIFICATION_REQUIRED;
  });

  it('rejects entry from a different or missing browser Origin before calling the gateway', async () => {
    for (const origin of [undefined, 'https://evil.example.com']) {
      const response = responseRecorder();
      const headers = { cookie: 'summer_lottery_session=opaque; summer_lottery_csrf=csrf' };
      if (origin) headers.origin = origin;
      else headers.origin = '';
      await handler(request('/api/lottery/enter', { headers }), response);
      expect(response.statusCode).toBe(403);
      expect(response.body.error.code).toBe('origin_not_allowed');
    }
    expect(mocks.callLotteryProvider).not.toHaveBeenCalled();
  });

  it('requires a matching CSRF header for entry', async () => {
    const response = responseRecorder();
    await handler(request('/api/lottery/enter', {
      headers: {
        cookie: 'summer_lottery_session=opaque; summer_lottery_csrf=csrf',
        'x-csrf-token': 'different',
      },
    }), response);
    expect(response.statusCode).toBe(403);
    expect(response.body.error.code).toBe('csrf_invalid');
    expect(mocks.callLotteryProvider).not.toHaveBeenCalled();
  });

  it('rejects invalid contact details before calling the provider', async () => {
    const response = responseRecorder();
    await handler(request('/api/lottery/enter', {
      body: { contactValue: 'not-a-qq', notificationConfirmed: true },
      headers: {
        cookie: 'summer_lottery_session=opaque; summer_lottery_csrf=csrf',
        'x-csrf-token': 'csrf',
      },
    }), response);
    expect(response.statusCode).toBe(400);
    expect(response.body.error.code).toBe('invalid_contact_value');
    expect(mocks.callLotteryProvider).not.toHaveBeenCalled();
  });

  it('forwards private contact details and the robot proof only to the provider', async () => {
    mocks.callLotteryProvider.mockImplementation(async (action) => action === 'enter'
      ? { id: 'entry-1', alreadyEntered: false }
      : { entry: { id: 'entry-1' }, entryCount: 1 });
    const response = responseRecorder();
    await handler(request('/api/lottery/enter', {
      body: {
        contactValue: '123456789',
        notificationConfirmed: true,
        captchaProvider: 'pow',
        powPayload: { action: 'lottery_enter', challengeId: 'challenge-1' },
      },
      headers: {
        cookie: 'summer_lottery_session=opaque; summer_lottery_csrf=csrf',
        'x-csrf-token': 'csrf',
      },
    }), response);
    expect(response.statusCode).toBe(201);
    expect(mocks.callLotteryProvider).toHaveBeenCalledWith('enter', expect.objectContaining({
      contactType: 'qq',
      contactValue: '123456789',
      notificationConfirmed: true,
      captchaProvider: 'pow',
      powPayload: expect.objectContaining({ action: 'lottery_enter', challengeId: 'challenge-1' }),
    }));
  });

  it('proxies a signed PoW challenge from the main site', async () => {
    mocks.createProviderPowChallenge.mockResolvedValue({ action: 'lottery_enter', signature: 'signed' });
    const response = responseRecorder();
    await handler(request('/api/auth-pow-challenge'), response);
    expect(response.statusCode).toBe(200);
    expect(response.body.data.challenge).toEqual({ action: 'lottery_enter', signature: 'signed' });
  });

  it('rejects a callback whose state does not match this browser cookie', async () => {
    const response = responseRecorder();
    await handler(request('/api/auth/sso/callback', {
      body: { ticket: 'ticket', state: 'other-state' },
      headers: { cookie: 'summer_lottery_sso_state=browser-state' },
    }), response);
    expect(response.statusCode).toBe(403);
    expect(response.body.error.code).toBe('sso_state_invalid');
    expect(mocks.callLotteryProvider).not.toHaveBeenCalled();
  });

  it('only sends hashes to the SSO exchange and sets host-only session cookies', async () => {
    mocks.callLotteryProvider.mockResolvedValue({ userId: 'user-1' });
    const response = responseRecorder();
    await handler(request('/api/auth/sso/callback', {
      body: { ticket: 'one-time-ticket', state: 'browser-state' },
      headers: { cookie: 'summer_lottery_sso_state=browser-state' },
    }), response);
    expect(response.statusCode).toBe(200);
    expect(mocks.callLotteryProvider).toHaveBeenCalledWith('exchange', expect.objectContaining({
      ticketHash: expect.stringMatching(/^[0-9a-f]{64}$/u),
      stateHash: expect.stringMatching(/^[0-9a-f]{64}$/u),
      sessionTokenHash: expect.stringMatching(/^[0-9a-f]{64}$/u),
      csrfTokenHash: expect.stringMatching(/^[0-9a-f]{64}$/u),
    }));
    const exchangePayload = mocks.callLotteryProvider.mock.calls[0][1];
    expect(exchangePayload).not.toHaveProperty('ticket');
    expect(exchangePayload).not.toHaveProperty('state');
    expect(response.headers['Set-Cookie'].join('; ')).not.toContain('Domain=');
  });

  it('does not clear browser cookies when database logout revocation fails', async () => {
    mocks.callLotteryProvider.mockRejectedValue(Object.assign(new Error('failed'), {
      code: 'lottery_backend_unavailable', status: 503,
    }));
    const response = responseRecorder();
    await handler(request('/api/auth/logout', {
      headers: {
        cookie: 'summer_lottery_session=opaque; summer_lottery_csrf=csrf',
        'x-csrf-token': 'csrf',
      },
    }), response);
    expect(response.statusCode).toBe(503);
    expect(response.headers['Set-Cookie']).toBeUndefined();
  });
});
