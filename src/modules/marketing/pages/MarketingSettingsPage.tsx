import React, { useState } from 'react';
import { Alert, Box, Button, Grid, Stack, TextField, Typography } from '@mui/material';
import { useForm } from 'react-hook-form';
import { z } from 'zod';
import { zodResolver } from '@hookform/resolvers/zod';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/lib/supabase';
import { useOrg } from '@/context/OrgContext';
import { useNotification } from '@/context/NotificationContext';
import { useMarketingWorkspace } from '../hooks/useMarketingWorkspace';
import { budgetUtilization, formatPercent, remainingBudget } from '../lib/metrics';
import { mktRpc } from '../lib/db';
import type { AdCampaign } from '../types';

const schema = z.object({
  brand_name: z.string().min(2),
  market: z.string().min(2),
  primary_language: z.string().min(2),
  secondary_language: z.string().min(2),
  monthly_ad_budget_mmk: z.coerce.number().min(0),
  facebook_budget_mmk: z.coerce.number().min(0),
  tiktok_budget_mmk: z.coerce.number().min(0),
  ad_name: z.string().optional(),
  ad_platform: z.enum(['facebook', 'tiktok']).optional(),
  ad_planned: z.coerce.number().min(0).optional(),
}).refine((v) => v.facebook_budget_mmk + v.tiktok_budget_mmk <= v.monthly_ad_budget_mmk, {
  message: 'Platform allocations cannot exceed the monthly budget',
  path: ['tiktok_budget_mmk'],
});

type FormValues = z.infer<typeof schema>;

