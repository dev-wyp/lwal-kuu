import React, { useState } from 'react';
import { Alert, Box, Button, Card, CardContent, Chip, CircularProgress, Container, Grid, List, ListItem, ListItemIcon, ListItemText, ToggleButton, ToggleButtonGroup, Typography } from '@mui/material';
import CheckCircleIcon from '@mui/icons-material/CheckCircle';
import { useQuery } from '@tanstack/react-query';
import { useNavigate } from 'react-router-dom';
import { supabase } from '@/lib/supabase';
import { LanguageSwitcher } from '@/i18n/LanguageSwitcher';
import { useI18n } from '@/i18n/I18nContext';

interface PriceFeature { is_enabled: boolean; features: { name: string; feature_type: string } | null }
interface PriceLimit { limit_value: number; features: { name: string } | null }
interface PricePlan {
  id: string; name: string; slug: string; description: string | null; monthly_price_mmk: number; yearly_price_mmk: number;
  currency: string; display_order: number; plan_features: PriceFeature[]; plan_feature_limits: PriceLimit[];
}

export const PricingPage: React.FC = () => {
  const [cycle, setCycle] = useState<'monthly' | 'yearly'>('monthly');
  const navigate = useNavigate();
  const { t } = useI18n();
  const { data: plans = [], isLoading, isError } = useQuery({
    queryKey: ['public_subscription_plans'],
    queryFn: async (): Promise<PricePlan[]> => {
      const { data, error } = await supabase.from('plans').select('*, plan_features(is_enabled, features(name,feature_type)), plan_feature_limits(limit_value, features(name))')
        .eq('is_active', true).eq('is_public', true).order('display_order');
      if (error) throw error;
      return (data ?? []) as unknown as PricePlan[];
    },
    staleTime: 60_000,
  });
  const number = (value: number) => value === -1 ? t('Unlimited') : value.toLocaleString();

  return <Box sx={{ minHeight: '100vh', bgcolor: '#f8fafc', py: { xs: 6, md: 10 } }}>
    <Container maxWidth="lg">
      <Box sx={{ display: 'flex', justifyContent: 'flex-end', mb: 2 }}><LanguageSwitcher /></Box>
      <Box sx={{ textAlign: 'center', mb: 6 }}>
        <Chip label={t('Simple, predictable pricing')} sx={{ mb: 2, bgcolor: '#e0f2fe', color: '#0369a1', fontWeight: 600 }} />
        <Typography variant="h3" sx={{ fontWeight: 800, mb: 2 }}>{t('Plans for Myanmar Businesses')}</Typography>
        <Typography color="text.secondary">{t('Plan features and limits are managed from ShopFlow administration.')}</Typography>
        <ToggleButtonGroup value={cycle} exclusive onChange={(_, value: 'monthly' | 'yearly' | null) => value && setCycle(value)} sx={{ mt: 3, bgcolor: 'white' }}>
          <ToggleButton value="monthly">{t('Monthly')}</ToggleButton><ToggleButton value="yearly">{t('Yearly')}</ToggleButton>
        </ToggleButtonGroup>
      </Box>
      {isLoading && <Box sx={{ display: 'flex', justifyContent: 'center', py: 8 }}><CircularProgress /></Box>}
      {isError && <Alert severity="error">{t('Plans could not be loaded. Please try again later.')}</Alert>}
      {!isLoading && !isError && plans.length === 0 && <Alert severity="info">{t('No public plans are currently available.')}</Alert>}
      <Grid container spacing={3} alignItems="stretch">
        {plans.map((plan, index) => {
          const price = cycle === 'yearly' ? plan.yearly_price_mmk : plan.monthly_price_mmk;
          const inheritedFeatureNames = new Set(plans.slice(0, index).flatMap((lowerPlan) => lowerPlan.plan_features
            ?.filter((item) => item.is_enabled && item.features?.feature_type === 'boolean')
            .map((item) => item.features?.name)
            .filter((name): name is string => Boolean(name)) ?? []));
          const activeFeatures = plan.plan_features?.filter((item) => item.is_enabled && item.features?.feature_type === 'boolean'
            && item.features?.name && !inheritedFeatureNames.has(item.features.name)) ?? [];
          const includedPlan = plans[index - 1];
          const limits = plan.plan_feature_limits?.filter((item) => item.features?.name) ?? [];
          return <Grid item xs={12} md={4} key={plan.id}>
            <Card sx={{ height: '100%', borderRadius: 3, border: plan.slug === 'business' ? '2px solid #0284c7' : '1px solid #e2e8f0' }}>
              <CardContent sx={{ p: 3 }}>
                <Typography variant="h5" fontWeight={800}>{t(plan.name)}</Typography>
                <Typography color="text.secondary" sx={{ minHeight: 48, my: 1 }}>{plan.description ? t(plan.description) : ''}</Typography>
                <Box sx={{ display: 'flex', alignItems: 'baseline', mb: 2 }}>
                  <Typography variant="h3" fontWeight={800}>{price.toLocaleString()}</Typography>
                  <Typography color="text.secondary" sx={{ ml: 1 }}>{plan.currency} / {cycle === 'yearly' ? t('year') : t('month')}</Typography>
                </Box>
                <Button fullWidth variant="contained" sx={{ mb: 2 }} onClick={() => navigate(`/register?plan=${plan.id}&cycle=${cycle}`)}>{t('Choose this plan')}</Button>
                <Typography variant="subtitle2" fontWeight={700}>{t('Usage limits')}</Typography>
                <List dense disablePadding>{limits.map((item) => <ListItem key={item.features?.name} disableGutters>
                  <ListItemText primary={`${t(item.features?.name ?? '')}: ${number(item.limit_value)}`} />
                </ListItem>)}</List>
                {includedPlan && <Typography variant="body2" color="text.secondary" sx={{ mt: 1 }}>
                  {t('Includes all {{plan}} features.', { plan: t(includedPlan.name) })}
                </Typography>}
                <Typography variant="subtitle2" fontWeight={700} sx={{ mt: 1 }}>{t(includedPlan ? 'Additional features' : 'Included features')}</Typography>
                <List dense disablePadding>{activeFeatures.length === 0
                  ? <ListItem disableGutters><ListItemText primary={t(includedPlan ? 'No additional features' : 'No modules configured')} /></ListItem>
                  : activeFeatures.map((item) => <ListItem key={item.features?.name} disableGutters>
                    <ListItemIcon sx={{ minWidth: 28 }}><CheckCircleIcon color="success" fontSize="small" /></ListItemIcon>
                    <ListItemText primary={t(item.features?.name ?? '')} />
                  </ListItem>)}</List>
              </CardContent>
            </Card>
          </Grid>;
        })}
      </Grid>
    </Container>
  </Box>;
};
