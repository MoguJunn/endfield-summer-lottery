import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  ArrowRight,
  CalendarDays,
  Check,
  CircleUserRound,
  Copy,
  ExternalLink,
  Gift,
  Info,
  LogIn,
  LogOut,
  LockKeyhole,
  MessageCircle,
  Moon,
  RefreshCw,
  ShieldCheck,
  Sparkles,
  Sun,
  TicketCheck,
  Trophy,
  Users,
  Waves,
  X,
} from 'lucide-react';
import LotteryCaptcha from './components/LotteryCaptcha.jsx';
import { DEFAULT_SITE_CONFIG, getContactInputProps, isValidContactValue } from './config/site.js';
import { enterLottery, exchangeSsoTicket, loadLottery, logoutLottery } from './services/api.js';
import {
  DEFAULT_DRAW_AT,
  formatEntryNumber,
  getCountdown,
  getPhaseCopy,
  getPrizeName,
} from './utils/campaign.js';
import { verifyPublicDraw } from './utils/drawVerification.js';

const AUTH_NOTICE = {
  signed_in: '活动账号登录成功，欢迎参与！',
  state_error: '登录校验已过期，请重新从本页发起登录。',
  ticket_error: '一次性登录票据无效或已使用，请重新登录。',
  session_error: '抽奖站会话创建失败，请稍后再试。',
  service_error: '登录服务暂时不可用，请稍后重试。',
  rate_error: '登录请求过于频繁，请稍后重试。',
};
const THEME_KEY = 'summer_lottery_theme';