export const MarketingSettingsPage: React.FC = () => {
  const { formatCurrency } = useOrg();
  const { data, refetch, isOwnerOrAdmin, orgId } = useMarketingWorkspace();
  const { showError, showSuccess } = useNotification();
  const queryClient = useQueryClient();
  const [spendDrafts, setSpendDrafts] = useState<Record<string, string>>({});
  const workspace = data?.workspace;

  const { data: spend = 0 } = useQuery({
    queryKey: ['month_ad_spend', workspace?.id],
    enabled: Boolean(workspace?.id),
    queryFn: () => mktRpc<number>('month_ad_spend', { p_workspace_id: workspace?.id }),
  });

  const { data: ads = [] } = useQuery({
    queryKey: ['ad_campaigns', orgId],
    enabled: Boolean(orgId),
    queryFn: async () => {
      const { data: rows, error } = await supabase.from('ad_campaigns').select('*').eq('organization_id', orgId as string);
      if (error) throw error;
      return (rows || []) as AdCampaign[];
    },
  });

  const form = useForm<FormValues>({
    values: {
      brand_name: workspace?.brand_name || 'ShopFlow',
      market: workspace?.market || 'Myanmar',
      primary_language: workspace?.primary_language || 'Burmese',
      secondary_language: workspace?.secondary_language || 'English',
      monthly_ad_budget_mmk: Number(workspace?.monthly_ad_budget_mmk || 50000),
      facebook_budget_mmk: Number(workspace?.facebook_budget_mmk || 30000),
      tiktok_budget_mmk: Number(workspace?.tiktok_budget_mmk || 20000),
      ad_name: '',
      ad_platform: 'facebook',
      ad_planned: 0,
    },
    resolver: zodResolver(schema),
  });

  const save = form.handleSubmit(async (values) => {
    if (!workspace) return;
    const { error } = await supabase.from('marketing_workspaces').update({
      brand_name: values.brand_name,
      market: values.market,
      primary_language: values.primary_language,
      secondary_language: values.secondary_language,
      monthly_ad_budget_mmk: values.monthly_ad_budget_mmk,
      facebook_budget_mmk: values.facebook_budget_mmk,
      tiktok_budget_mmk: values.tiktok_budget_mmk,
    }).eq('id', workspace.id);
    if (error) showError(error.message);
    else {
      showSuccess('Workspace settings saved. Budget is a ceiling, not spend authorization.');
      await refetch();
    }
  });

  const proposeAd = form.handleSubmit(async (values) => {
    if (!workspace || !orgId || !values.ad_name) return;
    const { error } = await supabase.from('ad_campaigns').insert({
      workspace_id: workspace.id,
      organization_id: orgId,
      name: values.ad_name,
      platform: values.ad_platform || 'facebook',
      planned_spend_mmk: values.ad_planned || 0,
      status: 'proposed',
    });
    if (error) showError(error.message);
    else showSuccess('Ad proposal saved. It cannot go live until a platform superadmin approves spend.');
  });

  const approveAd = async (id: string, amount: number) => {
    try {
      await mktRpc('approve_ad_campaign', { p_campaign_id: id, p_approved_spend_mmk: amount });
      showSuccess('Spend approved');
    } catch (err) {
      showError(err instanceof Error ? err.message : 'Approval failed');
    }
  };

  const recordSpend = async (ad: AdCampaign) => {
    const amount = Number(spendDrafts[ad.id]);
    if (!Number.isFinite(amount) || amount <= 0) {
      showError('Enter a spend amount greater than zero');
      return;
    }
    try {
      await mktRpc('record_ad_spend', {
        p_campaign_id: ad.id,
        p_amount_mmk: amount,
        p_notes: 'Manually recorded actual spend',
      });
      showSuccess('Actual spend recorded');
      setSpendDrafts((current) => ({ ...current, [ad.id]: '' }));
      await Promise.all([
        queryClient.invalidateQueries({ queryKey: ['month_ad_spend', workspace?.id] }),
        queryClient.invalidateQueries({ queryKey: ['ad_campaigns', orgId] }),
      ]);
    } catch (err) {
      showError(err instanceof Error ? err.message : 'Could not record spend');
    }
  };

  const remaining = remainingBudget(Number(workspace?.monthly_ad_budget_mmk || 0), Number(spend || 0));

  return (
    <Box>
      <Alert severity="warning" sx={{ mb: 2 }}>
        AI cannot launch ads, raise this budget, or change payment settings. Actual spend is recorded only after platform superadmin approval.
      </Alert>
      <Typography variant="body2" sx={{ mb: 2 }}>
        Used {formatCurrency(Number(spend || 0))} · Remaining {formatCurrency(remaining)} · Utilization {formatPercent(budgetUtilization(Number(spend || 0), Number(workspace?.monthly_ad_budget_mmk || 0)))}
      </Typography>
      <Grid container spacing={2}>
        <Grid item xs={12} md={6}><TextField fullWidth label="Brand" {...form.register('brand_name')} disabled={!isOwnerOrAdmin} /></Grid>
        <Grid item xs={12} md={6}><TextField fullWidth label="Market" {...form.register('market')} disabled={!isOwnerOrAdmin} /></Grid>
        <Grid item xs={12} md={6}><TextField fullWidth label="Primary language" {...form.register('primary_language')} disabled={!isOwnerOrAdmin} /></Grid>
        <Grid item xs={12} md={6}><TextField fullWidth label="Secondary language" {...form.register('secondary_language')} disabled={!isOwnerOrAdmin} /></Grid>
        <Grid item xs={12} md={4}><TextField fullWidth type="number" label="Monthly budget (MMK)" {...form.register('monthly_ad_budget_mmk')} disabled={!isOwnerOrAdmin} /></Grid>
        <Grid item xs={12} md={4}><TextField fullWidth type="number" label="Facebook allocation" {...form.register('facebook_budget_mmk')} disabled={!isOwnerOrAdmin} /></Grid>
        <Grid item xs={12} md={4}><TextField fullWidth type="number" label="TikTok allocation" {...form.register('tiktok_budget_mmk')} disabled={!isOwnerOrAdmin} /></Grid>
      </Grid>
      {form.formState.errors.tiktok_budget_mmk && (
        <Alert severity="error" sx={{ mt: 2 }}>{form.formState.errors.tiktok_budget_mmk.message}</Alert>
      )}
      <Button sx={{ mt: 2 }} variant="contained" onClick={save} disabled={!isOwnerOrAdmin}>Save workspace</Button>

      <Typography variant="h6" sx={{ mt: 4 }}>Proposed ad spend</Typography>
      <Stack direction={{ xs: 'column', md: 'row' }} spacing={2} sx={{ mt: 1 }}>
        <TextField label="Proposal name" {...form.register('ad_name')} />
        <TextField type="number" label="Planned MMK" {...form.register('ad_planned')} />
        <Button variant="outlined" onClick={proposeAd} disabled={!isOwnerOrAdmin}>Create proposal</Button>
      </Stack>
      <Stack spacing={1} sx={{ mt: 2 }}>
        {ads.map((ad) => (
          <Alert key={ad.id} severity={ad.owner_approved ? 'success' : 'info'}>
            <Stack direction={{ xs: 'column', md: 'row' }} spacing={1} alignItems={{ md: 'center' }}>
              <Typography variant="body2">
                {ad.name} · {ad.platform} · planned {formatCurrency(ad.planned_spend_mmk)} · approved {formatCurrency(ad.approved_spend_mmk)} · actual {formatCurrency(ad.actual_spend_mmk)} · {ad.status}
              </Typography>
              {!ad.owner_approved && (
                <Button size="small" disabled={!isOwnerOrAdmin || ad.planned_spend_mmk <= 0} onClick={() => approveAd(ad.id, ad.planned_spend_mmk)}>
                  Approve spend
                </Button>
              )}
              {ad.owner_approved && ad.actual_spend_mmk < ad.approved_spend_mmk && (
                <>
                  <TextField
                    size="small"
                    type="number"
                    label="Actual MMK"
                    value={spendDrafts[ad.id] || ''}
                    onChange={(event) => setSpendDrafts((current) => ({ ...current, [ad.id]: event.target.value }))}
                    disabled={!isOwnerOrAdmin}
                  />
                  <Button size="small" disabled={!isOwnerOrAdmin} onClick={() => void recordSpend(ad)}>
                    Record spend
                  </Button>
                </>
              )}
            </Stack>
          </Alert>
        ))}
      </Stack>
    </Box>
  );
};
