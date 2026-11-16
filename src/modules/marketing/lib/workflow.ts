import type { ContentStatus } from '../types';
import { wouldExceedBudget } from './metrics';

export const ALLOWED_CLIENT_STATUSES: ContentStatus[] = ['draft', 'pending_review', 'rejected', 'archived'];

export function canTransition(
  from: ContentStatus,
  to: ContentStatus,
  viaRpc: boolean
): boolean {
  if (!viaRpc) {
    if (from === 'publishing' || from === 'published') return false;
    if (to === 'pending_review') return from === 'draft' || from === 'rejected';
    return ALLOWED_CLIENT_STATUSES.includes(to);
  }
  const map: Record<ContentStatus, ContentStatus[]> = {
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

export function assertPublishAllowed(status: ContentStatus): void {
  if (status !== 'approved' && status !== 'scheduled') {
    throw new Error('Unapproved content cannot be published');
  }
}

export function duplicatePublishBlocked(existingJobStatuses: string[]): boolean {
  return existingJobStatuses.some((status) => status === 'processing' || status === 'succeeded');
}

export function oauthStateIsValid(input: {
  storedNonce: string | null;
  providedNonce: string;
  usedAt: string | null;
  expiresAt: string;
  now: string;
}): boolean {
  if (!input.storedNonce) return false;
  if (input.storedNonce !== input.providedNonce) return false;
  if (input.usedAt) return false;
  return Date.parse(input.expiresAt) > Date.parse(input.now);
}

export function tokensAreFrontendAccessible(storage: 'server_secret_table' | 'localStorage' | 'public_table'): boolean {
  return storage !== 'server_secret_table';
}

export function budgetApprovalAllowed(limit: number, spent: number, additional: number): boolean {
  return additional > 0 && !wouldExceedBudget(limit, spent, additional);
}

export function jobShouldRetry(permanent: boolean, attemptCount: number, maxAttempts: number): boolean {
  if (permanent) return false;
  return attemptCount < maxAttempts;
}

export function engagementSafe(engagements: number, reach: number): number | null {
  if (reach === 0) return null;
  return (engagements / reach) * 100;
}

export function attributeLead(params: {
  utmSource: string | null;
  contentId: string | null;
}): 'utm' | 'direct' | 'unknown' {
  if (params.contentId) return 'direct';
  if (params.utmSource) return 'utm';
  return 'unknown';
}
