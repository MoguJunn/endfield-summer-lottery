export const DEFAULT_DRAW_AT = '2099-12-31T23:00:00Z';

export function getCountdown(targetAt, now = new Date()) {
  const distance = Math.max(0, new Date(targetAt).getTime() - now.getTime());
  const totalSeconds = Math.floor(distance / 1000);
  return {
    complete: distance <= 0,
    days: Math.floor(totalSeconds / 86400),
    hours: Math.floor((totalSeconds % 86400) / 3600),
    minutes: Math.floor((totalSeconds % 3600) / 60),
    seconds: totalSeconds % 60,
  };
}

export function formatEntryNumber(value, prefix = 'LOT') {
  const number = Number.parseInt(String(value || ''), 10);
  const safePrefix = String(prefix || 'LOT').replace(/[^A-Z0-9-]/giu, '').toUpperCase() || 'LOT';
  return Number.isFinite(number) && number > 0 ? `${safePrefix}-${String(number).padStart(6, '0')}` : `${safePrefix}------`;
}

export function getPhaseCopy(phase) {
  const mapping = {
    scheduled: { eyebrow: 'ACTIVITY SCHEDULED', title: '活动即将开启', action: '暂未开始' },
    preparing: { eyebrow: 'PREPARING', title: '活动正在准备', action: '稍后开放' },
    open: { eyebrow: 'ENTRY CLOSING IN', title: '距离参与截止还有', action: '立即参与抽奖' },
    waiting_draw: { eyebrow: 'ENTRY CLOSED', title: '参与已截止，等待开奖', action: '等待开奖' },
    ready_to_draw: { eyebrow: 'DRAW PENDING', title: '已到开奖时间', action: '等待公布结果' },
    drawn: { eyebrow: 'RESULT ANNOUNCED', title: '本期结果已经公布', action: '查看结果' },
    closed: { eyebrow: 'ENTRY CLOSED', title: '活动已提前停止参与', action: '不可参与' },
    cancelled: { eyebrow: 'ACTIVITY CLOSED', title: '活动已取消', action: '不可参与' },
    unavailable: { eyebrow: 'SERVICE OFFLINE', title: '活动服务暂不可用', action: '暂不可用' },
  };
  return mapping[phase] || mapping.unavailable;
}

export function getPrizeName(tier) {
  if (tier === 'first') return '一等奖';
  if (tier === 'second') return '二等奖';
  if (tier === 'ineligible') return '未进入开奖名单';
  return '参与纪念';
}
