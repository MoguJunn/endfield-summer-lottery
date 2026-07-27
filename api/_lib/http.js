import { timingSafeEqual } from 'node:crypto';
import { getRuntimeConfig } from './env.js';

export function setNoStore(res) {
  res.setHeader('Cache-Control', 'no-store, max-age=0');
  res.setHeader('Pragma', 'no-cache');
  res.setHeader('X-Content-Type-Options', 'nosniff');
}

export function sendJson(res, status, payload) {
  setNoStore(res);
  return res.status(status).json(payload);
}

export function sendError(res, status, code, message) {
  return sendJson(res, status, {
    success: false,
    error: { code, message },
  });
}

export function redirect(res, location, status = 303) {
  setNoStore(res);
  res.setHeader('Referrer-Policy', 'no-referrer');
  res.statusCode = status;
  res.setHeader('Location', location);
  res.end();
}

export function isAllowedBrowserOrigin(req, env = process.env) {
  const origin = String(req.headers?.origin || '').replace(/\/$/u, '');
  return Boolean(origin) && origin === getRuntimeConfig(env).lotteryOrigin;
}

export function rejectDisallowedOrigin(req, res, env = process.env) {
  if (isAllowedBrowserOrigin(req, env)) {
    return false;
  }
  sendError(res, 403, 'origin_not_allowed', '请求来源不在允许范围内。');
  return true;
}

export function readBearerToken(req) {
  const authorization = String(req.headers?.authorization || '');
  return authorization.toLowerCase().startsWith('bearer ')
    ? authorization.slice(7).trim()
    : '';
}

export function getRequesterIp(req) {
  const forwardedFor = req?.headers?.['x-forwarded-for'];
  const realIp = req?.headers?.['x-real-ip'];
  return typeof forwardedFor === 'string'
    ? forwardedFor.split(',')[0].trim()
    : String(realIp || req?.socket?.remoteAddress || 'unknown');
}

export function safeEqual(left, right) {
  const leftBuffer = Buffer.from(String(left || ''), 'utf8');
  const rightBuffer = Buffer.from(String(right || ''), 'utf8');
  return leftBuffer.length === rightBuffer.length && timingSafeEqual(leftBuffer, rightBuffer);
}
