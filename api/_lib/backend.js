import { getRuntimeConfig } from './env.js';
import { GATEWAY_CONTRACT_VERSION } from './contracts.js';

export class LotteryBackendError extends Error {
  constructor(code, message, status = 502) {
    super(message || code || 'lottery_backend_failed');
    this.name = 'LotteryBackendError';
    this.code = code || 'lottery_backend_failed';
    this.status = status;
  }
}

export async function callLotteryBackend(action, payload = {}, env = process.env) {
  const config = getRuntimeConfig(env);
  const secret = ['prepare', 'draw'].includes(action) ? config.adminBackendSecret : config.backendSecret;
  if (!config.mainSiteOrigin || !secret) {
    throw new LotteryBackendError('lottery_backend_not_configured', '抽奖数据网关尚未配置。', 503);
  }
  const url = new URL('/api/summer-lottery-backend', config.mainSiteOrigin);
  let response;
  try {
    response = await fetch(url, {
      method: 'POST',
      headers: {
        Accept: 'application/json',
        Authorization: `Bearer ${secret}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ version: GATEWAY_CONTRACT_VERSION, action, payload }),
      signal: AbortSignal.timeout(15_000),
    });
  } catch {
    throw new LotteryBackendError('lottery_backend_unavailable', '抽奖数据服务暂时不可用。', 503);
  }
  const body = await response.json().catch(() => null);
  if (!response.ok || body?.success !== true) {
    throw new LotteryBackendError(
      body?.error?.code || `lottery_backend_http_${response.status}`,
      body?.error?.message || '抽奖数据服务暂时不可用。',
      response.status,
    );
  }
  return body.data;
}

export async function createLotteryPowChallenge(env = process.env) {
  const config = getRuntimeConfig(env);
  if (!config.mainSiteOrigin) {
    throw new LotteryBackendError('lottery_backend_not_configured', '主站验证服务尚未配置。', 503);
  }
  const url = new URL('/api/auth-pow-challenge', config.mainSiteOrigin);
  let response;
  try {
    response = await fetch(url, {
      method: 'POST',
      headers: {
        Accept: 'application/json',
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ action: 'lottery_enter' }),
      signal: AbortSignal.timeout(15_000),
    });
  } catch {
    throw new LotteryBackendError('captcha_challenge_unavailable', '机器人验证暂时不可用，请稍后重试。', 503);
  }
  const body = await response.json().catch(() => null);
  if (!response.ok || body?.success !== true || !body?.challenge) {
    throw new LotteryBackendError('captcha_challenge_unavailable', '机器人验证暂时不可用，请稍后重试。', 503);
  }
  return body.challenge;
}
