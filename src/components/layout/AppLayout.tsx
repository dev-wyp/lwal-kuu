import React, { useEffect, useRef, useState } from 'react';
import { Box, useMediaQuery, useTheme, CircularProgress, Typography, Button } from '@mui/material';
import { Outlet, Navigate, useNavigate } from 'react-router-dom';
import { Navbar } from './Navbar';
import { Sidebar } from './Sidebar';
import { useAuth } from '@/context/AuthContext';
import { useOrg } from '@/context/OrgContext';
import AddBusinessIcon from '@mui/icons-material/AddBusiness';
import { useI18n } from '@/i18n/I18nContext';

export const AppLayout: React.FC = () => {
  const { t } = useI18n();
  const theme = useTheme();
  const isMobile = useMediaQuery(theme.breakpoints.down('md'));
  const [sidebarOpen, setSidebarOpen] = useState(!isMobile);
  const previousMobile = useRef(isMobile);
  const { user, profile, loading: authLoading } = useAuth();
  const { currentOrg, loading: orgLoading } = useOrg();
  const navigate = useNavigate();

  useEffect(() => {
    if (previousMobile.current !== isMobile) {
      setSidebarOpen(!isMobile);
      previousMobile.current = isMobile;
    }
  }, [isMobile]);

  const handleToggleSidebar = () => {
    setSidebarOpen(!sidebarOpen);
  };

  if (authLoading || orgLoading) {
    return (
      <Box sx={{ display: 'flex', height: '100vh', alignItems: 'center', justifyContent: 'center', bgcolor: '#f8fafc' }}>
        <CircularProgress size={40} thickness={4} sx={{ color: '#0f172a' }} />
      </Box>
    );
  }

  if (!user) {
    return <Navigate to="/login" replace />;
  }

  // If user has no organizations yet, allow platform superadmin to access /platform routes, otherwise prompt onboarding
  const isPlatformRoute = window.location.pathname.startsWith('/platform');
  if (!currentOrg && window.location.pathname !== '/onboarding' && !(isPlatformRoute && profile?.is_platform_admin)) {
    return (
      <Box
        sx={{
          minHeight: '100vh',
          display: 'flex',
          flexDirection: 'column',
          alignItems: 'center',
          justifyContent: 'center',
          p: 3,
          bgcolor: '#f8fafc',
          textAlign: 'center',
        }}
      >
        <AddBusinessIcon sx={{ fontSize: 64, color: '#0284c7', mb: 2 }} />
        <Typography variant="h5" sx={{ fontWeight: 700, mb: 1 }}>
          {t("Welcome to Lwal Kuu!")}</Typography>
        <Typography variant="body1" color="text.secondary" sx={{ maxWidth: 480, mb: 3 }}>
          You don&apos;t have an active shop or organization yet. Create your organization in 30 seconds and start your 14-day free trial.
        </Typography>
        <Button
          variant="contained"
          size="large"
          onClick={() => navigate('/onboarding')}
          sx={{ borderRadius: 2, px: 4, py: 1.2, fontWeight: 600 }}
        >
          {t("Create Your Organization")}</Button>
      </Box>
    );
  }

  return (
    <Box sx={{ display: 'flex', flexDirection: 'column', minHeight: '100vh', bgcolor: 'background.default' }}>
      <Navbar onToggleSidebar={handleToggleSidebar} />

      <Box sx={{ display: 'flex', flexGrow: 1, position: 'relative' }}>
        <Sidebar open={sidebarOpen} onClose={() => setSidebarOpen(false)} isMobile={isMobile} />

        <Box
          component="main"
          sx={{
            flexGrow: 1,
            p: { xs: 2, sm: 3, lg: 4 },
            ml: !isMobile && sidebarOpen ? '272px' : 0,
            transition: theme.transitions.create(['margin', 'width'], {
              easing: theme.transitions.easing.sharp,
              duration: theme.transitions.duration.leavingScreen,
            }),
            minHeight: 'calc(100vh - 64px)',
            width: '100%',
            maxWidth: '100%',
            overflowX: 'hidden',
          }}
        >
          <Box sx={{ width: '100%', maxWidth: 1600, mx: 'auto' }}>
            <Outlet />
          </Box>
        </Box>
      </Box>
    </Box>
  );
};

