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
  LinearProgress,
  Dialog,
  DialogTitle,
  DialogContent,
  DialogActions,
  TextField,
  MenuItem,
  CircularProgress,
  Alert,
} from '@mui/material';
import LoyaltyIcon from '@mui/icons-material/Loyalty';
import AccountBalanceIcon from '@mui/icons-material/AccountBalance';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/lib/supabase';
import { useOrg } from '@/context/OrgContext';
import { useNotification } from '@/context/NotificationContext';

export const SubscriptionPage: React.FC = () => {
  const { currentOrg, formatCurrency } = useOrg();
  const { showSuccess, showError } = useNotification();
  const queryClient = useQueryClient();
  const orgId = currentOrg?.id;

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
      const { data, error } = await supabase
        .from('subscriptions')
        .select(`
          *,
          plans(*)
        `)
        .eq('organization_id', orgId)
        .single();

      if (error && error.code !== 'PGRST116') throw error;
      return data || null;
    },
    enabled: Boolean(orgId),
  });

  // 2. Fetch Usage Limits
  const { data: usageLimits = [] } = useQuery({
    queryKey: ['usage_limits', orgId],
    queryFn: async () => {
      if (!orgId) return [];
      const { data, error } = await supabase
        .from('usage_limits')
        .select('*')
        .eq('organization_id', orgId);

      if (error) throw error;
      return data || [];
    },
    enabled: Boolean(orgId),
  });

  // 3. Fetch Plans Master
  const { data: plansMaster = [] } = useQuery({
    queryKey: ['plans_master'],
    queryFn: async () => {
      const { data, error } = await supabase.from('plans').select('*').order('monthly_price_mmk');
      if (error) throw error;
      return data || [];
    },
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

  const currentPlan = subData?.plans;
  const isTrial = subData?.status === 'trialing';

  return (
    <Box>
      <Box sx={{ mb: 3 }}>
        <Typography variant="h4" sx={{ fontWeight: 800 }}>
          SaaS Subscription & Billing
        </Typography>
        <Typography variant="body2" color="text.secondary">
          Manage your cloud plan, usage limits, and subscription renewal.
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
                    {currentPlan?.name || 'Free Trial'}
                  </Typography>
                  <Chip
                    label={subData?.status?.toUpperCase() || 'TRIALING'}
                    color={subData?.status === 'active' ? 'success' : isTrial ? 'primary' : 'warning'}
                    size="small"
                    sx={{ fontWeight: 700, height: 22, fontSize: 11 }}
                  />
                </Box>
                <Typography variant="body2" color="text.secondary">
                  {isTrial
                    ? `Trial ends on: ${new Date(subData?.trial_ends_at || '').toLocaleDateString()}`
                    : `Active period through: ${new Date(subData?.current_period_end || '').toLocaleDateString()}`}
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
              Upgrade / Renew Plan
            </Button>
          </Box>
        </CardContent>
      </Card>

      {/* Usage Limits */}
      <Typography variant="h6" sx={{ fontWeight: 700, mb: 2 }}>
        Plan Usage Meters
      </Typography>

      <Grid container spacing={3} sx={{ mb: 4 }}>
        {usageLimits.map((limit: any) => {
          const percentage = Math.min(100, Math.round((limit.current_value / limit.limit_value) * 100));
          const metricLabel =
            limit.metric === 'product_count'
              ? 'Catalog Products'
              : limit.metric === 'user_count'
              ? 'Staff Users'
              : 'Monthly Sales Invoices';

          return (
            <Grid item xs={12} md={4} key={limit.id}>
              <Paper elevation={0} sx={{ p: 2.5, borderRadius: 3, border: '1px solid #e2e8f0', bgcolor: '#ffffff' }}>
                <Typography variant="subtitle2" sx={{ fontWeight: 700, mb: 0.5 }}>
                  {metricLabel}
                </Typography>
                <Typography variant="caption" color="text.secondary" sx={{ display: 'block', mb: 1.5 }}>
                  {limit.current_value} of {limit.limit_value} allowed
                </Typography>

                <LinearProgress
                  variant="determinate"
                  value={percentage}
                  sx={{
                    height: 8,
                    borderRadius: 4,
                    bgcolor: '#e2e8f0',
                    '& .MuiLinearProgress-bar': {
                      bgcolor: percentage > 90 ? '#ef4444' : '#0284c7',
                    },
                  }}
                />
              </Paper>
            </Grid>
          );
        })}
      </Grid>

      {/* Upgrade Modal */}
      <Dialog open={upgradeModalOpen} onClose={() => setUpgradeModalOpen(false)} maxWidth="sm" fullWidth>
        <DialogTitle sx={{ fontWeight: 700 }}>Upgrade or Renew Subscription</DialogTitle>
        <DialogContent dividers>
          <Alert severity="info" sx={{ mb: 3, borderRadius: 2 }}>
            Payments are manually verified by platform administrators within 2 hours. Official Myanmar payment gateway integration will auto-activate once merchant credentials are connected.
          </Alert>

          <Grid container spacing={2}>
            <Grid item xs={12} sm={6}>
              <TextField
                fullWidth
                size="small"
                select
                label="Select Plan"
                value={targetPlanId}
                onChange={(e) => setTargetPlanId(e.target.value)}
              >
                {plansMaster.map((p: any) => (
                  <MenuItem key={p.id} value={p.id}>
                    {p.name} ({formatCurrency(p.monthly_price_mmk)}/mo)
                  </MenuItem>
                ))}
              </TextField>
            </Grid>

            <Grid item xs={12} sm={6}>
              <TextField
                fullWidth
                size="small"
                select
                label="Billing Cycle"
                value={billingCycle}
                onChange={(e) => setBillingCycle(e.target.value)}
              >
                <MenuItem value="monthly">Monthly</MenuItem>
                <MenuItem value="yearly">Yearly (Save 16%)</MenuItem>
              </TextField>
            </Grid>

            <Grid item xs={12}>
              <Paper elevation={0} sx={{ p: 2, bgcolor: '#f8fafc', borderRadius: 2, border: '1px solid #e2e8f0' }}>
                <Typography variant="subtitle2" sx={{ fontWeight: 700, mb: 1, display: 'flex', alignItems: 'center', gap: 1 }}>
                  <AccountBalanceIcon fontSize="small" sx={{ color: '#0284c7' }} /> Payment Destination Accounts:
                </Typography>
                <Typography variant="body2" sx={{ fontSize: 13 }}>
                  &bull; <strong>KBZPay / WavePay:</strong> 09-798888888 (ShopFlow SaaS Admin)<br />
                  &bull; <strong>KBZ Bank:</strong> 123-456-78901234 (ShopFlow Cloud Co., Ltd.)<br />
                  &bull; <strong>AYA Bank:</strong> 200-345-67890 (ShopFlow Cloud Co., Ltd.)
                </Typography>
              </Paper>
            </Grid>

            <Grid item xs={12} sm={6}>
              <TextField
                fullWidth
                size="small"
                select
                label="Remittance Method"
                value={paymentMethod}
                onChange={(e) => setPaymentMethod(e.target.value)}
              >
                <MenuItem value="kbz_pay">KBZPay</MenuItem>
                <MenuItem value="wave_pay">WavePay</MenuItem>
                <MenuItem value="bank_transfer">KBZ / AYA / CB Bank Transfer</MenuItem>
              </TextField>
            </Grid>

            <Grid item xs={12} sm={6}>
              <TextField
                fullWidth
                size="small"
                label="Transaction ID / Ref #"
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
            Cancel
          </Button>
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
