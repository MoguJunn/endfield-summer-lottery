import { verifyPublicDraw } from '../src/utils/drawVerification.js';

const response = await fetch('http://localhost:5175/api/lottery');
const body = await response.json().catch(() => null);
if (!response.ok || body?.success !== true || body?.data?.campaign?.phase !== 'drawn') {
  throw new Error(`drawn snapshot unavailable (${response.status}): ${JSON.stringify(body)}`);
}
const verification = await verifyPublicDraw(body.data);
if (!verification.valid) {
  throw new Error(`public draw verification failed: ${JSON.stringify(verification.checks)}`);
}
console.log(JSON.stringify({
  success: true,
  phase: body.data.campaign.phase,
  entryCount: body.data.entryCount,
  winnerCount: body.data.publicWinners.length,
  publicRandomnessRound: body.data.campaign.publicRandomnessRound,
  checks: verification.checks,
}, null, 2));
