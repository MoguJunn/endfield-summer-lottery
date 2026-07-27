export function maskDisplayName(value) {
  const characters = Array.from(String(value || '').trim());
  if (!characters.length) return '匿名参与者';
  if (characters.length <= 2) return `${characters[0]}*`;
  return `${characters[0]}${'*'.repeat(Math.min(4, characters.length - 2))}${characters.at(-1)}`;
}

export function getCampaignPhase(campaign, now = new Date()) {
  if (!campaign) return 'unavailable';
  if (campaign.status === 'cancelled') return 'cancelled';
  if (campaign.status === 'closed') return 'closed';
  if (campaign.drawn_at || campaign.status === 'drawn') return 'drawn';
  const currentTime = now.getTime();
  if (currentTime < new Date(campaign.starts_at).getTime()) return 'scheduled';
  if (!campaign.seed_commitment) return 'preparing';
  if (currentTime < new Date(campaign.closes_at).getTime()) return 'open';
  if (currentTime < new Date(campaign.draws_at).getTime()) return 'waiting_draw';
  return 'ready_to_draw';
}
