import React from 'react';
import { Alert, Box, LinearProgress, Typography } from '@mui/material';
import { OrganizationEntitlement } from './useEntitlements';
import { useI18n } from '@/i18n/I18nContext';

export const UsageLimitIndicator: React.FC<{ entitlement: OrganizationEntitlement }> = ({ entitlement }) => {
  const { t } = useI18n();
  const used = entitlement.current_usage ?? 0;
  const limit = entitlement.limit_value ?? -1;
  const unlimited = limit === -1;
  const percent = unlimited ? 0 : Math.min(100, Math.round((used / Math.max(1, limit)) * 100));
  return <Box>
    <Typography variant="subtitle2" sx={{ fontWeight: 700 }}>{t(entitlement.feature_name)}</Typography>
    <Typography variant="caption" color="text.secondary" display="block" sx={{ mb: 1 }}>
      {used.toLocaleString()} / {unlimited ? t('Unlimited') : limit.toLocaleString()}
    </Typography>
    {!unlimited && <LinearProgress variant="determinate" value={percent} color={percent >= 100 ? 'error' : percent >= 80 ? 'warning' : 'primary'} />}
    {!unlimited && percent >= 80 && <Alert severity={percent >= 100 ? 'error' : 'warning'} sx={{ mt: 1, py: 0 }}>
      {percent >= 100 ? t('Plan limit reached. Upgrade to add more.') : t('You are nearing this plan limit.')}
    </Alert>}
  </Box>;
};
