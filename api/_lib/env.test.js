// @vitest-environment node

import { describe, expect, it } from 'vitest';
import { getMissingRuntimeKeys, getRuntimeConfig } from './env.js';

describe('runtime provider configuration', () => {
  it('allows demo without external secrets only in development', () => {
    const development = getRuntimeConfig({
      LOTTERY_PROVIDER: 'demo',
      LOTTERY_SITE_URL: 'http://localhost:5175',
      NODE_ENV: 'development',
    });
    expect(getMissingRuntimeKeys(development)).toEqual([]);

    const production = getRuntimeConfig({
      LOTTERY_PROVIDER: 'demo',
      LOTTERY_SITE_URL: 'https://lottery.example.test',
      NODE_ENV: 'production',
    });
    expect(getMissingRuntimeKeys(production)).toContain('LOTTERY_PROVIDER_DEMO_DISABLED_IN_PRODUCTION');
  });

  it('requires separate user and admin gateway secrets for main-site operations', () => {
    const config = getRuntimeConfig({
      LOTTERY_PROVIDER: 'main-site',
      LOTTERY_SITE_URL: 'https://lottery.example.test',
      MAIN_SITE_URL: 'https://main.example.test',
      LOTTERY_SESSION_SECRET: 's'.repeat(43),
      LOTTERY_BACKEND_SECRET: 'u'.repeat(43),
      LOTTERY_DRAW_SECRET: 'd'.repeat(43),
      LOTTERY_DRAW_SEED: 'r'.repeat(43),
    });
    expect(getMissingRuntimeKeys(config)).toEqual([]);
    expect(getMissingRuntimeKeys(config, { includeDraw: true })).toContain('LOTTERY_ADMIN_BACKEND_SECRET');
  });
});
