// @vitest-environment node

import { describe, expect, it } from 'vitest';
import {
  createLotterySessionMaterial,
  parseCookies,
  readLotteryCredentials,
  serializeCookie,
  setLotterySessionCookies,
  validateCsrfRequest,
} from './session.js';

const ENV = {
  LOTTERY_SITE_URL: 'https://lottery.example.com',
  MAIN_SITE_URL: 'https://main.example.com',
  LOTTERY_BACKEND_SECRET: 'backend-secret-which-is-at-least-forty-three-chars-long',
  LOTTERY_SESSION_SECRET: 'session-secret-which-is-at-least-forty-three-chars-long',
  LOTTERY_SESSION_TTL_SECONDS: '3600',
};

function createResponse() {
  return {
    headers: {},
    getHeader(name) { return this.headers[name]; },
    setHeader(name, value) { this.headers[name] = value; },
  };
}

describe('lottery session security helpers', () => {
  it('serializes host-only security cookies without a Domain attribute', () => {
    const cookie = serializeCookie('session', 'opaque', { maxAgeSeconds: 60, secure: true });
    expect(cookie).toContain('HttpOnly');
    expect(cookie).toContain('Secure');
    expect(cookie).toContain('SameSite=Lax');
    expect(cookie).not.toContain('Domain=');
  });

  it('creates opaque session material and requires matching CSRF cookie and header', () => {
    const req = { headers: { 'x-forwarded-proto': 'https' } };
    const res = createResponse();
    const material = createLotterySessionMaterial(ENV);
    expect(material.sessionTokenHash).toMatch(/^[0-9a-f]{64}$/u);
    expect(material.csrfTokenHash).toMatch(/^[0-9a-f]{64}$/u);
    setLotterySessionCookies(req, res, material, ENV);
    const cookies = parseCookies(res.headers['Set-Cookie'].join('; '));
    const request = {
      headers: {
        cookie: `summer_lottery_session=${cookies.summer_lottery_session}; summer_lottery_csrf=${cookies.summer_lottery_csrf}`,
        'x-csrf-token': cookies.summer_lottery_csrf,
      },
    };
    const credentials = readLotteryCredentials(request, ENV);
    expect(credentials.sessionTokenHash).toBe(material.sessionTokenHash);
    expect(credentials.csrfTokenHash).toBe(material.csrfTokenHash);
    expect(validateCsrfRequest(request, credentials)).toBe(true);
    request.headers['x-csrf-token'] = 'wrong-token';
    expect(validateCsrfRequest(request, credentials)).toBe(false);
  });
});
