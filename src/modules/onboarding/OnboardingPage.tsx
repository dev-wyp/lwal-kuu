import React, { useState } from 'react';
import {
  Box,
  Typography,
  TextField,
  Button,
  Alert,
  CircularProgress,
  Paper,
  Container,
  Grid,
} from '@mui/material';
import StorefrontIcon from '@mui/icons-material/Storefront';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import * as z from 'zod';
import { useNavigate, useSearchParams } from 'react-router-dom';
import { supabase } from '@/lib/supabase';
import { useAuth } from '@/context/AuthContext';
import { useOrg } from '@/context/OrgContext';
import { useNotification } from '@/context/NotificationContext';

const onboardingSchema = z.object({
  name: z.string().min(2, 'Shop name must be at least 2 characters'),
  slug: z.string().min(2, 'Identifier must be at least 2 characters').regex(/^[a-z0-9-]+$/, 'Lowercase letters, numbers, and hyphens only'),
  phone: z.string().optional(),
  address: z.string().optional(),
});

type OnboardingFormData = z.infer<typeof onboardingSchema>;

export const OnboardingPage: React.FC = () => {
  const { user } = useAuth();
  const { refreshOrgs } = useOrg();
  const { showSuccess } = useNotification();
  const [searchParams] = useSearchParams();
  const navigate = useNavigate();

  const [loading, setLoading] = useState(false);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);

  const selectedPlan = searchParams.get('plan') || 'starter';

  const {
    register,
    handleSubmit,
    setValue,
    formState: { errors },
  } = useForm<OnboardingFormData>({
    resolver: zodResolver(onboardingSchema),
    defaultValues: {
      name: '',
      slug: '',
    },
  });

  const handleNameChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const val = e.target.value;
    setValue('name', val);
    const generatedSlug = val
      .toLowerCase()
      .trim()
      .replace(/[^a-z0-9]+/g, '-')
      .replace(/^-+|-+$/g, '');
    setValue('slug', generatedSlug);
  };

  const onSubmit = async (data: OnboardingFormData) => {
    if (!user) {
      navigate('/login');
      return;
    }

    try {
      setLoading(true);
      setErrorMsg(null);

      // 1. Create Organization
      const { data: orgData, error: orgError } = await supabase
        .from('organizations')
        .insert({
          name: data.name,
          slug: data.slug,
        })
        .select()
        .single();

      if (orgError) {
        throw new Error(orgError.message);
      }

      // 2. Add User as Owner
      const { error: memberError } = await supabase
        .from('organization_members')
        .insert({
          organization_id: orgData.id,
          user_id: user.id,
          role: 'owner',
        });

      if (memberError) {
        throw new Error(memberError.message);
      }

      // 3. Create Default Organization Settings (MMK, Asia/Yangon, weighted average costing)
      await supabase
        .from('organization_settings')
        .insert({
          organization_id: orgData.id,
          currency_code: 'MMK',
          currency_symbol: 'Ks',
          timezone: 'Asia/Yangon',
          phone: data.phone || null,
          address: data.address || null,
          costing_method: 'weighted_average',
          low_stock_threshold_default: 5,
        });

      // 4. Initialize 14-day Free Trial
      await supabase.rpc('initialize_organization_trial', {
        p_org_id: orgData.id,
        p_plan_id: selectedPlan,
      });

      // 5. Seed baseline measurement units (Pcs, Box, Pack, Carton, Dozen)
      await supabase.from('units').insert([
        { organization_id: orgData.id, code: 'pcs', name: 'Pieces (ခု)', precision: 0 },
        { organization_id: orgData.id, code: 'box', name: 'Box (ဖာ)', precision: 0 },
        { organization_id: orgData.id, code: 'pack', name: 'Packet (ထုပ်)', precision: 0 },
        { organization_id: orgData.id, code: 'dozen', name: 'Dozen (ဒါဇင်)', precision: 0 },
      ]);

      showSuccess(`Organization "${orgData.name}" created! Your 14-day trial is active.`);
      localStorage.setItem('shopflow_active_org_id', orgData.id);
      await refreshOrgs();
      navigate('/app/dashboard');
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : 'Failed to create organization';
      setErrorMsg(message);
    } finally {
      setLoading(false);
    }
  };

  return (
    <Container maxWidth="sm" sx={{ py: 6 }}>
      <Paper elevation={0} sx={{ p: { xs: 3, sm: 5 }, borderRadius: 3, border: '1px solid #e2e8f0', bgcolor: '#ffffff' }}>
        <Box sx={{ display: 'flex', alignItems: 'center', gap: 1.5, mb: 1 }}>
          <StorefrontIcon sx={{ fontSize: 32, color: '#0284c7' }} />
          <Typography variant="h5" sx={{ fontWeight: 800 }}>
            Set Up Your Shop Organization
          </Typography>
        </Box>
        <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
          Enter your wholesale shop details to initialize your inventory ledger, accounting defaults, and free trial.
        </Typography>

        {errorMsg && (
          <Alert severity="error" sx={{ mb: 3, borderRadius: 2 }}>
            {errorMsg}
          </Alert>
        )}

        <Box component="form" onSubmit={handleSubmit(onSubmit)} noValidate>
          <Grid container spacing={2}>
            <Grid item xs={12}>
              <TextField
                fullWidth
                label="Shop / Business Name"
                placeholder="e.g. Shwe Thiri Wholesale"
                size="small"
                autoFocus
                {...register('name')}
                onChange={handleNameChange}
                error={Boolean(errors.name)}
                helperText={errors.name?.message}
              />
            </Grid>

            <Grid item xs={12}>
              <TextField
                fullWidth
                label="Shop URL Slug (Identifier)"
                placeholder="e.g. shwe-thiri"
                size="small"
                {...register('slug')}
                error={Boolean(errors.slug)}
                helperText={errors.slug?.message || 'Unique identifier for your business'}
              />
            </Grid>

            <Grid item xs={12} sm={6}>
              <TextField
                fullWidth
                label="Phone Number"
                placeholder="09123456789"
                size="small"
                {...register('phone')}
              />
            </Grid>

            <Grid item xs={12} sm={6}>
              <TextField
                fullWidth
                label="Default Currency & Timezone"
                value="MMK (Ks) &bull; Asia/Yangon"
                size="small"
                disabled
              />
            </Grid>

            <Grid item xs={12}>
              <TextField
                fullWidth
                label="Physical Address / Market Location"
                placeholder="e.g. Bayintnaung Wholesale Market, Yangon"
                size="small"
                multiline
                rows={2}
                {...register('address')}
              />
            </Grid>

            <Grid item xs={12}>
              <Button
                type="submit"
                fullWidth
                variant="contained"
                size="large"
                disabled={loading}
                sx={{
                  mt: 1,
                  py: 1.3,
                  borderRadius: 2,
                  fontWeight: 700,
                  bgcolor: '#0f172a',
                }}
              >
                {loading ? <CircularProgress size={24} sx={{ color: '#ffffff' }} /> : 'Launch ShopFlow'}
              </Button>
            </Grid>
          </Grid>
        </Box>
      </Paper>
    </Container>
  );
};

