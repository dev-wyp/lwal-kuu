import React from 'react';
import { Alert, Box, Button, Card, CardContent, CircularProgress, Grid, MenuItem, Stack, TextField, Typography } from '@mui/material';
import { useQuery } from '@tanstack/react-query';
import { supabase } from '@/lib/supabase';
import { useMarketingWorkspace } from '../hooks/useMarketingWorkspace';
import { KpiCard } from '../components/KpiCard';
import { combineMetricSource, engagementRate, formatMetricNumber, formatPercent } from '../lib/metrics';
import type { SocialAnalyticsRow } from '../types';
import { useNotification } from '@/context/NotificationContext';

export const AnalyticsPage: React.FC = () => {
  const { orgId, data: workspaceData } = useMarketingWorkspace();
  const { showError, showSuccess } = useNotification();
  const accounts = workspaceData?.accounts ?? [];
  const [analysisDays, setAnalysisDays] = React.useState(30);
  const [analysis, setAnalysis] = React.useState<Record<string, unknown> | null>(null);
  const [analysisModel, setAnalysisModel] = React.useState('');
  const [analysisBusy, setAnalysisBusy] = React.useState(false);

  const { data = [], error } = useQuery({
    queryKey: ['social_analytics', orgId],
    enabled: Boolean(orgId),
    queryFn: async () => {
      const { data: rows, error: qError } = await supabase
        .from('social_analytics')
        .select('*')
        .eq('organization_id', orgId as string)
        .order('metric_date', { ascending: false })
        .limit(90);
      if (qError) throw qError;
      return (rows || []) as SocialAnalyticsRow[];
    },
  });

  const byPlatform = (platform: 'facebook' | 'tiktok') => data.filter((row) => row.platform === platform);
  const sum = (rows: SocialAnalyticsRow[], key: keyof SocialAnalyticsRow): number | null => {
    const values = rows
      .map((row) => row[key])
      .filter((value): value is number => typeof value === 'number' && Number.isFinite(value));
    return values.length ? values.reduce((total, value) => total + value, 0) : null;
  };

  const facebook = byPlatform('facebook');
  const tiktok = byPlatform('tiktok');
  const connected = accounts.some((a) => a.connection_status === 'connected');

  const generateAnalysis = async () => {
    if (!orgId) return;
    setAnalysisBusy(true);
    setAnalysis(null);
    try {
      const { data: result, error: functionError } = await supabase.functions.invoke('marketing-ai', {
        body: { action: 'analyze_analytics', organization_id: orgId, days: analysisDays },
      });
      if (functionError) {
        const context = (functionError as Error & { context?: unknown }).context;
        if (context instanceof Response) {
          try {
            const payload = await context.clone().json() as { error?: string };
            if (payload.error) throw new Error(payload.error);
          } catch (parseError) {
            if (parseError instanceof Error && parseError.message !== 'Unexpected end of JSON input') throw parseError;
          }
        }
        throw functionError;
      }
      if (result?.setup_required) throw new Error(result.message || 'Configure an AI provider in AI settings first.');
      if (result?.error) throw new Error(result.error);
      setAnalysis(result.analysis as Record<string, unknown>);
      setAnalysisModel(String(result.model || 'AI'));
      showSuccess('AI analysis generated from stored marketing data');
    } catch (analysisError) {
      showError(analysisError instanceof Error ? analysisError.message : 'AI analysis failed');
    } finally {
      setAnalysisBusy(false);
    }
  };

  const renderValue = (value: unknown) => typeof value === 'string'
    ? value
    : JSON.stringify(value, null, 2);

  return (
    <Box>
      <Card sx={{ mb: 3 }}>
        <CardContent>
          <Stack direction={{ xs: 'column', sm: 'row' }} spacing={2} alignItems={{ sm: 'center' }} justifyContent="space-between">
            <Box>
              <Typography variant="h6">AI analytics analysis</Typography>
              <Typography variant="body2" color="text.secondary">
                Get findings and next steps from saved social metrics, leads, and actual ad spend.
              </Typography>
            </Box>
            <Stack direction="row" spacing={1}>
              <TextField
                select
                size="small"
                label="Period"
                value={analysisDays}
                onChange={(event) => setAnalysisDays(Number(event.target.value))}
                disabled={analysisBusy}
                sx={{ minWidth: 125 }}
              >
                <MenuItem value={7}>7 days</MenuItem>
                <MenuItem value={30}>30 days</MenuItem>
                <MenuItem value={90}>90 days</MenuItem>
              </TextField>
              <Button variant="contained" onClick={generateAnalysis} disabled={analysisBusy || !orgId}>
                {analysisBusy ? <CircularProgress size={20} color="inherit" /> : 'Analyze'}
              </Button>
            </Stack>
          </Stack>
          {analysis && (
            <Box sx={{ mt: 2 }}>
              <Alert severity="info" sx={{ mb: 2 }}>
                Generated by {analysisModel}. AI summarizes stored data and recommendations; unavailable metrics are not estimated.
              </Alert>
              {Object.entries(analysis).map(([key, value]) => (
                <Box key={key} sx={{ mb: 1.5 }}>
                  <Typography variant="subtitle2" sx={{ textTransform: 'capitalize', fontWeight: 700 }}>
                    {key.replace(/_/g, ' ')}
                  </Typography>
                  <Typography component="pre" variant="body2" sx={{ whiteSpace: 'pre-wrap', fontFamily: 'inherit', m: 0 }}>
                    {renderValue(value)}
                  </Typography>
                </Box>
              ))}
            </Box>
          )}
        </CardContent>
      </Card>

      {!connected && (
        <Alert severity="warning" sx={{ mb: 2 }}>
          No connected social account. Metrics below stay unavailable until insights sync succeeds.
        </Alert>
      )}
      {error && <Alert severity="error">{error instanceof Error ? error.message : 'Analytics failed'}</Alert>}
      {data.length === 0 && (
        <Alert severity="info" sx={{ mb: 2 }}>
          No platform analytics have been stored. Lwal Kuu will not display fabricated reach or views as actual results.
        </Alert>
      )}

      <Typography variant="h6" sx={{ mb: 1 }}>Facebook</Typography>
      <Grid container spacing={2} sx={{ mb: 3 }}>
        <Grid item xs={6} md={3}><KpiCard title="Reach" value={formatMetricNumber(sum(facebook, 'reach'))} source={combineMetricSource(facebook.map((r) => r.metric_source))} /></Grid>
        <Grid item xs={6} md={3}><KpiCard title="Impressions" value={formatMetricNumber(sum(facebook, 'impressions'))} source={combineMetricSource(facebook.map((r) => r.metric_source))} /></Grid>
        <Grid item xs={6} md={3}><KpiCard title="Reactions" value={formatMetricNumber(sum(facebook, 'reactions'))} source={combineMetricSource(facebook.map((r) => r.metric_source))} /></Grid>
        <Grid item xs={6} md={3}><KpiCard title="Link clicks" value={formatMetricNumber(sum(facebook, 'link_clicks'))} source={combineMetricSource(facebook.map((r) => r.metric_source))} /></Grid>
      </Grid>

      <Typography variant="h6" sx={{ mb: 1 }}>TikTok</Typography>
      <Grid container spacing={2} sx={{ mb: 3 }}>
        <Grid item xs={6} md={3}><KpiCard title="Video views" value={formatMetricNumber(sum(tiktok, 'video_views'))} source={combineMetricSource(tiktok.map((r) => r.metric_source))} /></Grid>
        <Grid item xs={6} md={3}><KpiCard title="Likes" value={formatMetricNumber(sum(tiktok, 'likes'))} source={combineMetricSource(tiktok.map((r) => r.metric_source))} /></Grid>
        <Grid item xs={6} md={3}><KpiCard title="Comments" value={formatMetricNumber(sum(tiktok, 'comments'))} source={combineMetricSource(tiktok.map((r) => r.metric_source))} /></Grid>
        <Grid item xs={6} md={3}><KpiCard title="Shares" value={formatMetricNumber(sum(tiktok, 'shares'))} source={combineMetricSource(tiktok.map((r) => r.metric_source))} /></Grid>
      </Grid>

      <Card>
        <CardContent>
          <Typography variant="h6">Definitions</Typography>
          <Typography variant="body2">Engagement rate = Engagements / Reach × 100.</Typography>
          <Typography variant="body2">Facebook: {formatPercent(engagementRate(sum(facebook, 'engagements') ?? 0, sum(facebook, 'reach') ?? 0))} · TikTok: {formatPercent(engagementRate(sum(tiktok, 'engagements') ?? 0, sum(tiktok, 'reach') ?? 0))}.</Typography>
          <Typography variant="body2">Facebook and TikTok metrics are labeled separately and are not blended into a single unofficial number.</Typography>
          <Typography variant="body2" color="text.secondary">Advertising spend and cost-per-lead live on Overview and Settings, using recorded actuals only.</Typography>
        </CardContent>
      </Card>
    </Box>
  );
};
