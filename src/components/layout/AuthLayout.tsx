import React from 'react';
import { Box, Paper, Typography } from '@mui/material';
import StorefrontIcon from '@mui/icons-material/Storefront';
import { Outlet, Link } from 'react-router-dom';
import { LanguageSwitcher } from '@/i18n/LanguageSwitcher';
import { useI18n } from '@/i18n/I18nContext';

export const AuthLayout: React.FC = () => {
  const { t } = useI18n();
  return (
    <Box
      sx={{
        minHeight: '100vh',
        display: 'flex',
        flexDirection: 'column',
        justifyContent: 'center',
        alignItems: 'center',
        bgcolor: '#f1f5f9',
        p: 2,
      }}
    >
      <Box sx={{ position: 'absolute', right: 20, top: 20 }}><LanguageSwitcher /></Box>
      <Box
        component={Link}
        to="/"
        sx={{
          display: 'flex',
          alignItems: 'center',
          gap: 1.5,
          mb: 3,
          textDecoration: 'none',
        }}
      >
        <StorefrontIcon sx={{ fontSize: 36, color: '#0284c7' }} />
        <Typography variant="h4" sx={{ fontWeight: 800, color: '#0f172a', letterSpacing: '-0.03em' }}>
          ShopFlow
        </Typography>
      </Box>

      <Paper
        elevation={0}
        sx={{
          width: '100%',
          maxWidth: 440,
          p: { xs: 3, sm: 4 },
          borderRadius: 3,
          border: '1px solid #e2e8f0',
          boxShadow: '0 4px 20px -2px rgba(0, 0, 0, 0.05)',
          bgcolor: '#ffffff',
        }}
      >
        <Outlet />
      </Paper>

      <Typography variant="body2" color="text.secondary" sx={{ mt: 3, textAlign: 'center' }}>
        &copy; {new Date().getFullYear()} ShopFlow Cloud SaaS. {t('All rights reserved.')}
      </Typography>
    </Box>
  );
};

