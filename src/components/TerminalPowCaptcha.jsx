import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { ArrowRight, Check, Cpu, Loader2, TerminalSquare } from 'lucide-react';
import { getPowWorkConfig } from '../utils/powChallengeCore.js';

function createSessionId() {
  return `GATE-${Math.floor(Math.random() * 0xffff).toString(16).padStart(4, '0').toUpperCase()}`;
}

function createWorkerUrl() {
  const workerSource = `
    const encoder = new TextEncoder();
    function toHex(buffer) {
      return Array.from(new Uint8Array(buffer), (value) => value.toString(16).padStart(2, '0')).join('');
    }
    async function hashStep(seed, step, previousHash, rounds) {
      let payload = encoder.encode(seed + ':' + step + ':' + previousHash);
      let hex = '';
      for (let round = 0; round < rounds; round += 1) {
        const digest = await crypto.subtle.digest('SHA-256', payload);
        hex = toHex(digest);
        if (round + 1 < rounds) payload = encoder.encode(seed + ':' + step + ':' + hex + ':' + (round + 1));
      }
      return hex;
    }
    self.onmessage = async (event) => {
      const { seed, rounds, totalSteps, progressInterval } = event.data;
      let step = 0;
      let hash = seed;
      let lastProgress = 0;
      while (step < totalSteps) {
        hash = await hashStep(seed, step, hash, rounds);
        step += 1;
        if (step - lastProgress >= progressInterval || step === totalSteps) {
          lastProgress = step;
          self.postMessage({ type: 'progress', step, hash });
        }
      }
      self.postMessage({ type: 'done', step: totalSteps, hash });
    };
  `;
  return URL.createObjectURL(new Blob([workerSource], { type: 'application/javascript' }));
}

export default function TerminalPowCaptcha({ challenge, onVerified }) {
  const config = useMemo(() => getPowWorkConfig({
    isMobile: window.matchMedia?.('(max-width: 600px)').matches,
    difficulty: challenge?.difficulty,
    totalSteps: challenge?.totalSteps,
  }), [challenge]);
  const workerRef = useRef(null);
  const workerUrlRef = useRef('');
  const [sessionId] = useState(createSessionId);
  const [status, setStatus] = useState('idle');
  const [progress, setProgress] = useState(0);
  const [error, setError] = useState('');

  const cleanupWorker = useCallback(() => {
    workerRef.current?.terminate();
    workerRef.current = null;
    if (workerUrlRef.current) URL.revokeObjectURL(workerUrlRef.current);
    workerUrlRef.current = '';
  }, []);

  useEffect(() => cleanupWorker, [cleanupWorker]);

  const startPow = useCallback(() => {
    if (!challenge || typeof Worker === 'undefined' || !crypto?.subtle) {
      setStatus('error');
      setError('当前浏览器无法完成验证，请尝试更新浏览器或改用 Turnstile。');
      return;
    }
    cleanupWorker();
    setStatus('running');
    setProgress(0);
    setError('');
    const workerUrl = createWorkerUrl();
    const worker = new Worker(workerUrl);
    workerRef.current = worker;
    workerUrlRef.current = workerUrl;
    worker.onmessage = (event) => {
      const payload = event.data;
      if (payload.type === 'progress') {
        setProgress(Math.min(100, Math.round((payload.step / config.totalSteps) * 100)));
        return;
      }
      if (payload.type !== 'done') return;
      cleanupWorker();
      setProgress(100);
      setStatus('done');
      onVerified?.({
        action: challenge.action,
        algorithm: challenge.algorithm,
        challengeId: challenge.challengeId,
        difficulty: challenge.difficulty,
        expiresAt: challenge.expiresAt,
        hash: payload.hash,
        issuedAt: challenge.issuedAt,
        seed: challenge.seed,
        signature: challenge.signature,
        step: payload.step,
        totalSteps: config.totalSteps,
      });
    };
    worker.onerror = () => {
      cleanupWorker();
      setStatus('error');
      setError('验证没有完成，请重新试一次。');
    };
    worker.postMessage({
      seed: challenge.seed,
      rounds: config.rounds,
      totalSteps: config.totalSteps,
      progressInterval: config.progressInterval,
    });
  }, [challenge, cleanupWorker, config, onVerified]);

  return (
    <div className="pow-terminal">
      <div className="pow-terminal__bar">
        <span><TerminalSquare /> 边境值守终端</span>
        <code>{sessionId}</code>
      </div>
      <div className="pow-terminal__screen">
        <div className="pow-terminal__status">
          <span>机器人验证</span>
          <strong className={status === 'done' ? 'is-done' : ''}>
            {status === 'idle' ? '等待开始' : status === 'running' ? '正在计算' : status === 'done' ? '验证完成' : '需要重试'}
          </strong>
        </div>
        <p>{status === 'done' ? '已确认本次参与由真人操作。' : '浏览器会在本机完成一小段计算，通常只需几秒。'}</p>
        {(status === 'running' || status === 'done') && (
          <div className="pow-progress" aria-label={`验证进度 ${progress}%`}>
            <i style={{ width: `${progress}%` }} />
          </div>
        )}
        {error && <p className="pow-terminal__error">{error}</p>}
        <button type="button" onClick={startPow} disabled={status === 'running' || status === 'done'}>
          {status === 'running' ? <Loader2 className="spin" /> : status === 'done' ? <Check /> : <Cpu />}
          {status === 'idle' ? '开始验证' : status === 'running' ? '验证中…' : status === 'done' ? '已验证' : '重新验证'}
          {status === 'idle' && <ArrowRight />}
        </button>
      </div>
    </div>
  );
}
