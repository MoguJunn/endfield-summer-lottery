export const POW_ALGORITHM = 'sha256-chain-v1';

export function toHex(buffer) {
  return Array.from(new Uint8Array(buffer), (value) => value.toString(16).padStart(2, '0')).join('');
}

export function isLikelyMainlandChinaLocale({
  language = typeof navigator !== 'undefined' ? navigator.language : '',
  languages = typeof navigator !== 'undefined' ? navigator.languages : [],
  timezone = '',
} = {}) {
  const localeValues = [language, ...(Array.isArray(languages) ? languages : [])]
    .map((value) => String(value || '').toLowerCase());
  if (localeValues.some((value) => value === 'zh-cn' || value.startsWith('zh-hans'))) return true;
  const resolvedTimezone = timezone || (() => {
    try { return Intl.DateTimeFormat().resolvedOptions().timeZone || ''; } catch { return ''; }
  })();
  return ['Asia/Shanghai', 'Asia/Chongqing', 'Asia/Harbin', 'Asia/Urumqi'].includes(resolvedTimezone);
}

export function shouldPreferPowCaptcha(env = import.meta.env, runtime = {}) {
  const explicit = String(env?.VITE_AUTH_CAPTCHA_REGION_STRATEGY || env?.VITE_CAPTCHA_REGION_STRATEGY || '').trim().toLowerCase();
  if (['pow', 'cn-pow', 'china-pow'].includes(explicit)) return true;
  if (['turnstile', 'provider'].includes(explicit)) return false;
  return isLikelyMainlandChinaLocale(runtime);
}

export function getPowWorkConfig({ isMobile = false, difficulty = 3, totalSteps } = {}) {
  const normalizedDifficulty = Math.max(1, Math.min(5, Number.parseInt(difficulty, 10) || 3));
  const baseSteps = isMobile ? 5200 : 7200;
  const steps = Number.isFinite(Number(totalSteps)) && Number(totalSteps) > 0
    ? Number(totalSteps)
    : baseSteps + normalizedDifficulty * (isMobile ? 900 : 1200);
  return {
    difficulty: normalizedDifficulty,
    progressInterval: Math.max(120, Math.floor(steps / 10)),
    rounds: normalizedDifficulty,
    totalSteps: steps,
  };
}

export async function hashPowStep({ seed, step, previousHash, rounds, subtle = crypto.subtle }) {
  const encoder = new TextEncoder();
  let payload = encoder.encode(`${seed}:${step}:${previousHash}`);
  let hex = '';
  for (let round = 0; round < rounds; round += 1) {
    const digest = await subtle.digest('SHA-256', payload);
    hex = toHex(digest);
    if (round + 1 < rounds) payload = encoder.encode(`${seed}:${step}:${hex}:${round + 1}`);
  }
  return hex;
}

export async function solvePowChallenge(challenge, { onProgress, isMobile = false, subtle = crypto.subtle } = {}) {
  const config = getPowWorkConfig({
    isMobile,
    difficulty: challenge?.difficulty,
    totalSteps: challenge?.totalSteps,
  });
  let step = 0;
  let hash = challenge.seed;
  while (step < config.totalSteps) {
    hash = await hashPowStep({ seed: challenge.seed, step, previousHash: hash, rounds: config.rounds, subtle });
    step += 1;
    if (step % config.progressInterval === 0 || step === config.totalSteps) {
      onProgress?.({ step, totalSteps: config.totalSteps, hash });
    }
  }
  return {
    action: challenge.action,
    algorithm: challenge.algorithm || POW_ALGORITHM,
    challengeId: challenge.challengeId,
    difficulty: config.difficulty,
    expiresAt: challenge.expiresAt,
    hash,
    issuedAt: challenge.issuedAt,
    seed: challenge.seed,
    signature: challenge.signature,
    step,
    totalSteps: config.totalSteps,
  };
}
