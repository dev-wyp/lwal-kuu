import React, { useState } from 'react';
import {
  Box,
  Typography,
  TextField,
  Button,
  Alert,
  Link as MuiLink,
  InputAdornment,
  IconButton,
  CircularProgress,
} from '@mui/material';
import Visibility from '@mui/icons-material/Visibility';
import VisibilityOff from '@mui/icons-material/VisibilityOff';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import * as z from 'zod';
import { Link, useNavigate, useSearchParams } from 'react-router-dom';
import { supabase } from '@/lib/supabase';
import { useNotification } from '@/context/NotificationContext';
import { captureAttributionFromSearch } from '@/modules/marketing/lib/utm';
import { useI18n } from '@/i18n/I18nContext';

const registerSchema = z.object({
  fullName: z.string().min(2, 'Name must be at least 2 characters'),
  phone: z.string().optional(),
  email: z.string().email('Please enter a valid email address'),
  password: z.string().min(6, 'Password must be at least 6 characters'),
});

type RegisterFormData = z.infer<typeof registerSchema>;

export const RegisterPage: React.FC = () => {
  const [showPassword, setShowPassword] = useState(false);
  const [loading, setLoading] = useState(false);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);
  const [searchParams] = useSearchParams();
  const navigate = useNavigate();
  const { showSuccess } = useNotification();
  const { t } = useI18n();

  const selectedPlan = searchParams.get('plan') || 'starter';

  React.useEffect(() => {
    captureAttributionFromSearch(window.location.search);
  }, []);

  const {
    register,
    handleSubmit,
    formState: { errors },
  } = useForm<RegisterFormData>({
    resolver: zodResolver(registerSchema),
  });

  const onSubmit = async (data: RegisterFormData) => {
    try {
      setLoading(true);
      setErrorMsg(null);

      const { data: authData, error } = await supabase.auth.signUp({
        email: data.email,
        password: data.password,
        options: {
          data: {
            full_name: data.fullName,
            phone_number: data.phone || '',
          },
        },
      });

      if (error) {
        setErrorMsg(error.message);
        return;
      }

      if (authData.user) {
        showSuccess(t('Account created! Now create your shop organization.'));
        navigate(`/onboarding?plan=${selectedPlan}`);
      }
    } catch (err: unknown) {
      const message = err instanceof Error ? t(err.message) : t('An unexpected error occurred');
      setErrorMsg(message);
    } finally {
      setLoading(false);
    }
  };

  return (
    <Box component="form" onSubmit={handleSubmit(onSubmit)} noValidate>
      <Typography variant="h5" sx={{ fontWeight: 800, mb: 0.5, color: '#0f172a' }}>
        {t('Create Your Account')}
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
        {t('Start your 14-day free trial on the')} {selectedPlan.toUpperCase()} {t('plan.')}
      </Typography>

      {errorMsg && (
        <Alert severity="error" sx={{ mb: 2.5, borderRadius: 2 }}>
          {errorMsg}
        </Alert>
      )}

      <TextField
        fullWidth
        label={t('Full Name')}
        margin="normal"
        size="small"
        autoFocus
        {...register('fullName')}
        error={Boolean(errors.fullName)}
        helperText={errors.fullName?.message ? t(errors.fullName.message) : undefined}
      />

      <TextField
        fullWidth
        label={t('Phone Number (e.g. 09123456789)')}
        margin="normal"
        size="small"
        {...register('phone')}
        error={Boolean(errors.phone)}
        helperText={errors.phone?.message ? t(errors.phone.message) : undefined}
      />

      <TextField
        fullWidth
        label={t('Email Address')}
        type="email"
        margin="normal"
        size="small"
        autoComplete="email"
        {...register('email')}
        error={Boolean(errors.email)}
        helperText={errors.email?.message ? t(errors.email.message) : undefined}
      />

      <TextField
        fullWidth
        label={t('Password')}
        type={showPassword ? 'text' : 'password'}
        margin="normal"
        size="small"
        autoComplete="new-password"
        {...register('password')}
        error={Boolean(errors.password)}
        helperText={errors.password?.message ? t(errors.password.message) : undefined}
        InputProps={{
          endAdornment: (
            <InputAdornment position="end">
              <IconButton
                aria-label={t('toggle password visibility')}
                onClick={() => setShowPassword(!showPassword)}
                edge="end"
                size="small"
              >
                {showPassword ? <VisibilityOff fontSize="small" /> : <Visibility fontSize="small" />}
              </IconButton>
            </InputAdornment>
          ),
        }}
      />

      <Button
        type="submit"
        fullWidth
        variant="contained"
        size="large"
        disabled={loading}
        sx={{
          mt: 2.5,
          mb: 3,
          py: 1.2,
          borderRadius: 2,
          fontWeight: 700,
          bgcolor: '#0284c7',
          '&:hover': { bgcolor: '#0369a1' },
        }}
      >
        {loading ? <CircularProgress size={24} sx={{ color: '#ffffff' }} /> : t('Continue to Organization Setup')}
      </Button>

      <Box sx={{ textAlign: 'center' }}>
        <Typography variant="body2" color="text.secondary">
          {t('Already registered?')}{' '}
          <MuiLink component={Link} to="/login" sx={{ fontWeight: 600, color: '#0284c7' }}>
            {t('Sign In')}
          </MuiLink>
        </Typography>
      </Box>
    </Box>
  );
};

