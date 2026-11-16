import React, { useState } from 'react';
import {
  Box,
  Typography,
  Button,
  Paper,
  Grid,
  Card,
  CardContent,
  Chip,
  Dialog,
  DialogTitle,
  DialogContent,
  DialogActions,
  TextField,
  MenuItem,
  CircularProgress,
  Alert,
  List,
  ListItem,
  ListItemIcon,
  ListItemText,
  ToggleButton,
  ToggleButtonGroup,
} from '@mui/material';
import LoyaltyIcon from '@mui/icons-material/Loyalty';
import AccountBalanceIcon from '@mui/icons-material/AccountBalance';
import CheckCircleIcon from '@mui/icons-material/CheckCircle';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/lib/supabase';
import { useOrg } from '@/context/OrgContext';
import { useNotification } from '@/context/NotificationContext';
import { useEntitlements } from './useEntitlements';
import { UsageLimitIndicator } from './UsageLimitIndicator';
import { useI18n } from '@/i18n/I18nContext';

interface SubscriptionSummary {
  found: boolean;
  status: string;
  plan_id?: string;
  plan_name?: string;
  billing_cycle?: string;
  trial_ends_at?: string | null;
  current_period_end?: string | null;
}

interface TenantPlanFeature {
  is_enabled: boolean;
  features: { name: string; feature_type: string } | null;
}

interface TenantPlanLimit {
  limit_value: number;
  features: { name: string } | null;
}

interface TenantPlan {
  id: string;
  name: string;
  slug: string;
  description: string | null;
  currency: string;
  monthly_price_mmk: number;
  yearly_price_mmk: number;
  max_users: number;
  max_products: number;
  max_customers: number;
  max_suppliers: number;
  max_branches: number;
  display_order: number;
  plan_features: TenantPlanFeature[];
  plan_feature_limits: TenantPlanLimit[];
}

