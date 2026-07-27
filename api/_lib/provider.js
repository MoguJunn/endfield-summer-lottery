import { callLotteryBackend, createLotteryPowChallenge } from './backend.js';
import { callDemoProvider, createDemoPowChallenge } from './demoProvider.js';
import { getRuntimeConfig } from './env.js';

export async function callLotteryProvider(action, payload = {}, env = process.env) {
  const config = getRuntimeConfig(env);
  return config.isDemo
    ? callDemoProvider(action, payload, env)
    : callLotteryBackend(action, payload, env);
}

export async function createProviderPowChallenge(env = process.env) {
  const config = getRuntimeConfig(env);
  return config.isDemo ? createDemoPowChallenge() : createLotteryPowChallenge(env);
}
