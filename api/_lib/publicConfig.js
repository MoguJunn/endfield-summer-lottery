const DEFAULT_PRIZES = Object.freeze([
  {
    tier: 'first',
    rank: '01',
    title: '一等奖',
    description: '请在部署配置中填写一等奖内容与领取方式。',
    icon: 'gift',
    imageUrl: '/prize-placeholder.svg',
  },
  {
    tier: 'second',
    rank: '02',
    title: '二等奖',
    description: '请在部署配置中填写二等奖内容与领取方式。',
    icon: 'sparkles',
    imageUrl: '',
  },
  {
    tier: 'participation',
    rank: 'ALL',
    title: '参与纪念',
    description: '成功参与且未中前两档奖品的用户可获得参与纪念。',
    icon: 'ticket',
    imageUrl: '',
  },
]);

function text(value, fallback, maxLength = 240) {
  const normalized = String(value || '').trim();
  return (normalized || fallback).slice(0, maxLength);
}

function boolean(value, fallback = false) {
  const normalized = String(value ?? '').trim().toLowerCase();
  if (['1', 'true', 'yes', 'on'].includes(normalized)) return true;
  if (['0', 'false', 'no', 'off'].includes(normalized)) return false;
  return fallback;
}

function normalizeContactFormat(value) {
  const normalized = String(value || '').trim().toLowerCase();
  return ['qq', 'email', 'text'].includes(normalized) ? normalized : 'text';
}

function normalizeIcon(value) {
  const normalized = String(value || '').trim().toLowerCase();
  return ['gift', 'sparkles', 'ticket'].includes(normalized) ? normalized : 'gift';
}

function normalizeAssetUrl(value, fallback = '') {
  const normalized = text(value, fallback, 500);
  if (normalized.startsWith('/') && !normalized.startsWith('//')) return normalized;
  try {
    const url = new URL(normalized);
    return ['http:', 'https:'].includes(url.protocol) ? url.toString() : '';
  } catch {
    return '';
  }
}

function normalizeTimeZone(value) {
  const normalized = text(value, 'Asia/Shanghai', 80);
  try {
    new Intl.DateTimeFormat('zh-CN', { timeZone: normalized }).format();
    return normalized;
  } catch {
    return 'UTC';
  }
}

function parsePrizes(rawValue) {
  if (!rawValue) return DEFAULT_PRIZES.map((prize) => ({ ...prize }));
  try {
    const parsed = JSON.parse(rawValue);
    if (!Array.isArray(parsed) || !parsed.length) throw new Error('invalid_prizes');
    return parsed.slice(0, 8).map((prize, index) => {
      const fallback = DEFAULT_PRIZES[index] || DEFAULT_PRIZES.at(-1);
      return {
        tier: text(prize?.tier, fallback.tier, 40).toLowerCase(),
        rank: text(prize?.rank, fallback.rank, 12),
        title: text(prize?.title, fallback.title, 80),
        description: text(prize?.description, fallback.description, 240),
        icon: normalizeIcon(prize?.icon || fallback.icon),
        imageUrl: normalizeAssetUrl(prize?.imageUrl, fallback.imageUrl),
      };
    });
  } catch {
    return DEFAULT_PRIZES.map((prize) => ({ ...prize }));
  }
}

function parseRules(rawValue) {
  const fallback = {
    version: '活动规则',
    notice: '参与前请完整阅读规则；奖品、时间和领取方式以本页公示内容为准。',
    items: [
      { title: '登录即可参加', description: '使用活动账号登录并完成参与信息确认。' },
      { title: '每个账号一次资格', description: '同一活动账号只能获得一个有效参与编号。' },
      { title: '截止后不再补录', description: '请在页面显示的截止时间前完成参与。' },
      { title: '开奖结果可以复查', description: '开奖后会公开候选清单和核对信息。' },
    ],
  };
  if (!rawValue) return fallback;
  try {
    const parsed = JSON.parse(rawValue);
    if (!Array.isArray(parsed?.items) || !parsed.items.length) throw new Error('invalid_rules');
    return {
      version: text(parsed.version, fallback.version, 80),
      notice: text(parsed.notice, fallback.notice, 300),
      items: parsed.items.slice(0, 12).map((item, index) => ({
        title: text(item?.title, `规则 ${index + 1}`, 100),
        description: text(item?.description, '', 500),
      })),
    };
  } catch {
    return fallback;
  }
}

