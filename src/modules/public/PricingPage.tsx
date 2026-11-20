import React, { useState } from 'react';
import { Alert, Box, Button, Card, CardContent, Chip, CircularProgress, Container, Grid, List, ListItem, ListItemIcon, ListItemText, ToggleButton, ToggleButtonGroup, Typography } from '@mui/material';
import CheckCircleIcon from '@mui/icons-material/CheckCircle';
import { useQuery } from '@tanstack/react-query';
import { useNavigate } from 'react-router-dom';
import { supabase } from '@/lib/supabase';
import { LanguageSwitcher } from '@/i18n/LanguageSwitcher';
import { useI18n } from '@/i18n/I18nContext';
import { getPlanFeatureSection, getPlanLimitValue, getYearlySavingsPercent } from '@/modules/subscription/planPresentation.js';

interface PriceFeature { feature_id: string; is_enabled: boolean }
interface PriceLimit { feature_id: string; limit_value: number }
interface CatalogFeature { id: string; feature_key: string; name: string; feature_type: string; category: string }
interface PricePlan {
  id: string; name: string; slug: string; description: string | null; monthly_price_mmk: number; yearly_price_mmk: number;
  currency: string; display_order: number; trial_days: number; max_users: number; max_products: number; max_customers: number;
  max_suppliers: number; max_branches: number; plan_features: PriceFeature[]; plan_feature_limits: PriceLimit[];
}

