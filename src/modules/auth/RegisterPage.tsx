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

  const selectedPlan = searchParams.get('plan') || 'starter';

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
        showSuccess('Account created! Now create your shop organization.');
        navigate(`/onboarding?plan=${selectedPlan}`);
      }
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : 'An unexpected error occurred';
      setErrorMsg(message);
    } finally {
      setLoading(false);
    }
  };

  return (
    <Box component="form" onSubmit={handleSubmit(onSubmit)} noValidate>
      <Typography variant="h5" sx={{ fontWeight: 800, mb: 0.5, color: '#0f172a' }}>
        Create Your Account
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
        Start your 14-day free trial on the {selectedPlan.toUpperCase()} plan.
      </Typography>

      {errorMsg && (
        <Alert severity="error" sx={{ mb: 2.5, borderRadius: 2 }}>
          {errorMsg}
        </Alert>
      )}

      <TextField
        fullWidth
        label="Full Name"
        margin="normal"
        size="small"
        autoFocus
        {...register('fullName')}
        error={Boolean(errors.fullName)}
        helperText={errors.fullName?.message}
      />

      <TextField
        fullWidth
        label="Phone Number (e.g. 09123456789)"
        margin="normal"
        size="small"
        {...register('phone')}
        error={Boolean(errors.phone)}
        helperText={errors.phone?.message}
      />

      <TextField
        fullWidth
        label="Email Address"
        type="email"
        margin="normal"
        size="small"
        autoComplete="email"
        {...register('email')}
        error={Boolean(errors.email)}
        helperText={errors.email?.message}
      />

      <TextField
        fullWidth
        label="Password"
        type={showPassword ? 'text' : 'password'}
        margin="normal"
        size="small"
        autoComplete="new-password"
        {...register('password')}
        error={Boolean(errors.password)}
        helperText={errors.password?.message}
        InputProps={{
          endAdornment: (
            <InputAdornment position="end">
              <IconButton
                aria-label="toggle password visibility"
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
        {loading ? <CircularProgress size={24} sx={{ color: '#ffffff' }} /> : 'Continue to Organization Setup'}
      </Button>

      <Box sx={{ textAlign: 'center' }}>
        <Typography variant="body2" color="text.secondary">
          Already registered?{' '}
          <MuiLink component={Link} to="/login" sx={{ fontWeight: 600, color: '#0284c7' }}>
            Sign in
          </MuiLink>
        </Typography>
      </Box>
    </Box>
  );
};

