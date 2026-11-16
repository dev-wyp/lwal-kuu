import React from 'react';
import { Alert, Button, CircularProgress } from '@mui/material';
import { useNavigate } from 'react-router-dom';
import { useEntitlements } from './useEntitlements';
import { useQuery } from '@tanstack/react-query';
import { supabase } from '@/lib/supabase';
import { useI18n } from '@/i18n/I18nContext';

interface PlanFeatureAccess {
  name: string;
  plan_features: Array<{ is_enabled: boolean; features: { feature_key: string } | null }>;
}

interface FeatureGateProps {
  feature: string;
  children: React.ReactNode;
  fallback?: React.ReactNode;
}

export const FeatureGate: React.FC<FeatureGateProps> = ({ feature, children, fallback }) => {
  const { t } = useI18n();
  const { data, isLoading, isError } = useEntitlements();
  const plansQuery = useQuery({
    queryKey: ['feature_upgrade_plans'],
    queryFn: async (): Promise<PlanFeatureAccess[]> => {
      const { data: plans, error } = await supabase.from('plans')
        .select('name,plan_features(is_enabled,features(feature_key))')
        .eq('is_active', true).eq('is_public', true).order('monthly_price_mmk');
      if (error) throw error;
      return (plans ?? []) as unknown as PlanFeatureAccess[];
    },
    staleTime: 60_000,
  });
  const navigate = useNavigate();
  if (isLoading) return <CircularProgress size={24} />;
  if (isError) return <Alert severity="error">{t("Could not verify this plan feature. Refresh and try again.")}</Alert>;
  const entitlement = data?.find((item) => item.feature_key === feature);
  if (entitlement?.is_allowed) return <>{children}</>;
  const includedPlan = plansQuery.data?.find((plan) => plan.plan_features.some((item) => item.is_enabled && item.features?.feature_key === feature));
  return <>{fallback ?? <Alert severity="info" action={<Button color="inherit" size="small" onClick={() => navigate('/app/subscription')}>{t("View plans")}</Button>}>
    {t(entitlement?.feature_name ?? feature)} {t("is not included in your current plan")}{includedPlan ? `; ${t('available on')} ${t(includedPlan.name)}.` : '.'}
  </Alert>}</>;
};
