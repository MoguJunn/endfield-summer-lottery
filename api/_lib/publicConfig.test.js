// @vitest-environment node

import { describe, expect, it } from 'vitest';
import { getPublicSiteConfig, validateContactValue } from './publicConfig.js';

describe('public site configuration', () => {
  it('normalizes configurable content without exposing unrelated environment values', () => {
    const site = getPublicSiteConfig({
      LOTTERY_BRAND_NAME: 'Community Draw',
      LOTTERY_BODY_FONT_STYLESHEET_URL: '/brand/fonts.css',
      LOTTERY_SPONSOR_CREDIT: 'Thanks to the mirror maintainer',
      LOTTERY_ARCHIVE_URL: '/lottery/archive/example-campaign',
      LOTTERY_CONTACT_FORMAT: 'email',
      LOTTERY_NOTIFICATION_REQUIRED: 'true',
      LOTTERY_NOTIFICATION_VALUE: 'announcements',
      LOTTERY_TIME_ZONE: 'not/a-zone',
      LOTTERY_PRIZES_JSON: JSON.stringify([{
        tier: 'first', title: 'Prize', imageUrl: 'javascript:alert(1)',
      }]),
      LOTTERY_RULES_JSON: JSON.stringify({
        version: '2026 rules',
        notice: 'Read before entering.',
        items: [{ title: 'Eligibility', description: 'One entry per account.' }],
      }),
      LOTTERY_SESSION_SECRET: 'must-not-be-public',
    });

    expect(site.brand.name).toBe('Community Draw');
    expect(site.fontStylesheetUrl).toBe('/brand/fonts.css');
    expect(site.hero.sponsor).toBe('Thanks to the mirror maintainer');
    expect(site.archive.url).toBe('/lottery/archive/example-campaign');
    expect(site.contact).toEqual(expect.objectContaining({
      format: 'email',
      notificationRequired: true,
      notificationValue: 'announcements',
    }));
    expect(JSON.stringify(site)).not.toContain('must-not-be-public');
    expect(site.timeZone).toBe('UTC');
    expect(site.prizes[0].imageUrl).toBe('');
    expect(site.prizes[0].imageUrls).toEqual([]);
    expect(site.rules).toEqual({
      version: '2026 rules',
      notice: 'Read before entering.',
      items: [{ title: 'Eligibility', description: 'One entry per account.' }],
    });
  });

  it('normalizes multiple prize images and keeps only safe unique urls', () => {
    const site = getPublicSiteConfig({
      LOTTERY_PRIZES_JSON: JSON.stringify([{
        tier: 'first',
        title: 'Choice prize',
        imageUrls: ['/one.png', 'https://example.test/two.png', '/one.png', 'javascript:alert(1)'],
      }]),
    });

    expect(site.prizes[0]).toEqual(expect.objectContaining({
      imageUrl: '/one.png',
      imageUrls: ['/one.png', 'https://example.test/two.png'],
    }));
  });

  it('validates the supported contact formats', () => {
    expect(validateContactValue('123456789', 'qq')).toBe(true);
    expect(validateContactValue('participant@example.test', 'email')).toBe(true);
    expect(validateContactValue('demo-contact', 'text')).toBe(true);
    expect(validateContactValue('bad address', 'email')).toBe(false);
  });
});
