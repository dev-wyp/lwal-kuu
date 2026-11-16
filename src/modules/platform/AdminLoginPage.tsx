import React, { useState } from 'react';
import {
  Box,
  Typography,
  TextField,
  Button,
  Alert,
  InputAdornment,
  IconButton,
  CircularProgress,
  Paper,
  Chip,
  Divider,
  Link as MuiLink,
} from '@mui/material';
import Visibility from '@mui/icons-material/Visibility';
import VisibilityOff from '@mui/icons-material/VisibilityOff';
import AdminPanelSettingsIcon from '@mui/icons-material/AdminPanelSettings';
import SecurityIcon from '@mui/icons-material/Security';
import StorefrontIcon from '@mui/icons-material/Storefront';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import * as z from 'zod';
import { Link, useNavigate } from 'react-router-dom';
import { supabase } from '@/lib/supabase';
import { useNotification } from '@/context/NotificationContext';
import { useI18n } from "@/i18n/I18nContext";

const adminLoginSchema = z.object({
  email: z.string().email('Please enter a valid administrator email'),
  password: z.string().min(6, 'Password must be at least 6 characters'),
});

type AdminLoginFormData = z.infer<typeof adminLoginSchema>;

export const AdminLoginPage: React.FC = () => {
  const { t } = useI18n();
  const [showPassword, setShowPassword] = useState(false);
  const [loading, setLoading] = useState(false);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);
  const navigate = useNavigate();
  const { showSuccess } = useNotification();

  const {
    register,
    handleSubmit,
    formState: { errors },
  } = useForm<AdminLoginFormData>({
    resolver: zodResolver(adminLoginSchema),
  });

  const onSubmit = async (data: AdminLoginFormData) => {
    try {
      setLoading(true);
      setErrorMsg(null);

      // 1. Authenticate against Supabase Auth
      const { data: authData, error: authError } = await supabase.auth.signInWithPassword({
        email: data.email,
        password: data.password,
      });

      if (authError) {
        setErrorMsg(authError.message);
        return;
      }

      if (!authData.user) {
        setErrorMsg('Authentication failed');
        return;
      }

      // 2. Strict Super-Admin Verification
      const { data: profileData, error: profileError } = await supabase
        .from('profiles')
        .select('is_platform_admin, full_name')
        .eq('id', authData.user.id)
        .single();

      if (profileError || !profileData?.is_platform_admin) {
        // Sign out immediately if not authorized as platform admin
        await supabase.auth.signOut();
        setErrorMsg('Access Denied: This portal is strictly restricted to Lwal Kuu Platform Super-Administrators.');
        return;
      }

      showSuccess(`Welcome Administrator, ${profileData.full_name || 'Admin'}!`);
      navigate('/admin/organizations');
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : 'An unexpected error occurred during admin sign in';
      setErrorMsg(message);
    } finally {
      setLoading(false);
    }
  };

  return (
    <Box
      sx={{
        minHeight: '100vh',
        display: 'flex',
        flexDirection: 'column',
        justifyContent: 'center',
        alignItems: 'center',
        bgcolor: '#090d16',
        p: 2,
      }}
    >
      <Paper
        elevation={0}
        sx={{
          width: '100%',
          maxWidth: 440,
          p: { xs: 3, sm: 4 },
          borderRadius: 3,
          border: '1px solid #1e293b',
          boxShadow: '0 20px 40px -15px rgba(0, 0, 0, 0.7)',
          bgcolor: '#0f172a',
          color: '#f8fafc',
        }}
      >
        {/* Header Badge */}
        <Box sx={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', mb: 2 }}>
          <Box sx={{ display: 'flex', alignItems: 'center', gap: 1 }}>
            <AdminPanelSettingsIcon sx={{ fontSize: 32, color: '#ef4444' }} />
            <Typography variant="h6" sx={{ fontWeight: 800, color: '#ffffff', letterSpacing: '-0.02em' }}>
              Lwal Kuu
            </Typography>
          </Box>
          <Chip
            icon={<SecurityIcon sx={{ fontSize: '14px !important', color: '#ffffff' }} />}
            label="MASTER ADMIN"
            size="small"
            sx={{
              bgcolor: '#dc2626',
              color: '#ffffff',
              fontWeight: 800,
              fontSize: 10,
              letterSpacing: '0.05em',
            }}
          />
        </Box>

        <Typography variant="h5" sx={{ fontWeight: 800, mb: 0.5, color: '#ffffff' }}>
          {t("Platform Control Login")}</Typography>
        <Typography variant="body2" sx={{ color: '#94a3b8', mb: 3 }}>
          {t("Master administrator portal for multi-tenant governance, organization controls, and global audit.")}</Typography>

        {errorMsg && (
          <Alert severity="error" sx={{ mb: 2.5, borderRadius: 2, bgcolor: '#450a0a', color: '#fca5a5' }}>
            {errorMsg}
          </Alert>
        )}

        <Box component="form" onSubmit={handleSubmit(onSubmit)} noValidate>
          <TextField
            fullWidth
            label="Super-Admin Email"
            type="email"
            margin="normal"
            size="small"
            autoComplete="email"
            autoFocus
            {...register('email')}
            error={Boolean(errors.email)}
            helperText={errors.email?.message}
            sx={{
              '& .MuiInputBase-root': { bgcolor: '#1e293b', color: '#ffffff' },
              '& .MuiInputLabel-root': { color: '#94a3b8' },
              '& .MuiOutlinedInput-notchedOutline': { borderColor: '#334155' },
              '&:hover .MuiOutlinedInput-notchedOutline': { borderColor: '#ef4444' },
            }}
          />

          <TextField
            fullWidth
            label="Master Password"
            type={showPassword ? 'text' : 'password'}
            margin="normal"
            size="small"
            autoComplete="current-password"
            {...register('password')}
            error={Boolean(errors.password)}
            helperText={errors.password?.message}
            sx={{
              '& .MuiInputBase-root': { bgcolor: '#1e293b', color: '#ffffff' },
              '& .MuiInputLabel-root': { color: '#94a3b8' },
              '& .MuiOutlinedInput-notchedOutline': { borderColor: '#334155' },
              '&:hover .MuiOutlinedInput-notchedOutline': { borderColor: '#ef4444' },
            }}
            InputProps={{
              endAdornment: (
                <InputAdornment position="end">
                  <IconButton
                    aria-label="toggle password visibility"
                    onClick={() => setShowPassword(!showPassword)}
                    edge="end"
                    size="small"
                    sx={{ color: '#94a3b8' }}
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
              mb: 2.5,
              py: 1.3,
              borderRadius: 2,
              fontWeight: 800,
              bgcolor: '#dc2626',
              '&:hover': { bgcolor: '#b91c1c' },
            }}
          >
            {loading ? <CircularProgress size={24} sx={{ color: '#ffffff' }} /> : 'Authenticate as Super-Admin'}
          </Button>

          <Divider sx={{ my: 2, borderColor: '#334155' }} />

          <Box sx={{ textAlign: 'center' }}>
            <Typography variant="body2" sx={{ color: '#64748b', fontSize: 13 }}>
              {t("Are you a wholesale shop owner or staff member?")}</Typography>
            <MuiLink
              component={Link}
              to="/login"
              sx={{
                display: 'inline-flex',
                alignItems: 'center',
                gap: 0.5,
                mt: 0.8,
                fontWeight: 600,
                color: '#38bdf8',
                textDecoration: 'none',
                fontSize: 13,
                '&:hover': { textDecoration: 'underline' },
              }}
            >
              <StorefrontIcon sx={{ fontSize: 16 }} />
              {t("Go to Regular Shop Login")}</MuiLink>
          </Box>
        </Box>
      </Paper>

      <Typography variant="caption" sx={{ mt: 3, color: '#475569', textAlign: 'center' }}>
        Protected by Role-Based Security &bull; Lwal Kuu Cloud Infrastructure
      </Typography>
    </Box>
  );
};

