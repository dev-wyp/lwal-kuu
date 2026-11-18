import React, { useEffect, useRef, useState } from 'react';
import {
  Box,
  AppBar,
  Toolbar,
  Typography,
  IconButton,
  Button,
  Drawer,
  List,
  ListItem,
  ListItemButton,
  ListItemIcon,
  ListItemText,
  Divider,
  Avatar,
  Menu,
  MenuItem,
  Chip,
  CircularProgress,
  useMediaQuery,
  useTheme,
} from '@mui/material';
import MenuIcon from '@mui/icons-material/Menu';
import AdminPanelSettingsIcon from '@mui/icons-material/AdminPanelSettings';
import BusinessIcon from '@mui/icons-material/Business';
import LoyaltyIcon from '@mui/icons-material/Loyalty';
import PeopleIcon from '@mui/icons-material/People';
import AssessmentIcon from '@mui/icons-material/Assessment';
import SupportAgentIcon from '@mui/icons-material/SupportAgent';
import ReceiptLongIcon from '@mui/icons-material/ReceiptLong';
import AutoAwesomeIcon from '@mui/icons-material/AutoAwesome';
import LogoutIcon from '@mui/icons-material/Logout';
import StorefrontIcon from '@mui/icons-material/Storefront';
import SecurityIcon from '@mui/icons-material/Security';
import CampaignIcon from '@mui/icons-material/Campaign';
import TuneIcon from '@mui/icons-material/Tune';
import { LanguageSwitcher } from '@/i18n/LanguageSwitcher';
import { useI18n } from '@/i18n/I18nContext';
import { Outlet, useLocation, useNavigate, Navigate } from 'react-router-dom';
import { useAuth } from '@/context/AuthContext';

interface AdminNavItem {
  title: string;
  path: string;
  icon: React.ReactNode;
}

const adminNavItems: AdminNavItem[] = [
  { title: 'Organizations & Shops', path: '/admin/organizations', icon: <BusinessIcon fontSize="small" /> },
  { title: 'Subscription Approvals', path: '/admin/subscriptions', icon: <LoyaltyIcon fontSize="small" /> },
  { title: 'Plans & Features', path: '/admin/plans', icon: <TuneIcon fontSize="small" /> },
  { title: 'Global Platform Users', path: '/admin/users', icon: <PeopleIcon fontSize="small" /> },
  { title: 'Usage Analytics', path: '/admin/analytics', icon: <AssessmentIcon fontSize="small" /> },
  { title: 'Priority Support', path: '/admin/support', icon: <SupportAgentIcon fontSize="small" /> },
  { title: 'Platform Audit Logs', path: '/admin/audit-logs', icon: <ReceiptLongIcon fontSize="small" /> },
  { title: 'Automations & Crons', path: '/admin/automations', icon: <AutoAwesomeIcon fontSize="small" /> },
  { title: 'Lwal Kuu Marketing', path: '/admin/marketing', icon: <CampaignIcon fontSize="small" /> },
];