export const SubscriptionPage: React.FC = () => {
  const { t } = useI18n();
  const { currentOrg, formatCurrency } = useOrg();
  const { showSuccess, showError } = useNotification();
  const queryClient = useQueryClient();
  const orgId = currentOrg?.id;
  const { data: entitlements = [] } = useEntitlements();

  const [upgradeModalOpen, setUpgradeModalOpen] = useState(false);
  const [targetPlanId, setTargetPlanId] = useState('business');
  const [billingCycle, setBillingCycle] = useState('monthly');
  const [paymentMethod, setPaymentMethod] = useState('kbz_pay');
  const [referenceNumber, setReferenceNumber] = useState('');
  const [notes, setNotes] = useState('');
  const [submitting, setSubmitting] = useState(false);

  // 1. Fetch Subscription & Plan
  const { data: subData } = useQuery({
    queryKey: ['subscription_details', orgId],
    queryFn: async () => {
      if (!orgId) return null;
      const { data, error } = await supabase.rpc('get_organization_subscription', { p_org_id: orgId });
      if (error) throw error;
      return (data ?? null) as unknown as SubscriptionSummary | null;
    },
    enabled: Boolean(orgId),
  });

  // Plans and their feature assignments are tenant-visible product data.
  const { data: plansMaster = [] } = useQuery({
    queryKey: ['plans_master_with_features'],
    queryFn: async () => {
      const { data, error } = await supabase.from('plans')
        .select('id,name,slug,description,currency,monthly_price_mmk,yearly_price_mmk,max_users,max_products,max_customers,max_suppliers,max_branches,display_order,plan_features(is_enabled,features(name,feature_type)),plan_feature_limits(limit_value,features(name))')
        .eq('is_active', true).eq('is_public', true).order('display_order');
      if (error) throw error;
      return (data ?? []) as unknown as TenantPlan[];
    },
  });

  const { data: paymentHistory = [] } = useQuery({
    queryKey: ['subscription_payments', orgId],
    queryFn: async () => {
      if (!orgId) return [];
      const { data, error } = await supabase.from('subscription_payments').select('id,amount,currency,payment_method,transaction_reference,payment_status,created_at,paid_at').eq('organization_id', orgId).order('created_at', { ascending: false });
      if (error) throw error;
      return data ?? [];
    },
    enabled: Boolean(orgId),
  });

  const handleSubmitPayment = async () => {
    if (!orgId || !referenceNumber.trim()) {
      showError('Please enter transaction reference number');
      return;
    }

    try {
      setSubmitting(true);
      const { error } = await supabase.rpc('submit_subscription_payment', {
        p_org_id: orgId,
        p_plan_id: targetPlanId,
        p_billing_cycle: billingCycle,
        p_payment_method: paymentMethod,
        p_reference_number: referenceNumber.trim(),
        p_notes: notes || null,
      });

      if (error) throw error;

      showSuccess('Payment receipt submitted! Platform admins will verify and activate your plan.');
      queryClient.invalidateQueries({ queryKey: ['subscription_details'] });
      setUpgradeModalOpen(false);
      setReferenceNumber('');
      setNotes('');
    } catch (err: any) {
      showError(err.message || 'Failed to submit subscription payment');
    } finally {
      setSubmitting(false);
    }
  };

  const isTrial = subData?.status === 'trialing';

  return (
    <Box>
      <Box sx={{ mb: 3 }}>
        <Typography variant="h4" sx={{ fontWeight: 800 }}>
          {t("SaaS Subscription & Billing")}</Typography>
        <Typography variant="body2" color="text.secondary">
          {t('Manage your cloud plan, usage limits, and subscription renewal.')}
        </Typography>
      </Box>

      {/* Plan Status Banner */}
      <Card sx={{ p: 1, borderRadius: 3, mb: 4, bgcolor: '#ffffff' }}>
        <CardContent>
          <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', flexWrap: 'wrap', gap: 2 }}>
            <Box sx={{ display: 'flex', alignItems: 'center', gap: 2 }}>
              <LoyaltyIcon sx={{ fontSize: 44, color: '#0284c7' }} />
              <div>
                <Box sx={{ display: 'flex', alignItems: 'center', gap: 1.5 }}>
                  <Typography variant="h5" sx={{ fontWeight: 800 }}>
                    {t(subData?.plan_name || 'No active plan')}
                  </Typography>
                  <Chip
                    label={t(subData?.status?.toUpperCase() || 'TRIALING')}
                    color={subData?.status === 'active' ? 'success' : isTrial ? 'primary' : 'warning'}
                    size="small"
                    sx={{ fontWeight: 700, height: 22, fontSize: 11 }}
                  />
                </Box>
                <Typography variant="body2" color="text.secondary">
                  {isTrial
                    ? `${t('Trial ends on:')} ${new Date(subData?.trial_ends_at || '').toLocaleDateString()}`
                    : `${t('Active period through:')} ${new Date(subData?.current_period_end || '').toLocaleDateString()}`}
                </Typography>
              </div>
            </Box>

            <Button
              variant="contained"
              onClick={() => {
                setTargetPlanId('business');
                setUpgradeModalOpen(true);
              }}
              sx={{ borderRadius: 2, bgcolor: '#0284c7', fontWeight: 600, px: 3 }}
            >
              {t("Upgrade / Renew Plan")}</Button>
          </Box>
        </CardContent>
      </Card>

      {/* Usage Limits */}
      <Box sx={{ textAlign: 'center', mb: 3 }}>
        <Typography variant="h4" sx={{ fontWeight: 800, mb: 2 }}>{t('Plans for Myanmar Businesses')}</Typography>
        <ToggleButtonGroup value={billingCycle} exclusive onChange={(_, value: 'monthly' | 'yearly' | null) => value && setBillingCycle(value)} sx={{ bgcolor: 'white' }}>
          <ToggleButton value="monthly">{t('Monthly')}</ToggleButton>
          <ToggleButton value="yearly">{t('Yearly')}</ToggleButton>
        </ToggleButtonGroup>
      </Box>
      <Grid container spacing={3} alignItems="stretch" sx={{ mb: 4 }}>
        {plansMaster.map((plan, index) => {
          const isCurrentPlan = plan.id === subData?.plan_id;
          const inheritedFeatureNames = new Set(plansMaster.slice(0, index).flatMap((lowerPlan) => lowerPlan.plan_features
            .filter((feature) => feature.is_enabled && feature.features?.feature_type === 'boolean')
            .map((feature) => feature.features?.name)
            .filter((name): name is string => Boolean(name))));
          const includedFeatures = plan.plan_features.filter((feature) => feature.is_enabled
            && feature.features?.feature_type === 'boolean'
            && feature.features.name
            && !inheritedFeatureNames.has(feature.features.name));
          const includedPlan = plansMaster[index - 1];
          const price = billingCycle === 'yearly' ? plan.yearly_price_mmk : plan.monthly_price_mmk;
          const limits = plan.plan_feature_limits.filter((item) => item.features?.name);
          return <Grid item xs={12} md={4} key={plan.id}>
            <Card sx={{ height: '100%', borderRadius: 3, border: isCurrentPlan || plan.slug === 'business' ? '2px solid #0284c7' : '1px solid #e2e8f0' }}>
              <CardContent sx={{ p: 3 }}>
                <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: 1 }}>
                <Typography variant="h5" fontWeight={800}>{t(plan.name)}</Typography>
                  {isCurrentPlan && <Chip size="small" color="primary" label={t("Current plan")} />}
                </Box>
                <Typography variant="body2" color="text.secondary" sx={{ minHeight: 48, my: 1 }}>{plan.description ? t(plan.description) : ''}</Typography>
                <Box sx={{ display: 'flex', alignItems: 'baseline', mb: 2 }}>
                  <Typography variant="h3" fontWeight={800}>{Number(price).toLocaleString()}</Typography>
                  <Typography color="text.secondary" sx={{ ml: 1 }}>{plan.currency} / {billingCycle === 'yearly' ? t('year') : t('month')}</Typography>
                </Box>
                <Button fullWidth variant={isCurrentPlan ? 'outlined' : 'contained'} sx={{ mb: 2 }} onClick={() => {
                  setTargetPlanId(plan.id);
                  setUpgradeModalOpen(true);
                }}>{t(isCurrentPlan ? 'Renew this plan' : 'Choose this plan')}</Button>
                <Typography variant="subtitle2" fontWeight={700}>{t('Usage limits')}</Typography>
                <List dense disablePadding>{limits.map((item) => <ListItem key={item.features?.name} disableGutters>
                  <ListItemText primary={`${t(item.features?.name ?? '')}: ${item.limit_value === -1 ? t('Unlimited') : item.limit_value.toLocaleString()}`} />
                </ListItem>)}</List>
                {includedPlan && <Typography variant="body2" color="text.secondary" sx={{ mt: 1.5 }}>
                  {t('Includes all {{plan}} features.', { plan: t(includedPlan.name) })}
                </Typography>}
                <Typography variant="subtitle2" fontWeight={700} sx={{ mt: 1.5 }}>{t(includedPlan ? 'Additional features' : 'Included features')}</Typography>
                <List dense disablePadding>{includedFeatures.length === 0
                  ? <ListItem disableGutters><ListItemText primary={t(includedPlan ? 'No additional features' : 'No modules configured')} /></ListItem>
                  : includedFeatures.map((feature) => <ListItem key={feature.features?.name} disableGutters>
                    <ListItemIcon sx={{ minWidth: 28 }}><CheckCircleIcon color="success" fontSize="small" /></ListItemIcon>
                    <ListItemText primary={t(feature.features?.name ?? '')} />
                  </ListItem>)}</List>
              </CardContent>
            </Card>
          </Grid>;
        })}
      </Grid>

      <Typography variant="h6" sx={{ fontWeight: 700, mb: 2 }}>
        {t("Plan Usage Meters")}</Typography>

      <Grid container spacing={3} sx={{ mb: 4 }}>
      {entitlements.filter((item) => item.feature_type === 'limit' && item.current_usage !== null).map((item) => (
        <Grid item xs={12} md={4} key={item.feature_key}>
          <Paper elevation={0} sx={{ p: 2.5, borderRadius: 3, border: '1px solid #e2e8f0', bgcolor: '#ffffff' }}>
            <UsageLimitIndicator entitlement={item} />
          </Paper>
        </Grid>
      ))}
      </Grid>

      <Typography variant="h6" sx={{ fontWeight: 700, mb: 2 }}>{t("Payment history")}</Typography>
      <Grid container spacing={1} sx={{ mb: 4 }}>
        {paymentHistory.length === 0 && <Grid item xs={12}><Alert severity="info">{t("No subscription payments have been submitted yet.")}</Alert></Grid>}
        {paymentHistory.map((payment) => <Grid item xs={12} key={payment.id}>
          <Paper sx={{ p: 2, display: 'flex', justifyContent: 'space-between', gap: 2, flexWrap: 'wrap' }}>
            <Typography>{payment.transaction_reference || 'Payment'} · {formatCurrency(Number(payment.amount))} · {payment.payment_method ?? '—'}</Typography>
            <Chip size="small" label={payment.payment_status.toUpperCase()} color={payment.payment_status === 'paid' ? 'success' : payment.payment_status === 'failed' ? 'error' : 'warning'} />
          </Paper>
        </Grid>)}
      </Grid>

      {/* Upgrade Modal */}
      <Dialog open={upgradeModalOpen} onClose={() => setUpgradeModalOpen(false)} maxWidth="sm" fullWidth>
        <DialogTitle sx={{ fontWeight: 700 }}>{t("Upgrade or Renew Subscription")}</DialogTitle>
        <DialogContent dividers>
          <Alert severity="info" sx={{ mb: 3, borderRadius: 2 }}>
            {t("Payments are manually verified by platform administrators within 2 hours. Official Myanmar payment gateway integration will auto-activate once merchant credentials are connected.")}</Alert>

          <Grid container spacing={2}>
            <Grid item xs={12} sm={6}>
              <TextField
                fullWidth
                size="small"
                select
                label={t("Select Plan")}
                value={targetPlanId}
                onChange={(e) => setTargetPlanId(e.target.value)}
              >
                {plansMaster.map((p) => (
                  <MenuItem key={p.id} value={p.id}>
                    {t(p.name)} ({formatCurrency(Number(billingCycle === 'yearly' ? p.yearly_price_mmk : p.monthly_price_mmk))}/{billingCycle === 'yearly' ? t('year') : t('mo')})
                  </MenuItem>
                ))}
              </TextField>
            </Grid>

            <Grid item xs={12} sm={6}>
              <TextField
                fullWidth
                size="small"
                select
                label={t("Billing Cycle")}
                value={billingCycle}
                onChange={(e) => setBillingCycle(e.target.value)}
              >
                <MenuItem value="monthly">{t("Monthly")}</MenuItem>
                <MenuItem value="yearly">{t("Yearly (Save 16%)")}</MenuItem>
              </TextField>
            </Grid>

            <Grid item xs={12}>
              <Paper elevation={0} sx={{ p: 2, bgcolor: '#f8fafc', borderRadius: 2, border: '1px solid #e2e8f0' }}>
                <Typography variant="subtitle2" sx={{ fontWeight: 700, mb: 1, display: 'flex', alignItems: 'center', gap: 1 }}>
                  <AccountBalanceIcon fontSize="small" sx={{ color: '#0284c7' }} /> {t("Payment Destination Accounts:")}</Typography>
                <Typography variant="body2" sx={{ fontSize: 13 }}>
                  &bull; <strong>KBZPay / WavePay:</strong> 09-798888888 (Lwal Kuu SaaS Admin)<br />
                  &bull; <strong>KBZ Bank:</strong> 123-456-78901234 (Lwal Kuu Cloud Co., Ltd.)<br />
                  &bull; <strong>AYA Bank:</strong> 200-345-67890 (Lwal Kuu Cloud Co., Ltd.)
                </Typography>
              </Paper>
            </Grid>

            <Grid item xs={12} sm={6}>
              <TextField
                fullWidth
                size="small"
                select
                label={t("Remittance Method")}
                value={paymentMethod}
                onChange={(e) => setPaymentMethod(e.target.value)}
              >
                <MenuItem value="kbz_pay">KBZPay</MenuItem>
                <MenuItem value="wave_pay">WavePay</MenuItem>
                <MenuItem value="bank_transfer">{t("KBZ / AYA / CB Bank Transfer")}</MenuItem>
              </TextField>
            </Grid>

            <Grid item xs={12} sm={6}>
              <TextField
                fullWidth
                size="small"
                label={t("Transaction ID / Ref #")}
                placeholder="e.g. Trx #891234..."
                value={referenceNumber}
                onChange={(e) => setReferenceNumber(e.target.value)}
              />
            </Grid>

            <Grid item xs={12}>
              <TextField
                fullWidth
                size="small"
                label="Notes / Depositor Name"
                value={notes}
                onChange={(e) => setNotes(e.target.value)}
              />
            </Grid>
          </Grid>
        </DialogContent>
        <DialogActions sx={{ px: 3, py: 2 }}>
          <Button onClick={() => setUpgradeModalOpen(false)} disabled={submitting}>
            {t("Cancel")}</Button>
          <Button
            variant="contained"
            onClick={handleSubmitPayment}
            disabled={submitting || !referenceNumber.trim()}
            sx={{ bgcolor: '#0f172a', fontWeight: 600 }}
          >
            {submitting ? <CircularProgress size={20} color="inherit" /> : 'Submit Proof of Payment'}
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
};
