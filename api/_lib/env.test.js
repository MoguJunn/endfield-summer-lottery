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

  it('requires only the user data gateway because operations stay on the main site', () => {
    const config = getRuntimeConfig({
      LOTTERY_PROVIDER: 'main-site',
      LOTTERY_SITE_URL: 'https://lottery.example.test',
      MAIN_SITE_URL: 'https://main.example.test',
      LOTTERY_SESSION_SECRET: 's'.repeat(43),
      LOTTERY_BACKEND_SECRET: 'u'.repeat(43),
    });
    expect(getMissingRuntimeKeys(config)).toEqual([]);
    expect(config).not.toHaveProperty('adminBackendSecret');
    expect(config).not.toHaveProperty('drawSecret');
    expect(config).not.toHaveProperty('drawSeed');
  });
});
