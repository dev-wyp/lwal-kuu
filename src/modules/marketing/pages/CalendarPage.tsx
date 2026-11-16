import React, { useMemo, useState } from 'react';
import {
  Alert,
  Box,
  Card,
  CardContent,
  Chip,
  MenuItem,
  Stack,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableRow,
  TextField,
  ToggleButton,
  ToggleButtonGroup,
  Typography,
} from '@mui/material';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/lib/supabase';
import { useNotification } from '@/context/NotificationContext';
import { useMarketingWorkspace } from '../hooks/useMarketingWorkspace';
import { ContentStatusChip } from '../components/ContentStatusChip';
import { canSchedule, formatYangon } from '../lib/status';
import { mktRpc } from '../lib/db';
import type { ContentStatus, MarketingContent, SocialPlatform } from '../types';
import { useI18n } from '@/i18n/I18nContext';

type ViewMode = 'month' | 'week' | 'day' | 'list';

export const CalendarPage: React.FC = () => {
  const { t } = useI18n();
  const { orgId, canApproveMarketing } = useMarketingWorkspace();
  const { showError, showSuccess } = useNotification();
  const queryClient = useQueryClient();
  const [view, setView] = useState<ViewMode>('month');
  const [platform, setPlatform] = useState<'all' | SocialPlatform>('all');
  const [status, setStatus] = useState<'all' | ContentStatus>('all');
  const [anchor, setAnchor] = useState(() => new Date(`${todayYangonDate()}T12:00:00.000Z`));

  const { data = [], error } = useQuery({
    queryKey: ['marketing_calendar', orgId],
    enabled: Boolean(orgId),
    queryFn: async () => {
      const { data: rows, error: qError } = await supabase
        .from('marketing_contents')
        .select('*')
        .eq('organization_id', orgId as string)
        .order('scheduled_for', { ascending: true });
      if (qError) throw qError;
      return (rows || []) as MarketingContent[];
    },
  });

  const filtered = useMemo(
    () =>
      data.filter((row) => {
        if (platform !== 'all' && row.platform !== platform) return false;
        if (status !== 'all' && row.status !== status) return false;
        return Boolean(row.scheduled_for) || ['approved', 'scheduled', 'published'].includes(row.status);
      }),
    [data, platform, status]
  );

  const days = useMemo(() => buildDays(anchor, view), [anchor, view]);

  const onDrop = async (contentId: string, day: string) => {
    const item = data.find((row) => row.id === contentId);
    if (!item) return;
    if (!canApproveMarketing) {
      showError('Only platform superadmins can reschedule');
      return;
    }
    if (!canSchedule(item.status)) {
      showError('Unapproved content cannot be scheduled');
      return;
    }
    const next = `${day}T09:00:00+06:30`;
    try {
      await mktRpc('schedule_marketing_content', { p_content_id: contentId, p_scheduled_for: next });
      showSuccess('Rescheduled in Asia/Yangon time');
      await queryClient.invalidateQueries({ queryKey: ['marketing_calendar'] });
    } catch (err) {
      showError(err instanceof Error ? err.message : 'Reschedule failed');
    }
  };

  return (
    <Box>
      <Stack direction={{ xs: 'column', md: 'row' }} spacing={2} sx={{ mb: 2 }}>
        <ToggleButtonGroup exclusive value={view} onChange={(_e, value: ViewMode | null) => value && setView(value)}>
          <ToggleButton value="month">Month</ToggleButton>
          <ToggleButton value="week">Week</ToggleButton>
          <ToggleButton value="day">Day</ToggleButton>
          <ToggleButton value="list">List</ToggleButton>
        </ToggleButtonGroup>
        <TextField select label="Platform" value={platform} onChange={(e) => setPlatform(e.target.value as 'all' | SocialPlatform)} sx={{ minWidth: 140 }}>
          <MenuItem value="all">All</MenuItem>
          <MenuItem value="facebook">Facebook</MenuItem>
          <MenuItem value="tiktok">TikTok</MenuItem>
        </TextField>
        <TextField select label={t("Status")} value={status} onChange={(e) => setStatus(e.target.value as 'all' | ContentStatus)} sx={{ minWidth: 160 }}>
          <MenuItem value="all">All</MenuItem>
          {['approved', 'scheduled', 'published', 'failed'].map((s) => (
            <MenuItem key={s} value={s}>{s}</MenuItem>
          ))}
        </TextField>
        <TextField
          type="date"
          label="Focus date"
          InputLabelProps={{ shrink: true }}
          value={isoDate(anchor)}
          onChange={(e) => {
            if (e.target.value) setAnchor(new Date(`${e.target.value}T12:00:00.000Z`));
          }}
        />
      </Stack>

      {error && <Alert severity="error">{error instanceof Error ? error.message : 'Calendar failed to load'}</Alert>}
      <Alert severity="info" sx={{ mb: 2 }}>
        Times are Asia/Yangon. Drag approved items onto a day to reschedule. Unapproved drafts cannot be scheduled.
      </Alert>

      {view === 'list' ? (
        <Table size="small">
          <TableHead>
            <TableRow>
              <TableCell>Title</TableCell>
              <TableCell>Platform</TableCell>
              <TableCell>{t("Status")}</TableCell>
              <TableCell>Scheduled</TableCell>
              <TableCell>Result</TableCell>
            </TableRow>
          </TableHead>
          <TableBody>
            {filtered.map((row) => (
              <TableRow key={row.id}>
                <TableCell>{row.title}</TableCell>
                <TableCell>{row.platform}</TableCell>
                <TableCell><ContentStatusChip status={row.status} /></TableCell>
                <TableCell>{formatYangon(row.scheduled_for)}</TableCell>
                <TableCell>{row.last_publish_error || row.provider_post_id || '—'}</TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      ) : (
        <Box
          sx={{
            display: 'grid',
            gridTemplateColumns: { xs: '1fr', sm: view === 'day' ? '1fr' : 'repeat(7, 1fr)' },
            gap: 1,
          }}
        >
          {days.map((day) => {
            const items = filtered.filter((row) => row.scheduled_for && yangonDate(row.scheduled_for) === day);
            return (
              <Card
                key={day}
                sx={{ minHeight: 140 }}
                onDragOver={(e) => e.preventDefault()}
                onDrop={(e) => {
                  e.preventDefault();
                  const id = e.dataTransfer.getData('text/plain');
                  if (id) void onDrop(id, day);
                }}
              >
                <CardContent>
                  <Typography variant="caption" fontWeight={700}>{day}</Typography>
                  {items.map((item) => (
                    <Box
                      key={item.id}
                      draggable={canSchedule(item.status)}
                      onDragStart={(e) => e.dataTransfer.setData('text/plain', item.id)}
                      sx={{ mt: 1, p: 1, bgcolor: '#f8fafc', borderRadius: 1, cursor: canSchedule(item.status) ? 'grab' : 'default' }}
                    >
                      <Typography variant="caption" display="block">{item.title}</Typography>
                      <Stack direction="row" spacing={0.5}>
                        <Chip size="small" label={item.platform} />
                        <ContentStatusChip status={item.status} />
                      </Stack>
                    </Box>
                  ))}
                </CardContent>
              </Card>
            );
          })}
        </Box>
      )}
    </Box>
  );
};

function buildDays(anchor: Date, view: ViewMode): string[] {
  const start = new Date(anchor);
  if (view === 'day') return [isoDate(start)];
  if (view === 'week' || view === 'list') {
    const day = start.getUTCDay();
    start.setUTCDate(start.getUTCDate() - ((day + 6) % 7));
    return Array.from({ length: 7 }, (_, i) => {
      const d = new Date(start);
      d.setUTCDate(start.getUTCDate() + i);
      return isoDate(d);
    });
  }
  const monthStart = new Date(Date.UTC(start.getUTCFullYear(), start.getUTCMonth(), 1));
  const monthEnd = new Date(Date.UTC(start.getUTCFullYear(), start.getUTCMonth() + 1, 0));
  const days: string[] = [];
  for (let d = new Date(monthStart); d <= monthEnd; d.setUTCDate(d.getUTCDate() + 1)) {
    days.push(isoDate(d));
  }
  return days;
}

function isoDate(d: Date): string {
  const year = d.getUTCFullYear();
  const month = String(d.getUTCMonth() + 1).padStart(2, '0');
  const day = String(d.getUTCDate()).padStart(2, '0');
  return `${year}-${month}-${day}`;
}

function todayYangonDate(): string {
  return yangonDate(new Date().toISOString());
}

function yangonDate(iso: string): string {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone: 'Asia/Yangon', year: 'numeric', month: '2-digit', day: '2-digit',
  }).formatToParts(new Date(iso));
  const values = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  return `${values.year}-${values.month}-${values.day}`;
}
