import { createHmac, randomBytes } from 'node:crypto';
import { getRuntimeConfig } from './env.js';
import { safeEqual } from './http.js';

const SESSION_COOKIE = 'summer_lottery_session';
const CSRF_COOKIE = 'summer_lottery_csrf';
const SSO_STATE_COOKIE = 'summer_lottery_sso_state';

export function parseCookies(headerValue) {
  const cookies = {};
  String(headerValue || '')
    .split(';')
    .map((item) => item.trim())
    .filter(Boolean)
    .forEach((item) => {
      const separator = item.indexOf('=');
      if (separator <= 0) return;
      const name = item.slice(0, separator).trim();
      const rawValue = item.slice(separator + 1).trim();
      try {
        cookies[name] = decodeURIComponent(rawValue);
      } catch {
        cookies[name] = rawValue;
      }
    });
  return cookies;
}

export function isSecureRequest(req, env = process.env) {
  if (getRuntimeConfig(env).lotteryOrigin.startsWith('https://')) return true;
  return String(req.headers?.['x-forwarded-proto'] || '').split(',')[0].trim() === 'https';
}

export function serializeCookie(name, value, {
  maxAgeSeconds,
  httpOnly = true,
  secure = true,
  sameSite = 'Lax',
} = {}) {
  const parts = [`${name}=${encodeURIComponent(value || '')}`, 'Path=/', `SameSite=${sameSite}`];
  if (Number.isFinite(Number(maxAgeSeconds))) parts.push(`Max-Age=${Math.max(0, Number(maxAgeSeconds))}`);
  if (httpOnly) parts.push('HttpOnly');
  if (secure) parts.push('Secure');
  return parts.join('; ');
}

export function appendCookie(res, value) {
  const current = res.getHeader?.('Set-Cookie');
  if (!current) res.setHeader('Set-Cookie', value);
  else res.setHeader('Set-Cookie', Array.isArray(current) ? [...current, value] : [current, value]);
}

export function createOpaqueToken() {
  return randomBytes(32).toString('base64url');
}

export function hashOpaqueToken(token, secret, purpose) {
  return createHmac('sha256', secret)
    .update(`${purpose}:${String(token || '')}`, 'utf8')
    .digest('hex');
}

export function setSsoStateCookie(req, res, state, env = process.env) {
  appendCookie(res, serializeCookie(SSO_STATE_COOKIE, state, {
    maxAgeSeconds: 10 * 60,
    secure: isSecureRequest(req, env),
  }));
}

export function readSsoState(req) {
  return parseCookies(req.headers?.cookie)[SSO_STATE_COOKIE] || '';
}

export function clearSsoStateCookie(req, res, env = process.env) {
  appendCookie(res, serializeCookie(SSO_STATE_COOKIE, '', {
    maxAgeSeconds: 0,
    secure: isSecureRequest(req, env),
  }));
}

export function createLotterySessionMaterial(env = process.env) {
  const config = getRuntimeConfig(env);
  const sessionToken = createOpaqueToken();
  const csrfToken = createOpaqueToken();
  return {
    sessionToken,
    csrfToken,
    sessionTokenHash: hashOpaqueToken(sessionToken, config.sessionSecret, 'session'),
    csrfTokenHash: hashOpaqueToken(csrfToken, config.sessionSecret, 'csrf'),
    expiresAt: new Date(Date.now() + config.sessionTtlSeconds * 1000).toISOString(),
  };
}

export function setLotterySessionCookies(req, res, material, env = process.env) {
  const config = getRuntimeConfig(env);
  const secure = isSecureRequest(req, env);
  appendCookie(res, serializeCookie(SESSION_COOKIE, material.sessionToken, {
    maxAgeSeconds: config.sessionTtlSeconds,
    secure,
  }));
  appendCookie(res, serializeCookie(CSRF_COOKIE, material.csrfToken, {
    maxAgeSeconds: config.sessionTtlSeconds,
    httpOnly: false,
    secure,
    sameSite: 'Strict',
  }));
}

export function readLotteryCredentials(req, env = process.env) {
  const config = getRuntimeConfig(env);
  const cookies = parseCookies(req.headers?.cookie);
  const sessionToken = cookies[SESSION_COOKIE] || '';
  const csrfToken = cookies[CSRF_COOKIE] || '';
  return {
    hasSession: Boolean(sessionToken),
    sessionTokenHash: sessionToken ? hashOpaqueToken(sessionToken, config.sessionSecret, 'session') : '',
    csrfToken,
    csrfTokenHash: csrfToken ? hashOpaqueToken(csrfToken, config.sessionSecret, 'csrf') : '',
  };
}

export function validateCsrfRequest(req, credentials) {
  const headerToken = String(req.headers?.['x-csrf-token'] || '');
  return Boolean(headerToken && credentials?.csrfToken && safeEqual(headerToken, credentials.csrfToken));
}

export function clearLotterySessionCookies(req, res, env = process.env) {
  const secure = isSecureRequest(req, env);
  appendCookie(res, serializeCookie(SESSION_COOKIE, '', { maxAgeSeconds: 0, secure }));
  appendCookie(res, serializeCookie(CSRF_COOKIE, '', {
    maxAgeSeconds: 0,
    httpOnly: false,
    secure,
    sameSite: 'Strict',
  }));
}