export const AdminLayout: React.FC = () => {
  const theme = useTheme();
  const isMobile = useMediaQuery(theme.breakpoints.down('md'));
  const [sidebarOpen, setSidebarOpen] = useState(!isMobile);
  const previousMobile = useRef(isMobile);
  const [anchorEl, setAnchorEl] = useState<null | HTMLElement>(null);

  const location = useLocation();
  const navigate = useNavigate();
  const { t } = useI18n();
  const { user, profile, loading, signOut } = useAuth();

  useEffect(() => {
    if (previousMobile.current !== isMobile) {
      setSidebarOpen(!isMobile);
      previousMobile.current = isMobile;
    }
  }, [isMobile]);

  const handleToggleSidebar = () => {
    setSidebarOpen(!sidebarOpen);
  };

  const handleMenuOpen = (event: React.MouseEvent<HTMLElement>) => {
    setAnchorEl(event.currentTarget);
  };

  const handleMenuClose = () => {
    setAnchorEl(null);
  };

  const handleSignOut = async () => {
    handleMenuClose();
    await signOut();
    navigate('/admin/login');
  };

  const handleNavClick = (path: string) => {
    navigate(path);
    if (isMobile) {
      setSidebarOpen(false);
    }
  };

  if (loading) {
    return (
      <Box sx={{ display: 'flex', height: '100vh', alignItems: 'center', justifyContent: 'center', bgcolor: '#0f172a' }}>
        <CircularProgress size={40} thickness={4} sx={{ color: '#ef4444' }} />
      </Box>
    );
  }

  // Not logged in -> Redirect to admin login
  if (!user) {
    return <Navigate to="/admin/login" replace />;
  }

  // Logged in but not a platform superadmin -> Block with clear alert
  if (!profile?.is_platform_admin) {
    return (
      <Box
        sx={{
          minHeight: '100vh',
          display: 'flex',
          flexDirection: 'column',
          alignItems: 'center',
          justifyContent: 'center',
          bgcolor: '#090d16',
          p: 3,
          textAlign: 'center',
        }}
      >
        <SecurityIcon sx={{ fontSize: 64, color: '#ef4444', mb: 2 }} />
        <Typography variant="h5" sx={{ fontWeight: 800, color: '#ffffff', mb: 1 }}>
          {t("Platform Administrator Access Required")}</Typography>
        <Typography variant="body2" sx={{ color: '#94a3b8', maxWidth: 460, mb: 3 }}>
          Your current account ({user.email}) does not possess master platform privileges. You can return to your wholesale shop workspace.
        </Typography>
        <Button
          variant="contained"
          onClick={() => navigate('/app/dashboard')}
          startIcon={<StorefrontIcon />}
          sx={{ borderRadius: 2, px: 3, py: 1.2, fontWeight: 700, bgcolor: '#0284c7' }}
        >
          {t("Return to Shop Dashboard")}</Button>
      </Box>
    );
  }

  const drawerContent = (
    <Box sx={{ width: 272, display: 'flex', flexDirection: 'column', height: '100%', py: 1, bgcolor: '#0f172a', color: '#f8fafc', overflowY: 'auto' }}>
      <Box sx={{ px: 2, py: 1.5, display: 'flex', alignItems: 'center', gap: 1 }}>
        <Chip
          label="MASTER GOVERNANCE"
          size="small"
          sx={{ bgcolor: '#7f1d1d', color: '#fca5a5', fontWeight: 800, fontSize: 10, letterSpacing: '0.05em' }}
        />
      </Box>

      <List dense sx={{ px: 1 }}>
        {adminNavItems.map((item) => {
          const isActive = location.pathname.startsWith(item.path);
          return (
            <ListItem key={item.path} disablePadding sx={{ mb: 0.5 }}>
              <ListItemButton
                onClick={() => handleNavClick(item.path)}
                selected={isActive}
                sx={{
                  borderRadius: 2,
                  py: 1,
                  px: 1.5,
                  color: isActive ? '#ffffff' : '#94a3b8',
                  '&.Mui-selected': {
                    bgcolor: '#dc2626',
                    color: '#ffffff',
                    '&:hover': { bgcolor: '#b91c1c' },
                    '& .MuiListItemIcon-root': { color: '#ffffff' },
                  },
                  '&:hover': {
                    bgcolor: '#1e293b',
                    color: '#ffffff',
                  },
                }}
              >
                <ListItemIcon sx={{ minWidth: 34, color: isActive ? '#ffffff' : '#ef4444' }}>
                  {item.icon}
                </ListItemIcon>
                <ListItemText
                  primary={item.title}
                  primaryTypographyProps={{
                    fontSize: 13,
                    fontWeight: isActive ? 700 : 500,
                  }}
                />
              </ListItemButton>
            </ListItem>
          );
        })}
      </List>

      <Box sx={{ mt: 'auto', p: 2, borderTop: '1px solid #1e293b' }}>
        <Button
          fullWidth
          variant="outlined"
          size="small"
          startIcon={<StorefrontIcon />}
          onClick={() => navigate('/app/dashboard')}
          sx={{
            color: '#38bdf8',
            borderColor: '#0284c7',
            borderRadius: 2,
            fontSize: 12,
            fontWeight: 700,
            py: 0.8,
            '&:hover': { borderColor: '#38bdf8', bgcolor: 'rgba(2, 132, 199, 0.1)' },
          }}
        >
          {t("Switch to Shop View")}</Button>
        <Typography variant="caption" sx={{ display: 'block', color: '#475569', mt: 1.5, fontSize: 11, textAlign: 'center' }}>
          Lwal Kuu Platform Engine v1.0
        </Typography>
      </Box>
    </Box>
  );

  return (
    <Box sx={{ display: 'flex', flexDirection: 'column', minHeight: '100vh', bgcolor: '#f8fafc' }}>
      {/* Superadmin Top Navbar */}
      <AppBar
        position="sticky"
        sx={{
          bgcolor: '#090d16',
          color: '#ffffff',
          borderBottom: '1px solid #1e293b',
          boxShadow: 'none',
          zIndex: (theme) => theme.zIndex.drawer + 1,
        }}
      >
        <Toolbar sx={{ justifyContent: 'space-between', minHeight: { xs: 58, sm: 68 }, px: { xs: 1, sm: 2.5 } }}>
          <Box sx={{ display: 'flex', alignItems: 'center', gap: 1.5 }}>
            <IconButton edge="start" color="inherit" onClick={handleToggleSidebar} aria-label={t('Open navigation menu')} sx={{ mr: { xs: 0, sm: 0.5 } }}>
              <MenuIcon />
            </IconButton>

            <Box
              sx={{ display: 'flex', alignItems: 'center', gap: 1, cursor: 'pointer', minWidth: 0 }}
              onClick={() => navigate('/admin/organizations')}
            >
              <AdminPanelSettingsIcon sx={{ color: '#ef4444', fontSize: { xs: 26, sm: 30 }, flexShrink: 0 }} />
              <div>
                <Typography variant="h6" sx={{ fontWeight: 800, color: '#ffffff', lineHeight: 1.2, fontSize: { xs: 14, sm: 18 }, whiteSpace: 'nowrap' }}>
                  {t("Lwal Kuu Master Admin")}</Typography>
                <Typography variant="caption" sx={{ color: '#94a3b8', fontSize: 11, display: { xs: 'none', sm: 'block' } }}>
                  {t("Cross-Tenant Cloud Governance")}</Typography>
              </div>
            </Box>

            <Chip
              label="CLUSTER ONLINE"
              size="small"
              sx={{
                ml: 2,
                bgcolor: '#064e3b',
                color: '#6ee7b7',
                fontWeight: 700,
                fontSize: 10,
                height: 20,
                display: { xs: 'none', md: 'inline-flex' },
              }}
            />
          </Box>

          <Box sx={{ display: 'flex', alignItems: 'center', gap: 2 }}>
            <Box sx={{ display: { xs: 'none', sm: 'block' } }}><LanguageSwitcher compact /></Box>
            <Button
              variant="text"
              size="small"
              startIcon={<StorefrontIcon />}
              onClick={() => navigate('/app/dashboard')}
              sx={{ color: '#94a3b8', fontSize: 12, display: { xs: 'none', sm: 'inline-flex' } }}
            >
              {t('Tenant View')}
            </Button>

            {/* Admin Avatar & Dropdown */}
            <IconButton onClick={handleMenuOpen} size="small" aria-label={t('Open account menu')}>
              <Avatar sx={{ bgcolor: '#dc2626', width: 34, height: 34, fontSize: 14, fontWeight: 700 }}>
                {profile?.full_name ? profile.full_name[0].toUpperCase() : 'A'}
              </Avatar>
            </IconButton>

            <Menu
              anchorEl={anchorEl}
              open={Boolean(anchorEl)}
              onClose={handleMenuClose}
              transformOrigin={{ horizontal: 'right', vertical: 'top' }}
              anchorOrigin={{ horizontal: 'right', vertical: 'bottom' }}
              PaperProps={{
                sx: { width: 240, borderRadius: 2, mt: 1, bgcolor: '#0f172a', color: '#ffffff', border: '1px solid #1e293b' },
              }}
            >
              <Box sx={{ px: 2, py: 1.5 }}>
                <Typography variant="subtitle2" sx={{ fontWeight: 700, color: '#ffffff' }}>
                  {profile?.full_name || t('Super Administrator')}
                </Typography>
                <Typography variant="caption" sx={{ color: '#94a3b8', display: 'block' }} noWrap>
                  {user?.email}
                </Typography>
                <Chip
                  label="SUPER ADMIN"
                  size="small"
                  sx={{ mt: 0.8, bgcolor: '#dc2626', color: '#ffffff', fontSize: 10, fontWeight: 800, height: 18 }}
                />
              </Box>
              <Divider sx={{ borderColor: '#1e293b' }} />

              <Box sx={{ px: 2, py: 1.25, display: { xs: 'block', sm: 'none' } }}><LanguageSwitcher compact /></Box>

              <MenuItem onClick={() => { handleMenuClose(); navigate('/app/dashboard'); }} sx={{ color: '#f8fafc', fontSize: 13 }}>
                <ListItemIcon sx={{ color: '#38bdf8' }}>
                  <StorefrontIcon fontSize="small" />
                </ListItemIcon>
                {t('Switch to Shop App')}
              </MenuItem>

              <Divider sx={{ borderColor: '#1e293b' }} />

              <MenuItem onClick={handleSignOut} sx={{ color: '#f87171', fontSize: 13 }}>
                <ListItemIcon sx={{ color: '#ef4444' }}>
                  <LogoutIcon fontSize="small" />
                </ListItemIcon>
                {t('Sign Out of Admin')}
              </MenuItem>
            </Menu>
          </Box>
        </Toolbar>
      </AppBar>

      {/* Main Container */}
      <Box sx={{ display: 'flex', flexGrow: 1, position: 'relative' }}>
        {isMobile ? (
          <Drawer
            variant="temporary"
            open={sidebarOpen}
            onClose={() => setSidebarOpen(false)}
            ModalProps={{ keepMounted: true }}
            PaperProps={{ sx: { bgcolor: '#0f172a', borderRight: '1px solid #1e293b', width: 272 } }}
          >
            {drawerContent}
          </Drawer>
        ) : (
          <Drawer
            variant="persistent"
            open={sidebarOpen}
            PaperProps={{
              sx: {
                width: 272,
                bgcolor: '#0f172a',
                borderRight: '1px solid #1e293b',
                top: 68,
                height: 'calc(100% - 68px)',
              },
            }}
          >
            {drawerContent}
          </Drawer>
        )}

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
          <Box sx={{ width: '100%', maxWidth: 1600, mx: 'auto' }}><Outlet /></Box>
        </Box>
      </Box>
    </Box>
  );
};
