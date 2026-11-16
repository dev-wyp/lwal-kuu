import React, { useState } from 'react';
import { Alert, Box, Button, Card, CardContent, Stack, Typography } from '@mui/material';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/lib/supabase';
import { useNotification } from '@/context/NotificationContext';
import { useMarketingWorkspace } from '../hooks/useMarketingWorkspace';
import type { MarketingReport } from '../types';

export const ReportsPage: React.FC = () => {
  const { orgId } = useMarketingWorkspace();
  const { showError, showSuccess } = useNotification();
  const queryClient = useQueryClient();
  const [busy, setBusy] = useState(false);

  const { data = [], error } = useQuery({
    queryKey: ['marketing_reports', orgId],
    enabled: Boolean(orgId),
    queryFn: async () => {
      const { data: rows, error: qError } = await supabase
        .from('marketing_reports')
        .select('*')
        .eq('organization_id', orgId as string)
        .order('period_start', { ascending: false });
      if (qError) throw qError;
      return (rows || []) as MarketingReport[];
    },
  });

  const generate = async (reportType: 'weekly' | 'monthly') => {
    setBusy(true);
    try {
      const { data: payload, error: fnError } = await supabase.functions.invoke('marketing-ai', {
        body: { action: 'report', organization_id: orgId, report_type: reportType },
      });
      if (fnError) throw fnError;
      if (payload?.setup_required) {
        showError(payload.message);
        return;
      }
      showSuccess(`${reportType} report generated from stored metrics only.`);
      await queryClient.invalidateQueries({ queryKey: ['marketing_reports'] });
    } catch (err) {
      showError(err instanceof Error ? err.message : 'Report generation failed');
    } finally {
      setBusy(false);
    }
  };

  return (
    <Box>
      <Stack direction="row" spacing={1} sx={{ mb: 2 }}>
        <Button variant="contained" disabled={busy} onClick={() => generate('weekly')}>Generate weekly report</Button>
        <Button variant="outlined" disabled={busy} onClick={() => generate('monthly')}>Generate monthly report</Button>
      </Stack>
      {error && <Alert severity="error">{error instanceof Error ? error.message : 'Failed to load reports'}</Alert>}
      {data.length === 0 && (
        <Alert severity="info">No reports yet. Reports use stored analytics and will state when data could not be retrieved.</Alert>
      )}
      <Stack spacing={2}>
        {data.map((report) => {
          const summary = report.summary as Record<string, unknown>;
          return (
            <Card key={report.id}>
              <CardContent>
                <Typography variant="h6">{report.report_type} · {report.period_start} to {report.period_end}</Typography>
                <Typography variant="caption">{report.status} · {report.generated_by}</Typography>
                <Typography variant="body2" sx={{ mt: 1, whiteSpace: 'pre-wrap' }}>
                  {String(summary.executive_summary || JSON.stringify(summary, null, 2))}
                </Typography>
              </CardContent>
            </Card>
          );
        })}
      </Stack>
    </Box>
  );
};
