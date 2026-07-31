// @vitest-environment node

import { describe, expect, it } from 'vitest';
import { getPublicSiteConfig, validateContactValue } from './publicConfig.js';

describe('public site configuration', () => {
  it('normalizes configurable content without exposing unrelated environment values', () => {
    const site = getPublicSiteConfig({
      LOTTERY_BRAND_NAME: 'Community Draw',
      LOTTERY_BODY_FONT_STYLESHEET_URL: '/brand/fonts.css',
      LOTTERY_CONTACT_FORMAT: 'email',
      LOTTERY_NOTIFICATION_REQUIRED: 'true',
      LOTTERY_NOTIFICATION_VALUE: 'announcements',
      LOTTERY_TIME_ZONE: 'not/a-zone',
      LOTTERY_PRIZES_JSON: JSON.stringify([{
        tier: 'first', title: 'Prize', imageUrl: 'javascript:alert(1)',
      }]),
      LOTTERY_SESSION_SECRET: 'must-not-be-public',
    });

    expect(site.brand.name).toBe('Community Draw');
    expect(site.fontStylesheetUrl).toBe('/brand/fonts.css');
    expect(site.contact).toEqual(expect.objectContaining({
      format: 'email',
      notificationRequired: true,
      notificationValue: 'announcements',
    }));
    expect(JSON.stringify(site)).not.toContain('must-not-be-public');
    expect(site.timeZone).toBe('UTC');
    expect(site.prizes[0].imageUrl).toBe('');
  });

  it('validates the supported contact formats', () => {
    expect(validateContactValue('123456789', 'qq')).toBe(true);
    expect(validateContactValue('participant@example.test', 'email')).toBe(true);
    expect(validateContactValue('demo-contact', 'text')).toBe(true);
    expect(validateContactValue('bad address', 'email')).toBe(false);
  });
});
