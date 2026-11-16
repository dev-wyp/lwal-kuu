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
import { Link, useNavigate } from 'react-router-dom';
import { supabase } from '@/lib/supabase';
import { useNotification } from '@/context/NotificationContext';
import { useI18n } from '@/i18n/I18nContext';

const loginSchema = z.object({
  email: z.string().email('Please enter a valid email address'),
  password: z.string().min(6, 'Password must be at least 6 characters'),
});

type LoginFormData = z.infer<typeof loginSchema>;

export const LoginPage: React.FC = () => {
  const [showPassword, setShowPassword] = useState(false);
  const [loading, setLoading] = useState(false);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);
  const navigate = useNavigate();
  const { showSuccess } = useNotification();
  const { t } = useI18n();

  const {
    register,
    handleSubmit,
    formState: { errors },
  } = useForm<LoginFormData>({
    resolver: zodResolver(loginSchema),
  });

  const onSubmit = async (data: LoginFormData) => {
    try {
      setLoading(true);
      setErrorMsg(null);

      const { data: authData, error } = await supabase.auth.signInWithPassword({
        email: data.email,
        password: data.password,
      });

      if (error) {
        setErrorMsg(error.message);
        return;
      }

      if (authData.user) {
        showSuccess(t('Welcome back!'));
        navigate('/app/dashboard');
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
        {t('Sign In to Lwal Kuu')}
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
        {t('Access your wholesale shop, sales register, and inventory ledger.')}
      </Typography>

      {errorMsg && (
        <Alert severity="error" sx={{ mb: 2.5, borderRadius: 2 }}>
          {errorMsg}
        </Alert>
      )}

      <TextField
        fullWidth
        label={t('Email Address')}
        type="email"
        margin="normal"
        size="small"
        autoComplete="email"
        autoFocus
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
        autoComplete="current-password"
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

      <Box sx={{ display: 'flex', justifyContent: 'flex-end', mt: 1, mb: 2 }}>
        <MuiLink component={Link} to="/forgot-password" variant="caption" sx={{ fontWeight: 600, color: '#0284c7' }}>
          {t('Forgot password?')}
        </MuiLink>
      </Box>

      <Button
        type="submit"
        fullWidth
        variant="contained"
        size="large"
        disabled={loading}
        sx={{
          mt: 1,
          mb: 3,
          py: 1.2,
          borderRadius: 2,
          fontWeight: 700,
          bgcolor: '#0f172a',
        }}
      >
        {loading ? <CircularProgress size={24} sx={{ color: '#ffffff' }} /> : t('Sign In')}
      </Button>

      <Box sx={{ textAlign: 'center' }}>
        <Typography variant="body2" color="text.secondary">
          {t('Don\'t have an account yet?')}{' '}
          <MuiLink component={Link} to="/register" sx={{ fontWeight: 600, color: '#0284c7' }}>
            {t('Start Free Trial')}
          </MuiLink>
        </Typography>

        <Box sx={{ mt: 2, pt: 2, borderTop: '1px solid #f1f5f9' }}>
          <MuiLink component={Link} to="/admin/login" variant="caption" sx={{ color: '#94a3b8', textDecoration: 'none', '&:hover': { color: '#dc2626', textDecoration: 'underline' } }}>
            {t('Platform Administrator? Access Super-Admin Portal →')}
          </MuiLink>
        </Box>
      </Box>
    </Box>
  );
};

