import { describe, expect, it } from 'vitest';
import { formatEntryNumber, getCountdown, getPhaseCopy, getPrizeName } from './campaign.js';
import { getCampaignPhase, maskDisplayName } from '../../api/_lib/lottery.js';

describe('lottery campaign helpers', () => {
  it('builds a stable countdown without negative values', () => {
    expect(getCountdown('2026-08-25T20:00:00+08:00', new Date('2026-08-24T19:59:59+08:00'))).toEqual({
      complete: false,
      days: 1,
      hours: 0,
      minutes: 0,
      seconds: 1,
    });
    expect(getCountdown('2026-08-25T20:00:00+08:00', new Date('2026-08-26T00:00:00+08:00')).complete).toBe(true);
  });

  it('formats public entry numbers without exposing user ids', () => {
    expect(formatEntryNumber(42)).toBe('LOT-000042');
    expect(formatEntryNumber(null)).toBe('LOT------');
    expect(formatEntryNumber(7, 'event')).toBe('EVENT-000007');
  });

  it('maps phases and prize tiers to user-facing copy', () => {
    expect(getPhaseCopy('open').action).toBe('立即参与抽奖');
    expect(getPhaseCopy('unknown').eyebrow).toBe('SERVICE OFFLINE');
    expect(getPrizeName('participation')).toBe('参与纪念');
  });

  it('uses server campaign times to determine participation state', () => {
    const campaign = {
      starts_at: '2026-07-25T00:00:00+08:00',
      closes_at: '2026-08-25T20:00:00+08:00',
      draws_at: '2026-08-25T20:00:00+08:00',
      status: 'open',
      seed_commitment: 'a'.repeat(64),
    };
    expect(getCampaignPhase(campaign, new Date('2026-08-25T19:59:59+08:00'))).toBe('open');
    expect(getCampaignPhase(campaign, new Date('2026-08-25T20:00:01+08:00'))).toBe('ready_to_draw');
  });

  it('masks public winner names', () => {
    expect(maskDisplayName('蘑菇君')).toBe('蘑*君');
    expect(maskDisplayName('AB')).toBe('A*');
    expect(maskDisplayName('')).toBe('匿名参与者');
  });
});
