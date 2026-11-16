import React, { useState } from 'react';
import {
  Alert,
  Box,
  Button,
  Dialog,
  DialogActions,
  DialogContent,
  DialogTitle,
  Paper,
  Stack,
  TextField,
  Typography,
} from '@mui/material';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/lib/supabase';
import { useNotification } from '@/context/NotificationContext';
import { useMarketingWorkspace } from '../hooks/useMarketingWorkspace';
import { ContentStatusChip } from '../components/ContentStatusChip';
import { mktRpc } from '../lib/db';
import { formatYangon } from '../lib/status';
import { buildManualPublishBrief, buildTrialTrackingUrl, downloadTextFile } from '../lib/exportBrief';
import type { ContentApproval, MarketingContent } from '../types';
import { useI18n } from '@/i18n/I18nContext';

export const ApprovalsPage: React.FC = () => {
  const { t } = useI18n();
  const { orgId, canApproveMarketing } = useMarketingWorkspace();
  const { showError, showSuccess } = useNotification();
  const queryClient = useQueryClient();
  const [rejectId, setRejectId] = useState<string | null>(null);
  const [reason, setReason] = useState('');
  const [preview, setPreview] = useState<MarketingContent | null>(null);
  const [scheduleId, setScheduleId] = useState<string | null>(null);
  const [scheduleAt, setScheduleAt] = useState('');
  const [editItem, setEditItem] = useState<MarketingContent | null>(null);
  const [editCaption, setEditCaption] = useState('');
  const [editHashtags, setEditHashtags] = useState('');

  const { data = [], error } = useQuery({
    queryKey: ['marketing_approvals', orgId],
    enabled: Boolean(orgId),
    queryFn: async () => {
      const { data: rows, error: qError } = await supabase
        .from('marketing_contents')
        .select('*')
        .eq('organization_id', orgId as string)
        .in('status', ['pending_review', 'approved', 'rejected', 'failed'])
        .order('updated_at', { ascending: false });
      if (qError) throw qError;
      return (rows || []) as MarketingContent[];
    },
  });

  const { data: history = [] } = useQuery({
    queryKey: ['content_approvals_history', preview?.id],
    enabled: Boolean(preview?.id),
    queryFn: async () => {
      const { data: rows, error: qError } = await supabase
        .from('content_approvals')
        .select('*')
        .eq('content_id', preview?.id as string)
        .order('created_at', { ascending: false });
      if (qError) throw qError;
      return (rows || []) as ContentApproval[];
    },
  });

  const refresh = () => queryClient.invalidateQueries({ queryKey: ['marketing_approvals'] });

  const approve = async (id: string) => {
    try {
      await mktRpc('approve_marketing_content', { p_content_id: id });
      showSuccess('Approved. Scheduling is now allowed.');
      await refresh();
    } catch (err) {
      showError(err instanceof Error ? err.message : 'Approval failed');
    }
  };

  const reject = async () => {
    if (!rejectId) return;
    try {
      await mktRpc('reject_marketing_content', { p_content_id: rejectId, p_reason: reason });
      showSuccess('Rejected with reason recorded');
      setRejectId(null);
      setReason('');
      await refresh();
    } catch (err) {
      showError(err instanceof Error ? err.message : 'Reject failed');
    }
  };

  const schedule = async () => {
    if (!scheduleId || !scheduleAt) return;
    try {
      const iso = new Date(scheduleAt).toISOString();
      await mktRpc('schedule_marketing_content', { p_content_id: scheduleId, p_scheduled_for: iso });
      showSuccess('Scheduled in Asia/Yangon');
      setScheduleId(null);
      await refresh();
    } catch (err) {
      showError(err instanceof Error ? err.message : 'Schedule failed');
    }
  };

  const exportBrief = (item: MarketingContent) => {
    const trackingUrl = buildTrialTrackingUrl(window.location.origin, item);
    downloadTextFile(
      `${item.platform}-${item.id.slice(0, 8)}-publish-brief.txt`,
      buildManualPublishBrief(item, trackingUrl)
    );
    showSuccess('Export downloaded. Post manually only if this content is approved.');
  };

  const saveEdits = async () => {
    if (!editItem) return;
    try {
      await mktRpc('edit_marketing_review_content', {
        p_content_id: editItem.id,
        p_caption: editCaption,
        p_hashtags: editHashtags.split(/[\s,]+/).filter(Boolean),
      });
      showSuccess('Caption updated and recorded in approval history. Re-preview before approving.');
      setEditItem(null);
      await refresh();
    } catch (err) {
      showError(err instanceof Error ? err.message : 'Unable to edit this content');
    }
  };

  const enqueue = async (id: string) => {
    try {
      await mktRpc('enqueue_marketing_publish', { p_content_id: id });
      showSuccess('Publish job queued. The backend will refuse unapproved content.');
      await refresh();
    } catch (err) {
      showError(err instanceof Error ? err.message : 'Publish enqueue failed');
    }
  };

  const pending = data.filter((row) => row.status === 'pending_review');

  return (
    <Box>
      {!canApproveMarketing && (
        <Alert severity="warning" sx={{ mb: 2 }}>
          Platform superadmins review and approve all content before publishing.
        </Alert>
      )}
      {error && <Alert severity="error">{error instanceof Error ? error.message : 'Failed to load approvals'}</Alert>}
      {pending.length === 0 && <Alert severity="info">No content is waiting for review.</Alert>}

      <Stack spacing={2} sx={{ mt: 2 }}>
        {data.map((item) => (
          <Paper key={item.id} sx={{ p: 2 }}>
            <Stack direction={{ xs: 'column', md: 'row' }} justifyContent="space-between" spacing={2}>
              <Box>
                <Typography fontWeight={700}>{item.title}</Typography>
                <Typography variant="body2" color="text.secondary">
                  {item.platform} · {item.content_type} · {item.content_pillar}
                </Typography>
                <Typography variant="body2" sx={{ mt: 1, whiteSpace: 'pre-wrap' }}>{item.caption}</Typography>
                <Typography variant="caption" display="block" sx={{ mt: 1 }}>
                  CTA: {item.cta || '—'} · {(item.hashtags || []).join(' ')}
                </Typography>
                {item.rejection_reason && (
                  <Alert severity="error" sx={{ mt: 1 }}>{item.rejection_reason}</Alert>
                )}
              </Box>
              <Stack spacing={1} alignItems={{ md: 'flex-end' }}>
                <ContentStatusChip status={item.status} />
                <Button size="small" onClick={() => setPreview(item)}>Preview</Button>
                {item.status === 'pending_review' && (
                  <Button
                    size="small"
                    disabled={!canApproveMarketing}
                    onClick={() => {
                      setEditItem(item);
                      setEditCaption(item.caption);
                      setEditHashtags((item.hashtags || []).join(' '));
                    }}
                  >
                    Edit copy
                  </Button>
                )}
                {['approved', 'scheduled', 'failed'].includes(item.status) && (
                  <Button size="small" onClick={() => exportBrief(item)}>Export for manual post</Button>
                )}
                {item.status === 'pending_review' && (
                  <>
                    <Button size="small" variant="contained" disabled={!canApproveMarketing} onClick={() => approve(item.id)}>
                      Approve
                    </Button>
                    <Button size="small" color="error" disabled={!canApproveMarketing} onClick={() => setRejectId(item.id)}>
                      Reject
                    </Button>
                  </>
                )}
                {['approved', 'failed'].includes(item.status) && (
                  <>
                    {item.status === 'approved' && (
                      <Button size="small" disabled={!canApproveMarketing} onClick={() => setScheduleId(item.id)}>
                        Schedule
                      </Button>
                    )}
                    <Button size="small" variant="outlined" disabled={!canApproveMarketing} onClick={() => enqueue(item.id)}>
                      {item.status === 'failed' ? 'Retry publish' : 'Queue publish'}
                    </Button>
                  </>
                )}
              </Stack>
            </Stack>
          </Paper>
        ))}
      </Stack>

      <Dialog open={Boolean(preview)} onClose={() => setPreview(null)} maxWidth="md" fullWidth>
        <DialogTitle>Publish preview</DialogTitle>
        <DialogContent>
          {preview && (
            <Stack spacing={1} sx={{ mt: 1 }}>
              <Typography variant="h6">{preview.title}</Typography>
              <Typography variant="body2">{preview.hook}</Typography>
              <Typography sx={{ whiteSpace: 'pre-wrap' }}>{preview.caption}</Typography>
              <Typography variant="caption">{(preview.hashtags || []).join(' ')}</Typography>
              <Typography variant="body2">Image prompt: {preview.image_prompt || 'None'}</Typography>
              {preview.production_brief && <Typography variant="body2">{preview.production_brief}</Typography>}
              <Typography variant="subtitle2" sx={{ mt: 2 }}>Approval history</Typography>
              {history.map((entry) => (
                <Typography key={entry.id} variant="caption" display="block">
                  {entry.action} · {formatYangon(entry.created_at)} · {entry.reason || ''}
                </Typography>
              ))}
            </Stack>
          )}
        </DialogContent>
        <DialogActions>
          {preview && <Button onClick={() => exportBrief(preview)}>Download brief</Button>}
          <Button onClick={() => setPreview(null)}>{t("Close")}</Button>
        </DialogActions>
      </Dialog>

      <Dialog open={Boolean(editItem)} onClose={() => setEditItem(null)} fullWidth maxWidth="sm">
        <DialogTitle>Edit caption and hashtags</DialogTitle>
        <DialogContent>
          <TextField
            fullWidth
            multiline
            minRows={5}
            label="Caption"
            value={editCaption}
            onChange={(e) => setEditCaption(e.target.value)}
            sx={{ mt: 1 }}
          />
          <TextField
            fullWidth
            label="Hashtags"
            value={editHashtags}
            onChange={(e) => setEditHashtags(e.target.value)}
            sx={{ mt: 2 }}
          />
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setEditItem(null)}>{t("Cancel")}</Button>
          <Button variant="contained" onClick={() => void saveEdits()}>{t("Save")}</Button>
        </DialogActions>
      </Dialog>

      <Dialog open={Boolean(rejectId)} onClose={() => setRejectId(null)}>
        <DialogTitle>Rejection reason</DialogTitle>
        <DialogContent>
          <TextField fullWidth multiline minRows={3} value={reason} onChange={(e) => setReason(e.target.value)} sx={{ mt: 1 }} />
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setRejectId(null)}>{t("Cancel")}</Button>
          <Button color="error" onClick={() => void reject()}>Reject</Button>
        </DialogActions>
      </Dialog>

      <Dialog open={Boolean(scheduleId)} onClose={() => setScheduleId(null)}>
        <DialogTitle>Schedule (Asia/Yangon)</DialogTitle>
        <DialogContent>
          <TextField
            type="datetime-local"
            fullWidth
            InputLabelProps={{ shrink: true }}
            value={scheduleAt}
            onChange={(e) => setScheduleAt(e.target.value)}
            sx={{ mt: 1 }}
          />
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setScheduleId(null)}>{t("Cancel")}</Button>
          <Button variant="contained" onClick={() => void schedule()}>Schedule</Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
};