function getInitialTheme() {
  try {
    const saved = window.localStorage.getItem(THEME_KEY);
    if (saved === 'light' || saved === 'dark') return saved;
  } catch {
    // Private browsing can disable localStorage.
  }
  return window.matchMedia?.('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
}

function formatEventTime(value, includeTime = true, timeZone = 'Asia/Shanghai') {
  if (!value) return '待公布';
  return new Intl.DateTimeFormat('zh-CN', {
    timeZone,
    month: '2-digit',
    day: '2-digit',
    ...(includeTime ? { hour: '2-digit', minute: '2-digit', hour12: false } : {}),
  }).format(new Date(value));
}

function Countdown({ targetAt }) {
  const [now, setNow] = useState(() => new Date());
  useEffect(() => {
    const timer = window.setInterval(() => setNow(new Date()), 1000);
    return () => window.clearInterval(timer);
  }, []);
  const countdown = getCountdown(targetAt, now);
  const units = [
    ['天', countdown.days],
    ['时', countdown.hours],
    ['分', countdown.minutes],
    ['秒', countdown.seconds],
  ];
  return (
    <div className="countdown" aria-label="活动倒计时">
      {units.map(([label, value]) => (
        <div className="countdown__unit" key={label}>
          <strong>{String(value).padStart(2, '0')}</strong>
          <span>{label}</span>
        </div>
      ))}
    </div>
  );
}

function PrizeVisual({ prize, count }) {
  const [hasImage, setHasImage] = useState(true);
  const Icon = prize.icon === 'ticket' ? TicketCheck : prize.icon === 'sparkles' ? Sparkles : Gift;
  return (
    <div className="gift-visual">
      {prize.imageUrl && hasImage ? (
        <img
          src={prize.imageUrl}
          alt={prize.title}
          onError={() => setHasImage(false)}
        />
      ) : (
        <div className="gift-visual__fallback"><Icon /><strong>{prize.title}</strong><small>OPEN LOTTERY</small></div>
      )}
      {count > 0 && <b>× {count}</b>}
    </div>
  );
}

function EntryPanel({ snapshot, phase, busy, onEnter, onLogout, site }) {
  const user = snapshot?.user;
  const entry = snapshot?.entry;
  const result = snapshot?.ownWinner;
  const eligible = entry?.eligible !== false;
  const phaseCopy = getPhaseCopy(phase);

  if (!user) {
    return (
      <section className="entry-panel entry-panel--guest">
        <div className="entry-panel__identity"><CircleUserRound /><span><small>EVENT ACCOUNT</small><strong>登录后领取活动票</strong></span></div>
        <a className="primary-button" href="/api/auth/sso/start"><LogIn /> 登录活动账号 <ArrowRight /></a>
      </section>
    );
  }

  return (
    <section className={`entry-panel ${entry ? 'entry-panel--confirmed' : ''}`}>
      <div className="entry-panel__identity">
        {entry && eligible ? <TicketCheck /> : <CircleUserRound />}
        <span>
          <small>{entry ? (eligible ? 'ENTRY CONFIRMED' : 'ENTRY INELIGIBLE') : 'ACCOUNT CONNECTED'}</small>
          <strong>{entry ? formatEntryNumber(entry.entryNumber, site.entryPrefix) : `你好，${user.username}`}</strong>
        </span>
      </div>
      <p>
        {result
          ? `本期结果：${site.prizes.find((prize) => prize.tier === result.prizeTier)?.title || getPrizeName(result.prizeTier)}`
          : entry && eligible
            ? `${formatEventTime(entry.createdAt, true, site.timeZone)} 已确认，静候开奖。`
            : entry
              ? '此编号未进入本期开奖名单。'
              : '每个活动账号仅有一次有效参与资格。'}
      </p>
      <div className="entry-panel__actions">
        {!entry && (
          <button className="primary-button" type="button" disabled={busy || phase !== 'open'} onClick={onEnter}>
            {busy ? <RefreshCw className="spin" /> : <Sparkles />}{busy ? '正在确认…' : phaseCopy.action}<ArrowRight />
          </button>
        )}
        {entry && eligible && <span className="confirmed-pill"><Check /> 已参与</span>}
        <button className="icon-button icon-button--quiet" type="button" onClick={onLogout} disabled={busy} title="退出抽奖站"><LogOut /></button>
      </div>
    </section>
  );
}

function ParticipationDialog({ busy, onClose, onSubmit, site }) {
  const [contactValue, setContactValue] = useState('');
  const [notificationConfirmed, setNotificationConfirmed] = useState(false);
  const [captcha, setCaptcha] = useState(null);
  const [localError, setLocalError] = useState('');
  const [copied, setCopied] = useState(false);

  useEffect(() => {
    const originalOverflow = document.body.style.overflow;
    document.body.style.overflow = 'hidden';
    const onKeyDown = (event) => {
      if (event.key === 'Escape' && !busy) onClose();
    };
    window.addEventListener('keydown', onKeyDown);
    return () => {
      document.body.style.overflow = originalOverflow;
      window.removeEventListener('keydown', onKeyDown);
    };
  }, [busy, onClose]);

  const copyNotificationValue = async () => {
    try {
      await navigator.clipboard.writeText(site.contact.notificationValue);
      setCopied(true);
      window.setTimeout(() => setCopied(false), 1800);
    } catch {
      setLocalError(`请手动复制：${site.contact.notificationValue}`);
    }
  };

  const submit = async (event) => {
    event.preventDefault();
    setLocalError('');
    if (!isValidContactValue(contactValue, site.contact)) {
      setLocalError(`请输入正确的${site.contact.label}。`);
      return;
    }
    if (site.contact.notificationRequired && !notificationConfirmed) {
      setLocalError('请先加入活动通知渠道，并勾选确认。');
      return;
    }
    if (captcha?.ready !== true) {
      setLocalError('请先完成机器人验证。');
      return;
    }
    const result = await onSubmit({ contactValue, notificationConfirmed, captcha });
    if (result.ok) {
      onClose();
      return;
    }
    setLocalError(result.message);
  };

  return (
    <div className="participation-modal" role="presentation" onMouseDown={(event) => {
      if (event.target === event.currentTarget && !busy) onClose();
    }}>
      <section className="participation-dialog" role="dialog" aria-modal="true" aria-labelledby="participation-title">
        <header>
          <div><small>COMPLETE YOUR ENTRY</small><h2 id="participation-title">确认参与信息</h2></div>
          <button type="button" onClick={onClose} disabled={busy} aria-label="关闭参与窗口"><X /></button>
        </header>
        <form onSubmit={submit}>
          <div className="entry-step">
            <span className="entry-step__number">01</span>
            <div className="entry-step__content">
              <label htmlFor="lottery-contact-value">填写{site.contact.label}</label>
              <input
                id="lottery-contact-value"
                {...getContactInputProps(site.contact)}
                autoComplete="off"
                placeholder={site.contact.placeholder}
                value={contactValue}
                onChange={(event) => setContactValue(
                  site.contact.format === 'qq'
                    ? event.target.value.replace(/\D/gu, '').slice(0, 12)
                    : event.target.value,
                )}
              />
              <p className="privacy-note"><LockKeyhole />{site.contact.privacyNotice}</p>
            </div>
          </div>

          {(site.contact.notificationRequired || site.contact.notificationValue) && <div className="entry-step">
            <span className="entry-step__number">02</span>
            <div className="entry-step__content">
              <strong>{site.contact.notificationLabel}</strong>
              <div className="qq-group-card">
                <MessageCircle />
                <span><small>活动通知</small><b>{site.contact.notificationValue}</b></span>
                {site.contact.notificationValue && <button type="button" onClick={copyNotificationValue}><Copy />{copied ? '已复制' : '复制'}</button>}
              </div>
              <p>{site.contact.notificationDescription}</p>
              {site.contact.notificationRequired && <label className="group-confirmation">
                <input type="checkbox" checked={notificationConfirmed} onChange={(event) => setNotificationConfirmed(event.target.checked)} />
                <span><Check /></span>
                {site.contact.confirmationLabel}
              </label>}
            </div>
          </div>}

          <div className="entry-step">
            <span className="entry-step__number">{site.contact.notificationRequired || site.contact.notificationValue ? '03' : '02'}</span>
            <div className="entry-step__content">
              <strong>完成机器人验证</strong>
              <LotteryCaptcha onStateChange={setCaptcha} />
            </div>
          </div>

          {localError && <div className="participation-error"><ShieldCheck />{localError}</div>}
          <div className="participation-dialog__actions">
            <button type="button" className="secondary-button" onClick={onClose} disabled={busy}>稍后再说</button>
            <button type="submit" className="primary-button" disabled={busy}>
              {busy ? <RefreshCw className="spin" /> : <TicketCheck />}
              {busy ? '正在确认…' : '确认参与抽奖'}
              {!busy && <ArrowRight />}
            </button>
          </div>
        </form>
      </section>
    </div>
  );
}

function PrizePane({ prizes, prizePlan }) {
  return (
    <div className="prize-strip">
      {prizes.map((prize, index) => {
        const count = prize.tier === 'participation' ? null : prizePlan?.[prize.tier] ?? 0;
        return (
          <article className={`prize-tile ${index === 0 ? 'prize-tile--major' : ''}`} key={`${prize.tier}-${index}`}>
            <span className="prize-tile__rank">{prize.rank}</span>
            {index === 0
              ? <PrizeVisual prize={prize} count={count} />
              : <div className="prize-tile__icon">{prize.icon === 'ticket' ? <TicketCheck /> : prize.icon === 'sparkles' ? <Sparkles /> : <Gift />}</div>}
            <div><small>{count == null ? '成功参与即可获得' : `${count} 名`}</small><h3>{prize.title}</h3><p>{prize.description}</p></div>
          </article>
        );
      })}
    </div>
  );
}

function RulesPane({ campaign }) {
  const rules = [
    ['01', '登录即可参加', '使用活动账号登录，演示模式无需额外注册。'],
    ['02', '每人只有一次机会', '每个账号只能参加一次，多次点击不会增加中奖机会。'],
    ['03', '记得在截止前参加', '活动截止后无法补录，请以页面显示的活动状态为准。'],
    ['04', '开奖结果可以复查', '开奖后会公布中奖名单和核对信息，任何人都可以自行检查。'],
  ];
  return (
    <div className="rules-pane">
      <div className="rule-list">
        {rules.map(([number, title, copy]) => <article key={number}><span>{number}</span><div><strong>{title}</strong><p>{copy}</p></div></article>)}
      </div>
      <aside className="commitment-card"><ShieldCheck /><strong>开奖核对码</strong><p>活动开始前已经锁定，开奖后会公开原始信息供大家核对。</p><code>{campaign?.seedCommitment || '活动准备完成后公布'}</code></aside>
    </div>
  );
}

function ResultsPane({ snapshot, site }) {
  const [verification, setVerification] = useState(null);
  useEffect(() => {
    let active = true;
    if (snapshot?.campaign?.phase !== 'drawn') return undefined;
    void verifyPublicDraw(snapshot).then((result) => { if (active) setVerification(result); });
    return () => { active = false; };
  }, [snapshot]);

  if (snapshot?.campaign?.phase !== 'drawn') {
    return (
      <div className="waiting-result">
        <div className="waiting-result__icon"><Trophy /><Sparkles /></div>
        <div><h3>开奖后在这里公布结果</h3></div>
      </div>
    );
  }

  return (
    <div className="results-pane">
      <div className="winner-list">
        {(snapshot.publicWinners || []).map((winner) => (
          <article key={`${winner.prizeTier}-${winner.winnerOrder}`}><Trophy /><span><small>{site.prizes.find((prize) => prize.tier === winner.prizeTier)?.title || getPrizeName(winner.prizeTier)}</small><strong>{winner.displayName}</strong></span><code>{formatEntryNumber(winner.entryNumber, site.entryPrefix)}</code></article>
        ))}
      </div>
      <aside className={`verification-card ${verification?.valid ? 'is-valid' : ''}`}>
        <ShieldCheck /><strong>{verification == null ? '正在核对开奖结果…' : verification.valid ? '开奖结果核对一致' : '开奖结果核对异常'}</strong>
        <details><summary>查看开奖核对信息</summary><small>公共随机轮次：{snapshot.campaign.publicRandomnessRound}</small><code>{snapshot.campaign.candidateManifestHash}</code></details>
      </aside>
    </div>
  );
}

function InfoPane({ activeTab, snapshot, site }) {
  const tabs = [
    ['prizes', '活动奖品', Gift],
    ['rules', '参与规则', Info],
    ['results', '开奖结果', Trophy],
  ];
  return (
    <section className="info-deck">
      <div className="info-deck__tabs" role="tablist" aria-label="活动信息">
        {tabs.map(([id, label, Icon]) => <button type="button" role="tab" aria-selected={activeTab.value === id} className={activeTab.value === id ? 'is-active' : ''} key={id} onClick={() => activeTab.set(id)}><Icon />{label}</button>)}
      </div>
      <div className="info-deck__body" role="tabpanel" key={activeTab.value}>
        {activeTab.value === 'prizes' && <PrizePane prizes={site.prizes} prizePlan={snapshot?.campaign?.prizePlan} />}
        {activeTab.value === 'rules' && <RulesPane campaign={snapshot?.campaign} />}
        {activeTab.value === 'results' && <ResultsPane snapshot={snapshot} site={site} />}
      </div>
    </section>
  );
}

export default function App() {
  const [snapshot, setSnapshot] = useState(null);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');
  const [theme, setTheme] = useState(getInitialTheme);
  const [activeTab, setActiveTab] = useState('prizes');
  const [entryDialogOpen, setEntryDialogOpen] = useState(false);

  const refresh = useCallback(async ({ clearExistingError = true } = {}) => {
    if (clearExistingError) setError('');
    try {
      setSnapshot(await loadLottery());
    } catch (requestError) {
      setError(requestError.message);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    document.documentElement.dataset.theme = theme;
    try { window.localStorage.setItem(THEME_KEY, theme); } catch { /* Theme still works for this tab. */ }
  }, [theme]);

  useEffect(() => {
    const initialize = async () => {
      let preserveAuthError = false;
      const fragment = new URLSearchParams(window.location.hash.replace(/^#/u, ''));
      const ticket = fragment.get('sso_ticket');
      const state = fragment.get('state');
      if (ticket || state) {
        window.history.replaceState({}, '', `${window.location.pathname}${window.location.search}`);
        try {
          await exchangeSsoTicket(ticket, state);
          setNotice(AUTH_NOTICE.signed_in);
        } catch (requestError) {
          setError(requestError.message);
        }
      } else {
        const params = new URLSearchParams(window.location.search);
        const authResult = params.get('auth');
        if (authResult && AUTH_NOTICE[authResult]) {
          if (authResult === 'signed_in') setNotice(AUTH_NOTICE[authResult]);
          else { setError(AUTH_NOTICE[authResult]); preserveAuthError = true; }
          params.delete('auth');
          const query = params.toString();
          window.history.replaceState({}, '', `${window.location.pathname}${query ? `?${query}` : ''}`);
        }
      }
      await refresh({ clearExistingError: !((ticket || state) || preserveAuthError) });
    };
    void initialize();
  }, [refresh]);

  const campaign = snapshot?.campaign;
  const site = snapshot?.site || DEFAULT_SITE_CONFIG;
  const phase = campaign?.phase || 'unavailable';
  const phaseCopy = getPhaseCopy(phase);
  const countdownTarget = phase === 'open' ? campaign?.closesAt : campaign?.drawsAt || DEFAULT_DRAW_AT;
  const participantLabel = useMemo(() => loading ? '读取中' : `${snapshot?.entryCount || 0} 人已参与`, [loading, snapshot?.entryCount]);

  useEffect(() => {
    const refreshAtBoundary = () => void refresh();
    const next = [campaign?.closesAt, campaign?.drawsAt]
      .map((value) => new Date(value || 0).getTime())
      .filter((value) => Number.isFinite(value) && value > Date.now())
      .sort((a, b) => a - b)[0];
    const timer = next ? window.setTimeout(refreshAtBoundary, Math.min(next - Date.now() + 250, 2_147_000_000)) : null;
    window.addEventListener('focus', refreshAtBoundary);
    return () => { if (timer) window.clearTimeout(timer); window.removeEventListener('focus', refreshAtBoundary); };
  }, [campaign?.closesAt, campaign?.drawsAt, refresh]);

  const handleEnter = async (details) => {
    setBusy(true); setError('');
    try {
      await enterLottery(details);
      setNotice('参与成功，活动票已经生成。');
      await refresh();
      return { ok: true };
    } catch (requestError) {
      setError(requestError.message);
      return { ok: false, message: requestError.message };
    } finally {
      setBusy(false);
    }
  };

  const handleLogout = async () => {
    setBusy(true);
    try { await logoutLottery(); setNotice('已退出活动站。'); await refresh(); }
    catch (requestError) { setError(requestError.message); }
    finally { setBusy(false); }
  };

  return (
    <div className="site-shell">
      <header className="topbar">
        <a className="brand" href="#top" aria-label={`${site.brand.name}首页`}><span className="brand__mark">{site.brand.mark}</span><span><b>{site.brand.name}</b><small>{site.brand.tagline}</small></span></a>
        <div className="topbar__actions">
          <span className={`phase-chip phase-chip--${phase}`}><i />{phaseCopy.title}</span>
          {snapshot?.mainSiteUrl && <a className="icon-button" href={snapshot.mainSiteUrl} target="_blank" rel="noreferrer" title="返回主站"><ExternalLink /></a>}
          <button className="theme-toggle" type="button" onClick={() => setTheme(theme === 'light' ? 'dark' : 'light')} aria-label={`切换为${theme === 'light' ? '暗色' : '亮色'}主题`}><Sun /><span /><Moon /></button>
        </div>
      </header>

      <main className="event-screen" id="top">
        <div className="ambient ambient--one" /><div className="ambient ambient--two" /><div className="dot-field" />
        <section className="event-grid">
          <div className="hero-copy">
            <div className="event-kicker"><Waves /> {site.hero.kicker}</div>
            <h1>
              <span className="hero-title-word">{site.hero.titleLineOne}</span>
              <span className="hero-title-line">
                <span className="hero-title-word">{site.hero.titleLineTwo}</span>
                <em className="hero-year-badge" aria-label={site.hero.yearBadge}><b aria-hidden="true">{site.hero.yearBadge}</b></em>
              </span>
            </h1>
            <div className="hero-copy__cn"><i /> {site.hero.title} <i /></div>
            <p>{site.hero.description}</p>
            <div className="event-meta">
              <span><CalendarDays /> {formatEventTime(campaign?.startsAt, false, site.timeZone)} — {formatEventTime(campaign?.closesAt || DEFAULT_DRAW_AT, false, site.timeZone)}</span>
              <span><Users /> {participantLabel}</span>
            </div>
          </div>

          <div className="hero-art" aria-hidden="true">
            <div className="sun-orbit"><Sun /><i /><i /><i /></div>
            <div className="ticket-poster"><span>{site.entryPrefix} / {site.hero.yearBadge}</span><strong>{site.hero.title}<br />好运募集计划</strong><small>LOGIN · ENTER · DRAW</small><div className="ticket-poster__waves"><i /><i /><i /></div></div>
            <Sparkles className="hero-art__spark hero-art__spark--one" /><Sparkles className="hero-art__spark hero-art__spark--two" />
          </div>

          <section className="status-card">
            <div className="status-card__copy"><small>{phaseCopy.eyebrow}</small><strong>{phaseCopy.title}</strong></div>
            <Countdown targetAt={countdownTarget} />
          </section>

          <EntryPanel snapshot={snapshot} phase={phase} busy={busy} onEnter={() => setEntryDialogOpen(true)} onLogout={handleLogout} site={site} />
        </section>

        <div className="toast-stack" aria-live="polite">
          {notice && <div className="toast toast--success"><Check />{notice}<button type="button" onClick={() => setNotice('')} aria-label="关闭提示"><X /></button></div>}
          {error && <div className="toast toast--error"><ShieldCheck />{error}<button type="button" onClick={() => setError('')} aria-label="关闭错误"><X /></button></div>}
        </div>

        <InfoPane activeTab={{ value: activeTab, set: setActiveTab }} snapshot={snapshot} site={site} />
      </main>

      <footer><span>{site.brand.name}</span><p>{site.brand.footer}</p></footer>
      {entryDialogOpen && snapshot?.user && !snapshot?.entry && (
        <ParticipationDialog
          busy={busy}
          onClose={() => setEntryDialogOpen(false)}
          onSubmit={handleEnter}
          site={site}
        />
      )}
    </div>
  );
}
