import React from 'react';
import { Card, CardContent, Typography, Chip, Stack } from '@mui/material';
import type { MetricSource } from '../lib/metrics';
import { metricSourceLabel } from '../lib/metrics';

interface KpiCardProps {
  title: string;
  value: string;
  source: MetricSource;
  helper?: string;
}

export const KpiCard: React.FC<KpiCardProps> = ({ title, value, source, helper }) => {
  const color = source === 'platform' ? 'success' : source === 'estimated' ? 'warning' : 'default';

  return (
    <Card sx={{ height: '100%' }}>
      <CardContent>
        <Typography variant="caption" color="text.secondary" sx={{ fontWeight: 600 }}>
          {title}
        </Typography>
        <Typography variant="h5" sx={{ fontWeight: 700, my: 0.5 }}>
          {value}
        </Typography>
        <Stack direction="row" spacing={1} alignItems="center">
          <Chip size="small" label={metricSourceLabel(source)} color={color === 'default' ? undefined : color} />
          {helper && (
            <Typography variant="caption" color="text.secondary">
              {helper}
            </Typography>
          )}
        </Stack>
      </CardContent>
    </Card>
  );
};
