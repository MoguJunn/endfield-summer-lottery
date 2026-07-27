import { createHash } from 'node:crypto';
import { sanitizeEntryResult, sanitizeSnapshot } from './_lib/contracts.js';
import { getRuntimeConfig, getMissingRuntimeKeys } from './_lib/env.js';
import { getRequesterIp, sendError, sendJson, redirect, readBearerToken, rejectDisallowedOrigin, safeEqual } from './_lib/http.js';
import { callLotteryProvider, createProviderPowChallenge } from './_lib/provider.js';
import { getPublicSiteConfig, validateContactValue } from './_lib/publicConfig.js';
import {
  clearLotterySessionCookies,
  clearSsoStateCookie,
  createLotterySessionMaterial,
  createOpaqueToken,
  readLotteryCredentials,
  readSsoState,
  setLotterySessionCookies,
  setSsoStateCookie,
  validateCsrfRequest,
} from './_lib/session.js';

function parseRequest(req) {
  const url = new URL(req.url || '/', 'https://lottery.local');
  const rewrittenPath = url.searchParams.get('__path');
  return rewrittenPath
    ? `/api/${rewrittenPath.replace(/^\/+|\/+$/gu, '')}`
    : url.pathname.replace(/\/+$/u, '') || '/';
}

function methodNotAllowed(req, res, allowed) {
  res.setHeader('Allow', allowed.join(', '));
  return sendError(res, 405, 'method_not_allowed', `不支持 ${req.method || 'UNKNOWN'} 请求。`);
}

function normalizePowPayload(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  return {
    action: String(value.action || '').slice(0, 40),
    algorithm: String(value.algorithm || '').slice(0, 40),
    challengeId: String(value.challengeId || '').slice(0, 128),
    difficulty: Number(value.difficulty),
    expiresAt: Number(value.expiresAt),
    hash: String(value.hash || '').slice(0, 128),
    issuedAt: Number(value.issuedAt),
    seed: String(value.seed || '').slice(0, 128),
    signature: String(value.signature || '').slice(0, 256),
    step: Number(value.step),
    totalSteps: Number(value.totalSteps),
  };
}

function requireRuntime(res, { includeDraw = false } = {}) {
  const config = getRuntimeConfig();
  if (getMissingRuntimeKeys(config, { includeDraw }).length) {
    sendError(res, 503, 'service_not_configured', '抽奖服务尚未完成部署配置。');
    return null;
  }
  return config;
}

function businessError(error) {
  const code = String(error?.code || 'lottery_backend_failed');
  const messages = {
    campaign_not_found: '活动配置尚未就绪。',
    campaign_not_open: '当前不在可参与时间内。',
    campaign_already_has_entries: '已有用户参与，不能再修改开奖承诺。',
    seed_commitment_already_fixed: '开奖承诺已经固定，不能修改。',
    campaign_already_drawn: '本期活动已经完成开奖。',
    draw_not_open: '尚未到开奖时间。',
    campaign_has_no_entries: '当前没有可用于开奖的有效参与记录。',
    seed_commitment_mismatch: '开奖种子与活动开放前公示的承诺不一致。',
    lottery_session_invalid: '登录状态已失效，请重新使用主站账号登录。',
    source_main_session_invalid: '主站登录状态已失效，请重新登录。',
    sso_ticket_invalid: '一次性登录票据无效或已使用。',
    public_randomness_unavailable: '固定轮次的公开随机信标尚未生成，请稍后重试开奖。',
    public_randomness_invalid: '公开随机信标校验失败，已停止开奖。',
    public_randomness_config_invalid: '公开随机信标配置无效，已停止开奖。',
    invalid_contact_value: '请输入正确的领奖联系方式。',
    notification_confirmation_required: '请先确认已加入活动通知渠道。',
    captcha_required: '请先完成人机验证。',
    captcha_failed: '人机验证未通过，请重新验证。',
    captcha_not_configured: '人机验证暂时不可用，请稍后重试。',
    captcha_verify_error: '人机验证服务暂时不可用，请稍后重试。',
    pow_missing: '请先完成工作量证明验证。',
    pow_invalid_payload: '工作量证明无效，请重新验证。',
    pow_action_mismatch: '工作量证明用途不匹配，请重新验证。',
    pow_expired: '工作量证明已过期，请重新验证。',
    pow_bad_signature: '工作量证明签名无效，请重新验证。',
    pow_invalid_steps: '工作量证明参数无效，请重新验证。',
    pow_failed: '工作量证明未通过，请重新验证。',
    captcha_challenge_unavailable: '机器人验证暂时不可用，请稍后重试。',
    lottery_backend_unavailable: '抽奖数据服务暂时不可用，请稍后再试。',
  };
  return { code, message: messages[code] || '服务暂时不可用，请稍后再试。' };
}

