export async function createAuthPowChallenge(action, { timeoutMs = 12000 } = {}) {
  const controller = new AbortController();
  const timeout = window.setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch('/api/auth-pow-challenge', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action }),
      credentials: 'include',
      signal: controller.signal,
    });
    const payload = await response.json().catch(() => null);
    const challenge = payload?.data?.challenge || payload?.challenge;
    if (!response.ok || payload?.success !== true || !challenge) {
      throw new Error(payload?.error?.message || '机器人验证暂时不可用，请稍后重试。');
    }
    return challenge;
  } catch (error) {
    if (error?.name === 'AbortError') {
      throw new Error('机器人验证加载超时，请稍后重试。', { cause: error });
    }
    throw error;
  } finally {
    window.clearTimeout(timeout);
  }
}
