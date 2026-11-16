import React, { useEffect, useMemo, useState } from 'react';
import { Alert, Box, Button, Checkbox, CircularProgress, FormControlLabel, Grid, MenuItem, Paper, TextField, Typography } from '@mui/material';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/lib/supabase';
import { useNotification } from '@/context/NotificationContext';
import { useI18n } from '@/i18n/I18nContext';

interface Plan { id: string; name: string; slug: string; description: string | null; monthly_price_mmk: number; yearly_price_mmk: number; max_users: number; max_products: number; max_customers: number; max_suppliers: number; max_branches: number; is_active: boolean; is_public: boolean; display_order: number }
interface Feature { id: string; feature_key: string; name: string; category: string; feature_type: string }
interface PlanFeature { feature_id: string; is_enabled: boolean }
interface PlanLimit { feature_id: string; limit_value: number }
interface FeatureValue { enabled: boolean; limit: number | null }

export const PlanManagementPage: React.FC = () => {
  const { t } = useI18n();
  const queryClient = useQueryClient();
  const { showSuccess, showError } = useNotification();
  const [selectedId, setSelectedId] = useState('');
  const [draft, setDraft] = useState<Plan | null>(null);
  const [featureValues, setFeatureValues] = useState<Record<string, FeatureValue>>({});
  const plansQuery = useQuery({ queryKey: ['admin_plans'], queryFn: async () => {
    const { data, error } = await supabase.from('plans').select('*').order('display_order');
    if (error) throw error;
    return (data ?? []) as unknown as Plan[];
  }});
  const featuresQuery = useQuery({ queryKey: ['admin_features'], queryFn: async () => {
    const { data, error } = await supabase.from('features').select('id,feature_key,name,category,feature_type').eq('is_active', true).order('category').order('name');
    if (error) throw error;
    return (data ?? []) as unknown as Feature[];
  }});
  const planFeaturesQuery = useQuery({ queryKey: ['admin_plan_features', selectedId], enabled: Boolean(selectedId), queryFn: async () => {
    const [featureResult, limitResult] = await Promise.all([
      supabase.from('plan_features').select('feature_id,is_enabled').eq('plan_id', selectedId),
      supabase.from('plan_feature_limits').select('feature_id,limit_value').eq('plan_id', selectedId),
    ]);
    if (featureResult.error) throw featureResult.error;
    if (limitResult.error) throw limitResult.error;
    return { features: (featureResult.data ?? []) as unknown as PlanFeature[], limits: (limitResult.data ?? []) as unknown as PlanLimit[] };
  }});

  useEffect(() => {
    const plan = plansQuery.data?.find((item) => item.id === selectedId) ?? null;
    if (plan) setDraft(plan);
  }, [plansQuery.data, selectedId]);
  useEffect(() => {
    if (!featuresQuery.data || !planFeaturesQuery.data) return;
    const featureState: Record<string, FeatureValue> = {};
    for (const item of featuresQuery.data) {
      const mapping = planFeaturesQuery.data.features.find((row) => row.feature_id === item.id);
      const limit = planFeaturesQuery.data.limits.find((row) => row.feature_id === item.id);
      featureState[item.feature_key] = { enabled: mapping?.is_enabled ?? false, limit: limit?.limit_value ?? null };
    }
    setFeatureValues(featureState);
  }, [featuresQuery.data, planFeaturesQuery.data]);

  const saveMutation = useMutation({
    mutationFn: async () => {
      if (!draft) throw new Error('Choose a plan first');
      const featurePayload = (featuresQuery.data ?? []).map((feature) => ({
        feature_key: feature.feature_key,
        is_enabled: featureValues[feature.feature_key]?.enabled ?? false,
        ...(feature.feature_type === 'limit' ? { limit_value: featureValues[feature.feature_key]?.limit ?? -1 } : {}),
      }));
      const { error } = await supabase.rpc('admin_update_plan_configuration', { p_plan: draft, p_features: featurePayload });
      if (error) throw error;
    },
    onSuccess: async () => {
      showSuccess('Plan settings saved.');
      await Promise.all([queryClient.invalidateQueries({ queryKey: ['admin_plans'] }), queryClient.invalidateQueries({ queryKey: ['public_subscription_plans'] })]);
    },
    onError: (error) => showError(error.message || 'Could not save plan settings'),
  });
  const groupedFeatures = useMemo(() => (featuresQuery.data ?? []).reduce<Record<string, Feature[]>>((groups, feature) => {
    (groups[feature.category] ??= []).push(feature);
    return groups;
  }, {}), [featuresQuery.data]);

  if (plansQuery.isLoading || featuresQuery.isLoading) return <Box sx={{ display: 'grid', placeItems: 'center', p: 8 }}><CircularProgress /></Box>;
  if (plansQuery.isError || featuresQuery.isError) return <Alert severity="error">{t('Could not load plan configuration.')}</Alert>;

  const updateDraft = (key: keyof Plan, value: string | number | boolean) => setDraft((current) => current ? { ...current, [key]: value } : current);
  return <Box>
    <Typography variant="h4" fontWeight={800} sx={{ mb: 1 }}>{t("Plan & Feature Management")}</Typography>
    <Typography color="text.secondary" sx={{ mb: 3 }}>{t("Edit published plan prices, limits, and feature access. Changes are recorded in the subscription audit log.")}</Typography>
    <Paper sx={{ p: 3, mb: 3 }}>
      <Box sx={{ display: 'flex', alignItems: 'center', gap: 2, flexWrap: 'wrap' }}>
        <TextField select label={t('Plan')} value={selectedId} onChange={(event) => setSelectedId(event.target.value)} sx={{ minWidth: 240 }}>
          {(plansQuery.data ?? []).map((plan) => <MenuItem value={plan.id} key={plan.id}>{t(plan.name)}</MenuItem>)}
        </TextField>
        <Button variant="outlined" onClick={() => {
          const stamp = Date.now();
          const newPlan: Plan = { id: `custom-${stamp}`, name: 'New Plan', slug: `custom-${stamp}`, description: '', monthly_price_mmk: 0, yearly_price_mmk: 0,
            max_users: 1, max_products: 100, max_customers: 100, max_suppliers: 20, max_branches: 1, is_active: false, is_public: false, display_order: (plansQuery.data?.length ?? 0) + 1 };
          setSelectedId(newPlan.id);
          setDraft(newPlan);
          setFeatureValues(Object.fromEntries((featuresQuery.data ?? []).map((feature) => [feature.feature_key, { enabled: false, limit: feature.feature_type === 'limit' ? -1 : null }])));
        }}>{t('Create plan')}</Button>
      </Box>
    </Paper>
    {draft && <>
      <Paper sx={{ p: 3, mb: 3 }}>
        <Grid container spacing={2}>
          {([['name','Name'],['slug','Slug'],['description','Description'],['monthly_price_mmk','Monthly MMK'],['yearly_price_mmk','Yearly MMK']] as Array<[keyof Plan,string]>).map(([key,label]) => <Grid item xs={12} sm={6} md={4} key={key}>
            <TextField fullWidth label={t(label)} value={String(draft[key] ?? '')} type={key.toString().includes('price') ? 'number' : 'text'} onChange={(event) => updateDraft(key, ['monthly_price_mmk','yearly_price_mmk'].includes(key) ? Number(event.target.value) : event.target.value)} />
          </Grid>)}
          <Grid item><FormControlLabel control={<Checkbox checked={draft.is_active} onChange={(event) => updateDraft('is_active', event.target.checked)} />} label={t('Active')} /></Grid>
          <Grid item><FormControlLabel control={<Checkbox checked={draft.is_public} onChange={(event) => updateDraft('is_public', event.target.checked)} />} label={t('Public')} /></Grid>
        </Grid>
      </Paper>
      {planFeaturesQuery.isLoading ? <CircularProgress /> : Object.entries(groupedFeatures).map(([category, features]) => <Paper key={category} sx={{ p: 2.5, mb: 2 }}>
        <Typography variant="h6" textTransform="capitalize" fontWeight={700}>{t(category)}</Typography>
        <Grid container spacing={1}>{(features ?? []).map((feature) => <Grid item xs={12} sm={6} md={4} key={feature.feature_key}>
          <FormControlLabel control={<Checkbox checked={featureValues[feature.feature_key]?.enabled ?? false} onChange={(event) => setFeatureValues((old) => ({ ...old, [feature.feature_key]: { ...old[feature.feature_key], enabled: event.target.checked } }))} />} label={t(feature.name)} />
          {feature.feature_type === 'limit' && <TextField size="small" type="number" label={t("Limit (-1 unlimited)")} value={featureValues[feature.feature_key]?.limit ?? -1} onChange={(event) => setFeatureValues((old) => ({ ...old, [feature.feature_key]: { ...old[feature.feature_key], limit: Number(event.target.value) } }))} />}
        </Grid>)}</Grid>
      </Paper>)}
      <Button variant="contained" size="large" disabled={saveMutation.isPending || planFeaturesQuery.isLoading} onClick={() => saveMutation.mutate()}>{saveMutation.isPending ? t('Saving…') : t('Save plan configuration')}</Button>
    </>}
  </Box>;
};