async function handleSnapshot(req, res) {
  if (req.method !== 'GET') return methodNotAllowed(req, res, ['GET']);
  const config = requireRuntime(res);
  if (!config) return;
  try {
    const credentials = readLotteryCredentials(req);
    const snapshot = await callLotteryProvider('snapshot', {
      sessionTokenHash: credentials.sessionTokenHash,
    });
    return sendJson(res, 200, {
      success: true,
      data: sanitizeSnapshot(snapshot, {
        site: getPublicSiteConfig(),
        mainSiteUrl: config.isDemo ? '' : config.mainSiteOrigin,
      }),
    });
  } catch (error) {
    const normalized = businessError(error);
    return sendError(res, error?.status || 503, normalized.code, normalized.message);
  }
}

async function handleEnter(req, res) {
  if (req.method !== 'POST') return methodNotAllowed(req, res, ['POST']);
  if (rejectDisallowedOrigin(req, res)) return;
  if (!requireRuntime(res)) return;
  const credentials = readLotteryCredentials(req);
  if (!credentials.hasSession) return sendError(res, 401, 'login_required', '请先使用主站账号登录。');
  if (!validateCsrfRequest(req, credentials)) {
    return sendError(res, 403, 'csrf_invalid', '页面校验已过期，请刷新后重试。');
  }
  const site = getPublicSiteConfig();
  const contactValue = String(req.body?.contactValue || '').trim();
  if (!validateContactValue(contactValue, site.contact.format)) {
    return sendError(res, 400, 'invalid_contact_value', `请输入正确的${site.contact.label}。`);
  }
  if (site.contact.notificationRequired && req.body?.notificationConfirmed !== true) {
    return sendError(res, 400, 'notification_confirmation_required', '请先加入活动通知渠道，并勾选确认。');
  }
  const requestedProvider = String(req.body?.captchaProvider || '').trim().toLowerCase();
  const captchaProvider = ['pow', 'turnstile'].includes(requestedProvider) ? requestedProvider : '';
  try {
    const entry = await callLotteryProvider('enter', {
      sessionTokenHash: credentials.sessionTokenHash,
      csrfTokenHash: credentials.csrfTokenHash,
      contactType: site.contact.format,
      contactValue,
      notificationConfirmed: req.body?.notificationConfirmed === true,
      captchaToken: String(req.body?.captchaToken || '').trim().slice(0, 4096),
      captchaProvider,
      powPayload: captchaProvider === 'pow' ? normalizePowPayload(req.body?.powPayload) : null,
      requesterIp: getRequesterIp(req),
    });
    const snapshot = await callLotteryProvider('snapshot', {
      sessionTokenHash: credentials.sessionTokenHash,
    });
    return sendJson(res, entry.alreadyEntered ? 200 : 201, {
      success: true,
      data: sanitizeEntryResult({ entry: snapshot.entry, entryCount: snapshot.entryCount }),
    });
  } catch (error) {
    const normalized = businessError(error);
    return sendError(res, error?.status || 409, normalized.code, normalized.message);
  }
}

async function handlePowChallenge(req, res) {
  if (req.method !== 'POST') return methodNotAllowed(req, res, ['POST']);
  if (rejectDisallowedOrigin(req, res)) return;
  if (!requireRuntime(res)) return;
  try {
    const challenge = await createProviderPowChallenge();
    return sendJson(res, 200, { success: true, data: { challenge } });
  } catch (error) {
    const normalized = businessError(error);
    return sendError(res, error?.status || 503, normalized.code, normalized.message);
  }
}

function handleSsoStart(req, res) {
  if (req.method !== 'GET') return methodNotAllowed(req, res, ['GET']);
  const config = requireRuntime(res);
  if (!config) return;
  if (config.isDemo) {
    const material = createLotterySessionMaterial();
    return callLotteryProvider('demo-login', {
      sessionTokenHash: material.sessionTokenHash,
    }).then(() => {
      setLotterySessionCookies(req, res, material);
      return redirect(res, `${config.lotteryOrigin}/?auth=signed_in`);
    }).catch((error) => {
      const normalized = businessError(error);
      return redirect(res, `${config.lotteryOrigin}/?auth=${normalized.code === 'rate_limited' ? 'rate_error' : 'service_error'}`);
    });
  }
  const state = createOpaqueToken();
  setSsoStateCookie(req, res, state);
  const target = new URL('/api/summer-lottery-sso/start', config.mainSiteOrigin);
  target.searchParams.set('state', state);
  return redirect(res, target.toString());
}