export const PricingPage: React.FC = () => {
  const [cycle, setCycle] = useState<'monthly' | 'yearly'>('monthly');
  const navigate = useNavigate();
  const { t } = useI18n();
  const { data: pricingData, isLoading, isError } = useQuery({
    queryKey: ['public_subscription_plans'],
    queryFn: async (): Promise<{ plans: PricePlan[]; features: CatalogFeature[] }> => {
      const [plansResult, featuresResult] = await Promise.all([
        supabase.from('plans').select('*, plan_features(feature_id,is_enabled), plan_feature_limits(feature_id,limit_value)')
          .eq('is_active', true).eq('is_public', true).order('display_order'),
        supabase.from('features').select('id,feature_key,name,feature_type,category').eq('is_active', true).order('category').order('name'),
      ]);
      if (plansResult.error) throw plansResult.error;
      if (featuresResult.error) throw featuresResult.error;
      return {
        plans: (plansResult.data ?? []) as unknown as PricePlan[],
        features: (featuresResult.data ?? []) as CatalogFeature[],
      };
    },
    staleTime: 60_000,
  });
  const plans = pricingData?.plans ?? [];
  const catalogFeatures = pricingData?.features ?? [];
  const number = (value: number) => value === -1 ? t('Unlimited') : value.toLocaleString();
  const legacyLimit = (plan: PricePlan, key: string): number | null => {
    const limits: Record<string, number> = {
      max_users: plan.max_users,
      max_products: plan.max_products,
      max_customers: plan.max_customers,
      max_suppliers: plan.max_suppliers,
      max_branches: plan.max_branches,
    };
    return limits[key] ?? null;
  };

  return <Box sx={{ minHeight: '100vh', bgcolor: '#f8fafc', py: { xs: 6, md: 10 } }}>
    <Container maxWidth="lg">
      <Box sx={{ display: 'flex', justifyContent: 'flex-end', mb: 2 }}><LanguageSwitcher /></Box>
      <Box sx={{ textAlign: 'center', mb: 6 }}>
        <Chip label={t('Simple, predictable pricing')} sx={{ mb: 2, bgcolor: '#e0f2fe', color: '#0369a1', fontWeight: 600 }} />
        <Typography variant="h3" sx={{ fontWeight: 800, mb: 2 }}>{t('Plans for Myanmar Businesses')}</Typography>
        <Typography color="text.secondary">{t('Plan features and limits are managed from Lwal Kuu administration.')}</Typography>
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
          const assignments = new Map(plan.plan_features.map((item) => [item.feature_id, item.is_enabled]));
          const configuredLimits = new Map(plan.plan_feature_limits.map((item) => [item.feature_id, item.limit_value]));
          const booleanFeatures = catalogFeatures.filter((feature) => feature.feature_type === 'boolean');
          const enabledFeatures = booleanFeatures
            .filter((feature) => assignments.get(feature.id) === true)
            .map((feature) => ({ id: feature.id, name: feature.name, category: feature.category }));
          const previousPlan = plans[index - 1];
          const previousEnabledFeatures = previousPlan
            ? booleanFeatures.filter((feature) => previousPlan.plan_features.some((item) => item.feature_id === feature.id && item.is_enabled))
              .map((feature) => ({ id: feature.id, name: feature.name, category: feature.category }))
            : null;
          const featureSection = getPlanFeatureSection(enabledFeatures, previousEnabledFeatures);
          const limits = catalogFeatures.filter((feature) => feature.feature_type === 'limit').map((feature) => ({
            ...feature,
            limit_value: getPlanLimitValue(configuredLimits.get(feature.id), legacyLimit(plan, feature.feature_key)),
          }));
          const yearlySavings = getYearlySavingsPercent(Number(plan.monthly_price_mmk), Number(plan.yearly_price_mmk));
          return <Grid item xs={12} md={4} key={plan.id}>
            <Card sx={{ height: '100%', borderRadius: 3, border: plan.slug === 'business' ? '2px solid #0284c7' : '1px solid #e2e8f0' }}>
              <CardContent sx={{ p: 3 }}>
                <Typography variant="h5" fontWeight={800}>{t(plan.name)}</Typography>
                <Typography color="text.secondary" sx={{ minHeight: 48, my: 1 }}>{plan.description ? t(plan.description) : ''}</Typography>
                <Box sx={{ display: 'flex', alignItems: 'baseline', mb: 2 }}>
                  <Typography variant="h3" fontWeight={800}>{price.toLocaleString()}</Typography>
                  <Typography color="text.secondary" sx={{ ml: 1 }}>{plan.currency} / {cycle === 'yearly' ? t('year') : t('month')}</Typography>
                </Box>
                {cycle === 'yearly' && yearlySavings !== null && <Typography variant="body2" color="success.main" sx={{ mb: 1.5, fontWeight: 700 }}>
                  {t('Save {{percent}}% compared with monthly billing', { percent: yearlySavings })}
                </Typography>}
                <Button fullWidth variant="contained" sx={{ mb: 2 }} onClick={() => navigate(`/register?plan=${plan.id}&cycle=${cycle}`)}>{t('Choose this plan')}</Button>
                <Typography variant="subtitle2" fontWeight={700}>{t('Usage limits')}</Typography>
                <List dense disablePadding>{limits.map((item) => <ListItem key={item.id} disableGutters>
                  <ListItemText primary={`${t(item.name)}: ${item.limit_value === null ? t('Not configured') : number(item.limit_value)}`} />
                </ListItem>)}</List>
                <Typography variant="subtitle2" fontWeight={700} sx={{ mt: 1 }}>{t('Plan terms')}</Typography>
                <List dense disablePadding><ListItem disableGutters>
                  <ListItemText primary={`${t('Free trial')}: ${plan.trial_days > 0 ? t('{{days}} days', { days: plan.trial_days }) : t('No free trial')}`} />
                </ListItem></List>
                {featureSection.includesPreviousPlan && previousPlan && <Typography variant="body2" color="text.secondary" sx={{ mt: 1 }}>
                  {t('Includes all {{plan}} features.', { plan: t(previousPlan.name) })}
                </Typography>}
                <Typography variant="subtitle2" fontWeight={700} sx={{ mt: 1 }}>{t(featureSection.includesPreviousPlan ? 'Additional features' : 'Included features')}</Typography>
                <List dense disablePadding>{featureSection.features.length === 0
                  ? <ListItem disableGutters><ListItemText primary={t(enabledFeatures.length === 0 ? 'No modules configured' : 'No additional features')} /></ListItem>
                  : featureSection.features.map((item) => <ListItem key={item.id} disableGutters>
                    <ListItemIcon sx={{ minWidth: 28 }}><CheckCircleIcon color="success" fontSize="small" /></ListItemIcon>
                    <ListItemText primary={t(item.name)} />
                  </ListItem>)}</List>
              </CardContent>
            </Card>
          </Grid>;
        })}
      </Grid>
    </Container>
  </Box>;
};
