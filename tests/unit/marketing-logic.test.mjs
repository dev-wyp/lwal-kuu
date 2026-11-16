function safeDivide(numerator, denominator) {
  if (!Number.isFinite(numerator) || !Number.isFinite(denominator) || denominator === 0) return null;
  return numerator / denominator;
}

function engagementRate(engagements, reach) {
  const ratio = safeDivide(engagements, reach);
  return ratio === null ? null : ratio * 100;
}

function costPerLead(spend, leads) {
  return safeDivide(spend, leads);
}

function costPerTrial(spend, trials) {
  return safeDivide(spend, trials);
}

function wouldExceedBudget(limit, spent, additional) {
  return spent + additional > limit;
}

function canTransition(from, to, viaRpc) {
  const client = ['draft', 'pending_review', 'rejected', 'archived'];
  if (!viaRpc) {
    if (from === 'publishing' || from === 'published') return false;
    if (to === 'pending_review') return from === 'draft' || from === 'rejected';
    return client.includes(to);
  }
  const map = {
    draft: ['pending_review', 'archived'],
    pending_review: ['approved', 'rejected', 'draft'],
    approved: ['scheduled', 'publishing', 'archived'],
    rejected: ['pending_review', 'draft', 'archived'],
    scheduled: ['publishing', 'scheduled', 'failed'],
    publishing: ['published', 'failed'],
    published: [],
    failed: ['scheduled', 'publishing', 'archived'],
    archived: [],
  };
  return map[from].includes(to);
}

function assertPublishAllowed(status) {
  if (status !== 'approved' && status !== 'scheduled') {
    throw new Error('Unapproved content cannot be published');
  }
}

function duplicatePublishBlocked(statuses) {
  return statuses.some((status) => status === 'processing' || status === 'succeeded');
}

function oauthStateIsValid({ storedNonce, providedNonce, usedAt, expiresAt, now }) {
  if (!storedNonce) return false;
  if (storedNonce !== providedNonce) return false;
  if (usedAt) return false;
  return Date.parse(expiresAt) > Date.parse(now);
}

function tokensAreFrontendAccessible(storage) {
  return storage !== 'server_secret_table';
}

function jobShouldRetry(permanent, attemptCount, maxAttempts) {
  if (permanent) return false;
  return attemptCount < maxAttempts;
}

function attributeLead({ utmSource, contentId }) {
  if (contentId) return 'direct';
  if (utmSource) return 'utm';
  return 'unknown';
}

function assert(condition, message) {
  if (!condition) throw new Error(`Assertion Failed: ${message}`);
  console.log(`[PASS] ${message}`);
}

console.log('--- Running Lwal Kuu Marketing Logic Tests ---');

assert(engagementRate(25, 500) === 5, 'Engagement rate is Engagements / Reach × 100');
assert(engagementRate(10, 0) === null, 'Engagement rate is unavailable when reach is zero');
assert(costPerLead(50000, 10) === 5000, 'Cost per lead divides spend by attributed leads');
assert(costPerLead(50000, 0) === null, 'Cost per lead is unavailable with zero leads');
assert(costPerTrial(40000, 4) === 10000, 'Cost per trial divides spend by trial registrations');
assert(costPerTrial(40000, 0) === null, 'Cost per trial is unavailable with zero trials');

assert(wouldExceedBudget(50000, 40000, 15000) === true, 'Budget limit rejects spend above monthly ceiling');
assert(wouldExceedBudget(50000, 20000, 10000) === false, 'Budget allows spend within monthly ceiling');

assert(canTransition('draft', 'approved', false) === false, 'Client cannot mark content approved');
assert(canTransition('draft', 'pending_review', false) === true, 'Draft can be submitted for review');
assert(canTransition('pending_review', 'approved', true) === true, 'RPC can approve pending review content');
assert(canTransition('published', 'draft', false) === false, 'Published content cannot be mutated from the client');

let publishRejected = false;
try {
  assertPublishAllowed('draft');
} catch {
  publishRejected = true;
}
assert(publishRejected, 'Unapproved publishing is rejected');
assertPublishAllowed('approved');
assertPublishAllowed('scheduled');

assert(duplicatePublishBlocked(['queued']) === false, 'Queued job is not a duplicate success');
assert(duplicatePublishBlocked(['succeeded']) === true, 'Succeeded job blocks duplicate publish');
assert(duplicatePublishBlocked(['processing']) === true, 'In-flight job blocks duplicate publish');

assert(
  oauthStateIsValid({
    storedNonce: 'abc',
    providedNonce: 'abc',
    usedAt: null,
    expiresAt: '2026-11-11T12:00:00Z',
    now: '2026-11-11T11:00:00Z',
  }),
  'Matching unused unexpired OAuth state is valid'
);
assert(
  oauthStateIsValid({
    storedNonce: 'abc',
    providedNonce: 'zzz',
    usedAt: null,
    expiresAt: '2026-11-11T12:00:00Z',
    now: '2026-11-11T11:00:00Z',
  }) === false,
  'Mismatched OAuth state is rejected'
);
assert(
  oauthStateIsValid({
    storedNonce: 'abc',
    providedNonce: 'abc',
    usedAt: '2026-11-11T10:00:00Z',
    expiresAt: '2026-11-11T12:00:00Z',
    now: '2026-11-11T11:00:00Z',
  }) === false,
  'Replayed OAuth state is rejected'
);

assert(tokensAreFrontendAccessible('localStorage') === true, 'localStorage token storage is insecure');
assert(tokensAreFrontendAccessible('server_secret_table') === false, 'Server secret table is the allowed token store');

assert(jobShouldRetry(true, 1, 5) === false, 'Permanent permission failures are not retried');
assert(jobShouldRetry(false, 2, 5) === true, 'Temporary failures retry under max attempts');
assert(jobShouldRetry(false, 5, 5) === false, 'Retries stop at max attempts');

assert(attributeLead({ utmSource: 'facebook', contentId: 'c1' }) === 'direct', 'Content ID is direct attribution');
assert(attributeLead({ utmSource: 'tiktok', contentId: null }) === 'utm', 'UTM source is utm attribution');
assert(attributeLead({ utmSource: null, contentId: null }) === 'unknown', 'Missing params stay unknown');

function buildTrialTrackingUrl(origin, content) {
  const url = new URL('/register', origin);
  url.searchParams.set('utm_source', content.platform);
  url.searchParams.set('utm_medium', 'social');
  url.searchParams.set('utm_campaign', content.campaign_id || 'lwal-kuu-trial');
  url.searchParams.set('utm_content', content.id);
  url.searchParams.set('plan', 'starter');
  return url.toString();
}

const tracking = buildTrialTrackingUrl('https://app.shopflow.example', {
  id: 'content-1',
  platform: 'facebook',
  campaign_id: null,
});
assert(tracking.includes('utm_source=facebook'), 'Tracking link sets utm_source from platform');
assert(tracking.includes('utm_content=content-1'), 'Tracking link attributes the content id');
assert(tracking.includes('/register'), 'Tracking link lands on trial registration');

console.log('--- Marketing tests passed ---');