async function handleSsoCallback(req, res) {
  if (req.method !== 'POST') return methodNotAllowed(req, res, ['POST']);
  if (rejectDisallowedOrigin(req, res)) return;
  const config = requireRuntime(res);
  if (!config) return;
  const ticket = String(req.body?.ticket || '');
  const state = String(req.body?.state || '');
  const cookieState = readSsoState(req);
  if (!ticket || !state || !cookieState || !safeEqual(state, cookieState)) {
    clearSsoStateCookie(req, res);
    return sendError(res, 403, 'sso_state_invalid', '登录校验已过期，请重新发起登录。');
  }
  const material = createLotterySessionMaterial();
  try {
    await callLotteryProvider('exchange', {
      ticketHash: createHash('sha256').update(ticket, 'utf8').digest('hex'),
      stateHash: createHash('sha256').update(state, 'utf8').digest('hex'),
      audience: config.audience,
      sessionTokenHash: material.sessionTokenHash,
      csrfTokenHash: material.csrfTokenHash,
      expiresAt: material.expiresAt,
    });
    clearSsoStateCookie(req, res);
    setLotterySessionCookies(req, res, material);
    return sendJson(res, 200, { success: true, data: { authenticated: true } });
  } catch (error) {
    clearSsoStateCookie(req, res);
    const normalized = businessError(error);
    return sendError(res, error?.status || 401, normalized.code, normalized.message);
  }
}

async function handleLogout(req, res) {
  if (req.method !== 'POST') return methodNotAllowed(req, res, ['POST']);
  if (rejectDisallowedOrigin(req, res)) return;
  if (!requireRuntime(res)) return;
  const credentials = readLotteryCredentials(req);
  if (!credentials.hasSession) {
    clearLotterySessionCookies(req, res);
    return sendJson(res, 200, { success: true });
  }
  if (!validateCsrfRequest(req, credentials)) {
    return sendError(res, 403, 'csrf_invalid', '页面校验已过期，请刷新后重试。');
  }
  try {
    await callLotteryProvider('logout', {
      sessionTokenHash: credentials.sessionTokenHash,
      csrfTokenHash: credentials.csrfTokenHash,
    });
    clearLotterySessionCookies(req, res);
    return sendJson(res, 200, { success: true });
  } catch (error) {
    const normalized = businessError(error);
    return sendError(res, error?.status || 503, normalized.code, normalized.message);
  }
}

function requireDrawAuthorization(req, res, config) {
  const token = readBearerToken(req);
  if (!token || !safeEqual(token, config.drawSecret)) {
    sendError(res, 401, 'admin_unauthorized', '管理员凭据无效。');
    return false;
  }
  return true;
}

async function handlePrepare(req, res) {
  if (req.method !== 'POST') return methodNotAllowed(req, res, ['POST']);
  const config = requireRuntime(res, { includeDraw: true });
  if (!config || !requireDrawAuthorization(req, res, config)) return;
  try {
    const result = await callLotteryProvider('prepare', {
      seedCommitment: createHash('sha256').update(config.drawSeed, 'utf8').digest('hex'),
    });
    return sendJson(res, 200, { success: true, data: result });
  } catch (error) {
    const normalized = businessError(error);
    return sendError(res, error?.status || 409, normalized.code, normalized.message);
  }
}

async function handleDraw(req, res) {
  if (req.method !== 'POST') return methodNotAllowed(req, res, ['POST']);
  const config = requireRuntime(res, { includeDraw: true });
  if (!config || !requireDrawAuthorization(req, res, config)) return;
  try {
    const result = await callLotteryProvider('draw', { seed: config.drawSeed });
    return sendJson(res, 200, { success: true, data: result });
  } catch (error) {
    const normalized = businessError(error);
    return sendError(res, error?.status || 409, normalized.code, normalized.message);
  }
}

async function handleHealth(req, res) {
  if (req.method !== 'GET') return methodNotAllowed(req, res, ['GET']);
  const config = requireRuntime(res, { includeDraw: true });
  if (!config) return;
  try {
    const backend = await callLotteryProvider('health');
    const ready = backend?.schemaReady === true && backend?.campaignPrepared === true;
    return sendJson(res, ready ? 200 : 503, {
      success: ready,
      data: {
        service: 'endfield-summer-lottery',
        campaignId: config.campaignId,
        configured: true,
        ...backend,
      },
    });
  } catch (error) {
    const normalized = businessError(error);
    return sendError(res, error?.status || 503, normalized.code, normalized.message);
  }
}

export default async function handler(req, res) {
  if (req.method === 'OPTIONS') {
    res.statusCode = 204;
    res.end();
    return;
  }
  const path = parseRequest(req);
  if (path === '/api/lottery') return handleSnapshot(req, res);
  if (path === '/api/lottery/enter') return handleEnter(req, res);
  if (path === '/api/auth-pow-challenge') return handlePowChallenge(req, res);
  if (path === '/api/auth/sso/start') return handleSsoStart(req, res);
  if (path === '/api/auth/sso/callback') return handleSsoCallback(req, res);
  if (path === '/api/auth/logout') return handleLogout(req, res);
  if (path === '/api/admin/prepare') return handlePrepare(req, res);
  if (path === '/api/admin/draw') return handleDraw(req, res);
  if (path === '/api/health') return handleHealth(req, res);
  return sendError(res, 404, 'not_found', '接口不存在。');
}
