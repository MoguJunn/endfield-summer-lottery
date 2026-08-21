function readCookie(name) {
  const prefix = `${name}=`;
  return document.cookie
    .split(';')
    .map((item) => item.trim())
    .find((item) => item.startsWith(prefix))
    ?.slice(prefix.length) || '';
}

async function request(path, options = {}) {
  const headers = new Headers(options.headers || {});
  if (options.body && !headers.has('Content-Type')) {
    headers.set('Content-Type', 'application/json');
  }
  if (options.method && !['GET', 'HEAD'].includes(options.method.toUpperCase())) {
    const csrfToken = readCookie('summer_lottery_csrf');
    if (csrfToken) headers.set('x-csrf-token', decodeURIComponent(csrfToken));
  }

  const response = await fetch(path, {
    ...options,
    headers,
    credentials: 'include',
  });
  const payload = await response.json().catch(() => null);
  if (!response.ok || payload?.success === false) {
    const error = new Error(payload?.error?.message || '请求失败，请稍后再试。');
    error.code = payload?.error?.code || `http_${response.status}`;
    error.status = response.status;
    throw error;
  }
  return payload?.data;
}

export function loadLottery() {
  return request('/api/lottery');
}

export async function loadLotteryArchive(campaignId) {
  const normalizedId = String(campaignId || '').trim();
  if (!/^[a-z0-9][a-z0-9_-]{2,79}$/u.test(normalizedId)) {
    throw new Error('无效的历史活动编号。');
  }

  const response = await fetch(`/lottery/local-activity/archives/${encodeURIComponent(normalizedId)}.json`, {
    credentials: 'same-origin',
    headers: { Accept: 'application/json' },
  });
  const payload = await response.json().catch(() => null);
  if (!response.ok || !payload) throw new Error('历史活动公示暂时不可用。');
  return payload?.data || payload;
}

export function enterLottery({ contactValue, notificationConfirmed, captcha } = {}) {
  return request('/api/lottery/enter', {
    method: 'POST',
    body: JSON.stringify({
      contactValue,
      notificationConfirmed,
      captchaToken: captcha?.token || '',
      captchaProvider: captcha?.provider || '',
      powPayload: captcha?.powPayload || null,
    }),
  });
}

export function exchangeSsoTicket(ticket, state) {
  return request('/api/auth/sso/callback', {
    method: 'POST',
    body: JSON.stringify({ ticket, state }),
  });
}

export function logoutLottery() {
  return request('/api/auth/logout', { method: 'POST', body: '{}' });
}
