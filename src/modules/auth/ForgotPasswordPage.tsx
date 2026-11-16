import React, { useState } from 'react';
import {
  Box,
  Typography,
  TextField,
  Button,
  Alert,
  Link as MuiLink,
  CircularProgress,
} from '@mui/material';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import * as z from 'zod';
import { Link } from 'react-router-dom';
import { supabase } from '@/lib/supabase';
import { useI18n } from '@/i18n/I18nContext';

const forgotPasswordSchema = z.object({
  email: z.string().email('Please enter a valid email address'),
});

type ForgotPasswordFormData = z.infer<typeof forgotPasswordSchema>;

export const ForgotPasswordPage: React.FC = () => {
  const { t } = useI18n();
  const [loading, setLoading] = useState(false);
  const [successMsg, setSuccessMsg] = useState<string | null>(null);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);

  const {
    register,
    handleSubmit,
    formState: { errors },
  } = useForm<ForgotPasswordFormData>({
    resolver: zodResolver(forgotPasswordSchema),
  });

  const onSubmit = async (data: ForgotPasswordFormData) => {
    try {
      setLoading(true);
      setErrorMsg(null);
      setSuccessMsg(null);

      const { error } = await supabase.auth.resetPasswordForEmail(data.email, {
        redirectTo: `${window.location.origin}/login`,
      });

      if (error) {
        setErrorMsg(error.message);
        return;
      }

      setSuccessMsg(t('Password reset instructions have been sent to your email.'));
    } catch (err: unknown) {
      const message = err instanceof Error ? t(err.message) : t('An error occurred');
      setErrorMsg(message);
    } finally {
      setLoading(false);
    }
  };

  return (
    <Box component="form" onSubmit={handleSubmit(onSubmit)} noValidate>
      <Typography variant="h5" sx={{ fontWeight: 800, mb: 0.5, color: '#0f172a' }}>
        {t('Reset Your Password')}
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
        {t('Enter your registered email address to receive password reset instructions.')}
      </Typography>

      {errorMsg && (
        <Alert severity="error" sx={{ mb: 2.5, borderRadius: 2 }}>
          {errorMsg}
        </Alert>
      )}

      {successMsg && (
        <Alert severity="success" sx={{ mb: 2.5, borderRadius: 2 }}>
          {successMsg}
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

      <Button
        type="submit"
        fullWidth
        variant="contained"
        size="large"
        disabled={loading}
        sx={{
          mt: 2,
          mb: 3,
          py: 1.2,
          borderRadius: 2,
          fontWeight: 700,
          bgcolor: '#0f172a',
        }}
      >
        {loading ? <CircularProgress size={24} sx={{ color: '#ffffff' }} /> : t('Send Reset Link')}
      </Button>

      <Box sx={{ textAlign: 'center' }}>
        <MuiLink component={Link} to="/login" variant="body2" sx={{ fontWeight: 600, color: '#0284c7' }}>
          {t('Back to Sign In')}
        </MuiLink>
      </Box>
    </Box>
  );
};

