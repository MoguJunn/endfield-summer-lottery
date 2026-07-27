import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { AlertTriangle, CheckCircle2, ShieldCheck } from 'lucide-react';
import { ensureAuthCaptchaProviderScriptLoaded, getAuthCaptchaClientConfig } from '../services/authCaptchaClient.js';
import { createAuthPowChallenge } from '../services/powChallengeService.js';
import { shouldPreferPowCaptcha } from '../utils/powChallengeCore.js';
import TerminalPowCaptcha from './TerminalPowCaptcha.jsx';

const CAPTCHA_ACTION = 'lottery_enter';

export default function LotteryCaptcha({ onStateChange }) {
  const containerRef = useRef(null);
  const widgetIdRef = useRef(null);
  const config = useMemo(() => getAuthCaptchaClientConfig({ action: CAPTCHA_ACTION }), []);
  const preferPow = useMemo(() => shouldPreferPowCaptcha(import.meta.env), []);
  const [mode, setMode] = useState(() => (preferPow || !config.configured ? 'pow' : 'turnstile'));
  const [powChallenge, setPowChallenge] = useState(null);
  const [status, setStatus] = useState(() => config.enabled ? 'loading' : 'disabled');
  const [message, setMessage] = useState(() => config.enabled ? '正在准备机器人验证…' : '');

  const publishState = useCallback((nextStatus, {
    token = '',
    powPayload = null,
    provider = mode,
    nextMessage = '',
  } = {}) => {
    setStatus(nextStatus);
    setMessage(nextMessage);
    onStateChange?.({
      action: config.action,
      enabled: config.enabled,
      provider,
      ready: !config.enabled || !config.required || Boolean(token || powPayload),
      required: config.required,
      status: nextStatus,
      token,
      powPayload,
    });
  }, [config.action, config.enabled, config.required, mode, onStateChange]);

  useEffect(() => {
    if (!config.enabled) {
      queueMicrotask(() => onStateChange?.({
        action: config.action,
        enabled: false,
        provider: 'off',
        ready: true,
        required: false,
        status: 'disabled',
        token: '',
        powPayload: null,
      }));
    }
  }, [config.action, config.enabled, onStateChange]);

  useEffect(() => {
    if (!config.enabled || mode !== 'pow') return undefined;
    let cancelled = false;
    createAuthPowChallenge(config.action)
      .then((challenge) => {
        if (cancelled) return;
        setPowChallenge(challenge);
        publishState('ready', { provider: 'pow', nextMessage: '点击“开始验证”，通常几秒即可完成。' });
      })
      .catch((error) => {
        if (cancelled) return;
        publishState('error', { provider: 'pow', nextMessage: error?.message || '机器人验证暂时不可用。' });
      });
    return () => { cancelled = true; };
  }, [config.action, config.enabled, mode, publishState]);

  useEffect(() => {
    if (!config.enabled || mode !== 'turnstile') return undefined;
    let cancelled = false;
    ensureAuthCaptchaProviderScriptLoaded(config, window, document, 10000)
      .then((loaded) => {
        if (cancelled) return;
        if (!loaded || !window.turnstile?.render || !containerRef.current) {
          setMode('pow');
          return;
        }
        containerRef.current.innerHTML = '';
        widgetIdRef.current = window.turnstile.render(containerRef.current, {
          sitekey: config.siteKey,
          action: config.action,
          theme: 'auto',
          appearance: 'always',
          callback: (token) => {
            if (!cancelled) publishState('success', { provider: 'turnstile', token, nextMessage: '验证已完成。' });
          },
          'error-callback': () => {
            if (!cancelled) publishState('error', { provider: 'turnstile', nextMessage: 'Turnstile 验证失败，可以改用 PoW。' });
          },
          'expired-callback': () => {
            if (!cancelled) publishState('expired', { provider: 'turnstile', nextMessage: '验证已过期，请重新完成。' });
          },
          'timeout-callback': () => { if (!cancelled) setMode('pow'); },
        });
        publishState('ready', { provider: 'turnstile', nextMessage: '请完成人机验证。' });
      })
      .catch(() => { if (!cancelled) setMode('pow'); });
    return () => {
      cancelled = true;
      try {
        if (widgetIdRef.current !== null) window.turnstile?.remove?.(widgetIdRef.current);
      } catch {
        // Best-effort cleanup only.
      }
      widgetIdRef.current = null;
    };
  }, [config, mode, publishState]);

  if (!config.enabled) return null;
  const isError = status === 'error' || status === 'expired';

  return (
    <div className={`captcha-box ${status === 'success' ? 'is-success' : ''} ${isError ? 'is-error' : ''}`}>
      <div className="captcha-box__heading">
        {status === 'success' ? <CheckCircle2 /> : isError ? <AlertTriangle /> : <ShieldCheck />}
        <div>
          <strong>{mode === 'pow' ? 'PoW 本机验证' : 'Turnstile 人机验证'}</strong>
          <p>{message || '完成验证后即可提交参与信息。'}</p>
        </div>
        {config.configured && (
          <button type="button" onClick={() => {
            setPowChallenge(null);
            setStatus('loading');
            setMessage('正在切换验证方式…');
            setMode((current) => current === 'pow' ? 'turnstile' : 'pow');
          }}>
            {mode === 'pow' ? '使用 Turnstile' : '改用 PoW'}
          </button>
        )}
      </div>
      {mode === 'turnstile' && config.configured && <div className="captcha-box__turnstile" ref={containerRef} />}
      {mode === 'pow' && powChallenge && (
        <TerminalPowCaptcha
          key={powChallenge.challengeId}
          challenge={powChallenge}
          onVerified={(powPayload) => publishState('success', {
            provider: 'pow',
            powPayload,
            nextMessage: '本机验证已完成。',
          })}
        />
      )}
    </div>
  );
}
