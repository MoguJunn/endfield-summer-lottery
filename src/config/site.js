export const DEFAULT_SITE_CONFIG = Object.freeze({
  timeZone: 'Asia/Shanghai',
  fontStylesheetUrl: '',
  brand: {
    mark: 'OL',
    name: 'Open Lottery',
    tagline: 'COMMUNITY EVENT',
    footer: '本活动由社区组织者发起，请以活动规则为准。',
  },
  hero: {
    kicker: 'COMMUNITY × OPEN LOTTERY',
    titleLineOne: 'Summer',
    titleLineTwo: 'Lottery',
    yearBadge: String(new Date().getFullYear()).slice(-2),
    title: '社区抽奖活动',
    description: '登录活动账号，领取一张属于你的活动票。',
  },
  contact: {
    format: 'text',
    label: '领奖联系方式',
    placeholder: '请输入方便联系你的账号',
    privacyNotice: '联系方式只用于中奖后联系发奖，不会公开展示，也不会用于其他用途。',
    notificationRequired: false,
    notificationLabel: '活动通知渠道',
    notificationValue: '',
    notificationDescription: '活动结果公布后会通过配置的通知渠道提醒参与者。',
    confirmationLabel: '我已加入活动通知渠道',
  },
  prizes: [
    { tier: 'first', rank: '01', title: '一等奖', description: '请配置一等奖内容。', icon: 'gift', imageUrl: '/prize-placeholder.svg' },
    { tier: 'second', rank: '02', title: '二等奖', description: '请配置二等奖内容。', icon: 'sparkles', imageUrl: '' },
    { tier: 'participation', rank: 'ALL', title: '参与纪念', description: '成功参与的用户可获得参与纪念。', icon: 'ticket', imageUrl: '' },
  ],
  entryPrefix: 'LOT',
});

export function getContactInputProps(contact = DEFAULT_SITE_CONFIG.contact) {
  if (contact.format === 'qq') {
    return { inputMode: 'numeric', maxLength: 12, pattern: '[1-9][0-9]{4,11}' };
  }
  if (contact.format === 'email') {
    return { inputMode: 'email', maxLength: 254, type: 'email' };
  }
  return { inputMode: 'text', maxLength: 120, type: 'text' };
}

export function isValidContactValue(value, contact = DEFAULT_SITE_CONFIG.contact) {
  const normalized = String(value || '').trim();
  if (contact.format === 'qq') return /^[1-9][0-9]{4,11}$/u.test(normalized);
  if (contact.format === 'email') return /^[^\s@]+@[^\s@]+\.[^\s@]+$/u.test(normalized) && normalized.length <= 254;
  return normalized.length >= 2 && normalized.length <= 120;
}
