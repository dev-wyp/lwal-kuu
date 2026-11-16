import type { ContentStatus } from '../types';

const CLIENT_EDITABLE: ContentStatus[] = ['draft', 'rejected'];

export function canEditCopy(status: ContentStatus): boolean {
  return CLIENT_EDITABLE.includes(status);
}

export function canSubmitForReview(status: ContentStatus): boolean {
  return status === 'draft' || status === 'rejected';
}

export function canApprove(status: ContentStatus): boolean {
  return status === 'pending_review';
}

export function canSchedule(status: ContentStatus): boolean {
  return status === 'approved' || status === 'scheduled';
}

export function canEnqueuePublish(status: ContentStatus): boolean {
  return status === 'approved' || status === 'scheduled';
}

export function statusLabel(status: ContentStatus): string {
  const labels: Record<ContentStatus, string> = {
    draft: 'Draft',
    pending_review: 'Pending review',
    approved: 'Approved',
    rejected: 'Rejected',
    scheduled: 'Scheduled',
    publishing: 'Publishing',
    published: 'Published',
    failed: 'Failed',
    archived: 'Archived',
  };
  return labels[status];
}

export function statusColor(
  status: ContentStatus
): 'default' | 'warning' | 'success' | 'error' | 'info' | 'secondary' {
  switch (status) {
    case 'approved':
    case 'published':
      return 'success';
    case 'pending_review':
    case 'scheduled':
    case 'publishing':
      return 'warning';
    case 'rejected':
    case 'failed':
      return 'error';
    case 'archived':
      return 'secondary';
    default:
      return 'default';
  }
}

export const YANGON_TIMEZONE = 'Asia/Yangon';

export function formatYangon(iso: string | null): string {
  if (!iso) return '—';
  return new Intl.DateTimeFormat('en-GB', {
    timeZone: YANGON_TIMEZONE,
    dateStyle: 'medium',
    timeStyle: 'short',
  }).format(new Date(iso));
}
