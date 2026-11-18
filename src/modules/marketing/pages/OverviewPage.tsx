import React from 'react';
import {
  Alert,
  Box,
  Button,
  Card,
  CardContent,
  Grid,
  LinearProgress,
  Stack,
  Table,
  TableContainer,
  TableBody,
  TableCell,
  TableHead,
  TableRow,
  Typography,
} from '@mui/material';
import { useQuery } from '@tanstack/react-query';
import { useNavigate } from 'react-router-dom';
import { supabase } from '@/lib/supabase';
import { useOrg } from '@/context/OrgContext';
import { useMarketingWorkspace } from '../hooks/useMarketingWorkspace';
import { KpiCard } from '../components/KpiCard';
import { ContentStatusChip } from '../components/ContentStatusChip';
import {
  budgetUtilization,
  combineMetricSource,
  costPerLead,
  costPerTrial,
  engagementRate,
  formatMetricNumber,
  formatPercent,
  remainingBudget,
  type MetricSource,
} from '../lib/metrics';
import { formatYangon } from '../lib/status';
import type { MarketingContent, MarketingLead, SocialAnalyticsRow } from '../types';
import { mktRpc } from '../lib/db';

export const OverviewPage: React.FC = () => {
  const navigate = useNavigate();
  const { formatCurrency } = useOrg();
  const { orgId, data: workspaceData } = useMarketingWorkspace();
  const workspace = workspaceData?.workspace;
  const accounts = workspaceData?.accounts ?? [];

  const { data, isLoading, error } = useQuery({
    queryKey: ['marketing_overview', orgId],
    enabled: Boolean(orgId && workspace),
    queryFn: async () => {
      if (!orgId || !workspace) return null;

      const [contentsRes, leadsRes, analyticsRes, spend] = await Promise.all([
        supabase
          .from('marketing_contents')
          .select('*')
          .eq('organization_id', orgId)
          .order('created_at', { ascending: false })
          .limit(200),
        supabase.from('marketing_leads').select('*').eq('organization_id', orgId),
        supabase.from('social_analytics').select('*').eq('organization_id', orgId),
        mktRpc<number>('month_ad_spend', { p_workspace_id: workspace.id }),
      ]);

      if (contentsRes.error) throw contentsRes.error;
      if (leadsRes.error) throw leadsRes.error;
      if (analyticsRes.error) throw analyticsRes.error;

      return {
        contents: (contentsRes.data || []) as MarketingContent[],
        leads: (leadsRes.data || []) as MarketingLead[],
        analytics: (analyticsRes.data || []) as SocialAnalyticsRow[],
        spend: Number(spend || 0),
      };
    },
  });

  if (error) {
    return <Alert severity="error">{error instanceof Error ? error.message : 'Failed to load dashboard'}</Alert>;
  }

  const contents = data?.contents ?? [];
  const leads = data?.leads ?? [];
  const analytics = data?.analytics ?? [];
  const spend = data?.spend ?? 0;

  const published = contents.filter((c) => c.status === 'published');
  const pending = contents.filter((c) => c.status === 'pending_review');
  const upcoming = contents
    .filter((c) => c.status === 'scheduled')
    .sort((a, b) => (a.scheduled_for || '').localeCompare(b.scheduled_for || ''));

  const sumMetric = (key: keyof SocialAnalyticsRow): number | null => {
    const values = analytics
      .map((row) => row[key])
      .filter((value): value is number => typeof value === 'number' && Number.isFinite(value));
    return values.length ? values.reduce((total, value) => total + value, 0) : null;
  };
  const analyticsSource: MetricSource = combineMetricSource(
    analytics.length ? analytics.map((row) => row.metric_source) : ['unavailable']
  );

  const reach = analytics.length ? sumMetric('reach') : null;
  const impressions = analytics.length ? sumMetric('impressions') : null;
  const videoViews = analytics.length ? sumMetric('video_views') : null;
  const engagements = analytics.length ? sumMetric('engagements') : null;
  const er = reach !== null && engagements !== null ? engagementRate(engagements, reach) : null;

  const trialLeads = leads.filter((l) => l.status === 'trial_registered' || l.status === 'converted');
  const converted = leads.filter((l) => l.status === 'converted');
  const cpl = costPerLead(spend, leads.length);
  const cpt = costPerTrial(spend, trialLeads.length);
  const budgetLimit = Number(workspace?.monthly_ad_budget_mmk || 50000);
  const utilization = budgetUtilization(spend, budgetLimit);
  const remaining = remainingBudget(budgetLimit, spend);

  const disconnected = accounts.filter((a) => a.connection_status !== 'connected');
  const fbRows = analytics.filter((a) => a.platform === 'facebook');
  const ttRows = analytics.filter((a) => a.platform === 'tiktok');

  const weekBuckets = lastSevenDays().map((day) => ({
    day,
    posts: published.filter((c) => c.published_at && yangonDate(c.published_at) === day).length,
  }));
  const maxPosts = Math.max(1, ...weekBuckets.map((b) => b.posts));

  return (
    <Box>
      {disconnected.length > 0 && (
        <Alert
          severity="warning"
          sx={{ mb: 2 }}
          action={
            <Button color="inherit" size="small" onClick={() => navigate('/admin/marketing/social-accounts')}>
              Connect
            </Button>
          }
        >
          {disconnected.map((a) => a.provider).join(' and ')} {disconnected.length === 1 ? 'is' : 'are'} not
          connected. Publishing and live analytics stay unavailable until OAuth is completed.
        </Alert>
      )}

      {isLoading && <LinearProgress sx={{ mb: 2 }} />}

      <Grid container spacing={2}>
        <Grid item xs={6} md={3} lg={2}>
          <KpiCard title="Published posts" value={String(published.length)} source="platform" helper="From Lwal Kuu records" />
        </Grid>
        <Grid item xs={6} md={3} lg={2}>
          <KpiCard title="Pending approvals" value={String(pending.length)} source="platform" />
        </Grid>
        <Grid item xs={6} md={3} lg={2}>
          <KpiCard title="Reach" value={formatMetricNumber(reach)} source={analyticsSource} />
        </Grid>
        <Grid item xs={6} md={3} lg={2}>
          <KpiCard title="Impressions" value={formatMetricNumber(impressions)} source={analyticsSource} />
        </Grid>
        <Grid item xs={6} md={3} lg={2}>
          <KpiCard title="Video views" value={formatMetricNumber(videoViews)} source={analyticsSource} />
        </Grid>
        <Grid item xs={6} md={3} lg={2}>
          <KpiCard title="Engagement rate" value={formatPercent(er)} source={analyticsSource} helper="Engagements / Reach" />
        </Grid>
        <Grid item xs={6} md={3} lg={2}>
          <KpiCard title="Leads" value={String(leads.length)} source="platform" />
        </Grid>
        <Grid item xs={6} md={3} lg={2}>
          <KpiCard title="Trial registrations" value={String(trialLeads.length)} source="platform" />
        </Grid>
        <Grid item xs={6} md={3} lg={2}>
          <KpiCard title="Paid conversions" value={String(converted.length)} source="platform" />
        </Grid>
        <Grid item xs={6} md={3} lg={2}>
          <KpiCard title="Ad spend" value={formatCurrency(spend)} source="platform" helper="Recorded actuals only" />
        </Grid>
        <Grid item xs={6} md={3} lg={2}>
          <KpiCard title="Cost per lead" value={cpl === null ? 'Unavailable' : formatCurrency(cpl)} source={spend && leads.length ? 'platform' : 'unavailable'} />
        </Grid>
        <Grid item xs={6} md={3} lg={2}>
          <KpiCard title="Cost per trial" value={cpt === null ? 'Unavailable' : formatCurrency(cpt)} source={spend && trialLeads.length ? 'platform' : 'unavailable'} />
        </Grid>
      </Grid>

      <Grid container spacing={2} sx={{ mt: 1 }}>
        <Grid item xs={12} md={7}>
          <Card>
            <CardContent>
              <Typography variant="h6" sx={{ mb: 2 }}>Weekly published posts</Typography>
              <Stack direction="row" spacing={1} alignItems="flex-end" sx={{ height: 140 }}>
                {weekBuckets.map((bucket) => (
                  <Box key={bucket.day} sx={{ flex: 1, textAlign: 'center' }}>
                    <Box
                      sx={{
                        height: `${(bucket.posts / maxPosts) * 100}px`,
                        minHeight: bucket.posts ? 8 : 2,
                        bgcolor: bucket.posts ? '#0284c7' : '#e2e8f0',
                        borderRadius: 1,
                      }}
                    />
                    <Typography variant="caption">{bucket.day.slice(5)}</Typography>
                  </Box>
                ))}
              </Stack>
              <Typography variant="caption" color="text.secondary">
                Counts Lwal Kuu publish records, not estimated reach.
              </Typography>
            </CardContent>
          </Card>
        </Grid>
        <Grid item xs={12} md={5}>
          <Card sx={{ height: '100%' }}>
            <CardContent>
              <Typography variant="h6">Facebook vs TikTok</Typography>
              <Typography variant="body2" sx={{ mt: 2 }}>
                Facebook rows: {fbRows.length || 'none'} ({combineMetricSource(fbRows.map((r) => r.metric_source))})
              </Typography>
              <Typography variant="body2">
                TikTok rows: {ttRows.length || 'none'} ({combineMetricSource(ttRows.map((r) => r.metric_source))})
              </Typography>
              <Alert severity="info" sx={{ mt: 2 }}>
                Platform metrics are shown only after a successful insights sync. Missing values are labeled unavailable, not zero.
              </Alert>
            </CardContent>
          </Card>
        </Grid>
        <Grid item xs={12} md={6}>
          <Card>
            <CardContent>
              <Stack direction="row" justifyContent="space-between" sx={{ mb: 1 }}>
                <Typography variant="h6">Pending approval</Typography>
                <Button size="small" onClick={() => navigate('/admin/marketing/approvals')}>Review</Button>
              </Stack>
              {pending.length === 0 ? (
                <Typography variant="body2" color="text.secondary">No content waiting for review.</Typography>
              ) : (
                pending.slice(0, 5).map((item) => (
                  <Stack key={item.id} direction="row" justifyContent="space-between" sx={{ py: 0.75 }}>
                    <Typography variant="body2">{item.title}</Typography>
                    <ContentStatusChip status={item.status} />
                  </Stack>
                ))
              )}
            </CardContent>
          </Card>
        </Grid>
        <Grid item xs={12} md={6}>
          <Card>
            <CardContent>
              <Typography variant="h6" sx={{ mb: 1 }}>Upcoming scheduled</Typography>
              {upcoming.length === 0 ? (
                <Typography variant="body2" color="text.secondary">Nothing scheduled in Asia/Yangon time.</Typography>
              ) : (
                upcoming.slice(0, 5).map((item) => (
                  <Stack key={item.id} direction="row" justifyContent="space-between" sx={{ py: 0.75 }}>
                    <Typography variant="body2">{item.title}</Typography>
                    <Typography variant="caption">{formatYangon(item.scheduled_for)}</Typography>
                  </Stack>
                ))
              )}
            </CardContent>
          </Card>
        </Grid>
        <Grid item xs={12} md={6}>
          <Card>
            <CardContent>
              <Typography variant="h6" sx={{ mb: 1 }}>Recent published</Typography>
              {published.length === 0 ? (
                <Typography variant="body2" color="text.secondary">No published posts yet.</Typography>
              ) : (
                <TableContainer>
                <Table size="small" sx={{ minWidth: 440 }}>
                  <TableHead>
                    <TableRow>
                      <TableCell>Title</TableCell>
                      <TableCell>Platform</TableCell>
                      <TableCell>Published</TableCell>
                    </TableRow>
                  </TableHead>
                  <TableBody>
                    {published.slice(0, 5).map((item) => (
                      <TableRow key={item.id}>
                        <TableCell>{item.title}</TableCell>
                        <TableCell>{item.platform}</TableCell>
                        <TableCell>{formatYangon(item.published_at)}</TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
                </TableContainer>
              )}
            </CardContent>
          </Card>
        </Grid>
        <Grid item xs={12} md={6}>
          <Card>
            <CardContent>
              <Typography variant="h6">Monthly budget</Typography>
              <Typography variant="body2" color="text.secondary" sx={{ mb: 1 }}>
                {formatCurrency(spend)} of {formatCurrency(budgetLimit)} used · {formatCurrency(remaining)} remaining
              </Typography>
              <LinearProgress variant="determinate" value={Math.min(100, utilization ?? 0)} />
              <Typography variant="caption" color="text.secondary" display="block" sx={{ mt: 1 }}>
                Limits are ceilings. AI cannot launch ads or increase this budget.
              </Typography>
            </CardContent>
          </Card>
        </Grid>
      </Grid>
    </Box>
  );
};

function lastSevenDays(): string[] {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone: 'Asia/Yangon', year: 'numeric', month: '2-digit', day: '2-digit',
  }).formatToParts(new Date());
  const values = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  const anchor = new Date(Date.UTC(Number(values.year), Number(values.month) - 1, Number(values.day)));
  const days: string[] = [];
  for (let i = 6; i >= 0; i -= 1) {
    const d = new Date(anchor);
    d.setUTCDate(d.getUTCDate() - i);
    days.push(d.toISOString().slice(0, 10));
  }
  return days;
}

function yangonDate(iso: string): string {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone: 'Asia/Yangon', year: 'numeric', month: '2-digit', day: '2-digit',
  }).formatToParts(new Date(iso));
  const values = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  return `${values.year}-${values.month}-${values.day}`;
}
