import React, { useMemo, useState } from 'react';
import {
  Alert,
  Box,
  Button,
  Chip,
  MenuItem,
  Stack,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableRow,
  TextField,
  Typography,
} from '@mui/material';
import { useQuery } from '@tanstack/react-query';
import { useNavigate } from 'react-router-dom';
import { supabase } from '@/lib/supabase';
import { useMarketingWorkspace } from '../hooks/useMarketingWorkspace';
import { ContentStatusChip } from '../components/ContentStatusChip';
import { formatYangon } from '../lib/status';
import type { ContentStatus, MarketingContent, SocialPlatform } from '../types';
import { useI18n } from '@/i18n/I18nContext';

export const ContentListPage: React.FC = () => {
  const { t } = useI18n();
  const navigate = useNavigate();
  const { orgId } = useMarketingWorkspace();
  const [platform, setPlatform] = useState<'all' | SocialPlatform>('all');
  const [status, setStatus] = useState<'all' | ContentStatus>('all');

  const { data = [], error, isLoading } = useQuery({
    queryKey: ['marketing_contents', orgId],
    enabled: Boolean(orgId),
    queryFn: async () => {
      const { data: rows, error: qError } = await supabase
        .from('marketing_contents')
        .select('*')
        .eq('organization_id', orgId as string)
        .order('created_at', { ascending: false });
      if (qError) throw qError;
      return (rows || []) as MarketingContent[];
    },
  });

  const filtered = useMemo(
    () =>
      data.filter((row) => (platform === 'all' || row.platform === platform) && (status === 'all' || row.status === status)),
    [data, platform, status]
  );

  return (
    <Box>
      <Stack direction={{ xs: 'column', sm: 'row' }} justifyContent="space-between" spacing={2} sx={{ mb: 2 }}>
        <Typography variant="h6">All generated content</Typography>
        <Button variant="contained" onClick={() => navigate('/admin/marketing/content/new')}>
          Create content
        </Button>
      </Stack>
      <Stack direction={{ xs: 'column', sm: 'row' }} spacing={2} sx={{ mb: 2 }}>
        <TextField select label="Platform" value={platform} onChange={(e) => setPlatform(e.target.value as 'all' | SocialPlatform)} sx={{ minWidth: 160 }}>
          <MenuItem value="all">All</MenuItem>
          <MenuItem value="facebook">Facebook</MenuItem>
          <MenuItem value="tiktok">TikTok</MenuItem>
        </TextField>
        <TextField select label={t("Status")} value={status} onChange={(e) => setStatus(e.target.value as 'all' | ContentStatus)} sx={{ minWidth: 180 }}>
          <MenuItem value="all">All</MenuItem>
          {['draft', 'pending_review', 'approved', 'rejected', 'scheduled', 'published', 'failed', 'archived'].map((s) => (
            <MenuItem key={s} value={s}>{s}</MenuItem>
          ))}
        </TextField>
      </Stack>
      {error && <Alert severity="error">{error instanceof Error ? error.message : 'Failed to load content'}</Alert>}
      {!isLoading && filtered.length === 0 && (
        <Alert severity="info">No content yet. Create a draft or generate ideas with AI.</Alert>
      )}
      {filtered.length > 0 && (
        <Table size="small">
          <TableHead>
            <TableRow>
              <TableCell>Title</TableCell>
              <TableCell>Platform</TableCell>
              <TableCell>{t("Type")}</TableCell>
              <TableCell>{t("Status")}</TableCell>
              <TableCell>Scheduled</TableCell>
            </TableRow>
          </TableHead>
          <TableBody>
            {filtered.map((row) => (
              <TableRow key={row.id} hover sx={{ cursor: 'pointer' }} onClick={() => navigate(`/admin/marketing/content/new?id=${row.id}`)}>
                <TableCell>
                  <Typography variant="body2" fontWeight={600}>{row.title}</Typography>
                  <Chip size="small" label={row.content_pillar} sx={{ mt: 0.5 }} />
                </TableCell>
                <TableCell>{row.platform}</TableCell>
                <TableCell>{row.content_type}</TableCell>
                <TableCell><ContentStatusChip status={row.status} /></TableCell>
                <TableCell>{formatYangon(row.scheduled_for)}</TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      )}
    </Box>
  );
};