export function getPublicSiteConfig(env = process.env) {
  const contactFormat = normalizeContactFormat(env.LOTTERY_CONTACT_FORMAT);
  const defaultContactLabel = contactFormat === 'qq'
    ? '领奖 QQ 号'
    : contactFormat === 'email'
      ? '领奖邮箱'
      : '领奖联系方式';
  const defaultPlaceholder = contactFormat === 'qq'
    ? '请输入你的 QQ 号'
    : contactFormat === 'email'
      ? '请输入你的邮箱'
      : '请输入方便联系你的账号';

  return {
    timeZone: normalizeTimeZone(env.LOTTERY_TIME_ZONE),
    fontStylesheetUrl: normalizeAssetUrl(env.LOTTERY_BODY_FONT_STYLESHEET_URL),
    brand: {
      mark: text(env.LOTTERY_BRAND_MARK, 'OL', 4),
      name: text(env.LOTTERY_BRAND_NAME, 'Open Lottery', 80),
      tagline: text(env.LOTTERY_BRAND_TAGLINE, 'COMMUNITY EVENT', 80),
      footer: text(env.LOTTERY_FOOTER_NOTICE, '本活动由社区组织者发起，请以活动规则为准。', 180),
    },
    hero: {
      kicker: text(env.LOTTERY_HERO_KICKER, 'COMMUNITY × OPEN LOTTERY', 100),
      titleLineOne: text(env.LOTTERY_HERO_TITLE_LINE_ONE, 'Summer', 40),
      titleLineTwo: text(env.LOTTERY_HERO_TITLE_LINE_TWO, 'Lottery', 40),
      yearBadge: text(env.LOTTERY_HERO_YEAR_BADGE, String(new Date().getFullYear()).slice(-2), 4),
      title: text(env.LOTTERY_HERO_TITLE, '社区抽奖活动', 80),
      description: text(env.LOTTERY_HERO_DESCRIPTION, '登录活动账号，领取一张属于你的活动票。', 220),
    },
    contact: {
      format: contactFormat,
      label: text(env.LOTTERY_CONTACT_LABEL, defaultContactLabel, 80),
      placeholder: text(env.LOTTERY_CONTACT_PLACEHOLDER, defaultPlaceholder, 100),
      privacyNotice: text(
        env.LOTTERY_CONTACT_PRIVACY_NOTICE,
        '联系方式只用于中奖后联系发奖，不会公开展示，也不会用于其他用途。',
        240,
      ),
      notificationRequired: boolean(env.LOTTERY_NOTIFICATION_REQUIRED, false),
      notificationLabel: text(env.LOTTERY_NOTIFICATION_LABEL, '活动通知渠道', 80),
      notificationValue: text(env.LOTTERY_NOTIFICATION_VALUE, '', 120),
      notificationDescription: text(
        env.LOTTERY_NOTIFICATION_DESCRIPTION,
        '活动结果公布后会通过配置的通知渠道提醒参与者。',
        220,
      ),
      confirmationLabel: text(env.LOTTERY_NOTIFICATION_CONFIRMATION_LABEL, '我已加入活动通知渠道', 140),
    },
    prizes: parsePrizes(env.LOTTERY_PRIZES_JSON),
    rules: parseRules(env.LOTTERY_RULES_JSON),
    entryPrefix: text(env.LOTTERY_ENTRY_PREFIX, 'LOT', 12).replace(/[^A-Z0-9-]/giu, '').toUpperCase() || 'LOT',
  };
}

export function validateContactValue(rawValue, format = 'text') {
  const value = String(rawValue || '').trim();
  if (format === 'qq') return /^[1-9][0-9]{4,11}$/u.test(value);
  if (format === 'email') return /^[^\s@]+@[^\s@]+\.[^\s@]+$/u.test(value) && value.length <= 254;
  return value.length >= 2 && value.length <= 120;
}
