import React, { useState } from 'react';
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
import ReceiptLongIcon from '@mui/icons-material/ReceiptLong';
import AutoAwesomeIcon from '@mui/icons-material/AutoAwesome';
import LogoutIcon from '@mui/icons-material/Logout';
import StorefrontIcon from '@mui/icons-material/Storefront';
import SecurityIcon from '@mui/icons-material/Security';
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
  { title: 'Global Platform Users', path: '/admin/users', icon: <PeopleIcon fontSize="small" /> },
  { title: 'Usage Analytics', path: '/admin/analytics', icon: <AssessmentIcon fontSize="small" /> },
  { title: 'Platform Audit Logs', path: '/admin/audit-logs', icon: <ReceiptLongIcon fontSize="small" /> },
  { title: 'Automations & Crons', path: '/admin/automations', icon: <AutoAwesomeIcon fontSize="small" /> },
];

export const AdminLayout: React.FC = () => {
  const theme = useTheme();
  const isMobile = useMediaQuery(theme.breakpoints.down('md'));
  const [sidebarOpen, setSidebarOpen] = useState(!isMobile);
  const [anchorEl, setAnchorEl] = useState<null | HTMLElement>(null);

  const location = useLocation();
  const navigate = useNavigate();
  const { user, profile, loading, signOut } = useAuth();

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
          Platform Administrator Access Required
        </Typography>
        <Typography variant="body2" sx={{ color: '#94a3b8', maxWidth: 460, mb: 3 }}>
          Your current account ({user.email}) does not possess master platform privileges. You can return to your wholesale shop workspace.
        </Typography>
        <Button
          variant="contained"
          onClick={() => navigate('/app/dashboard')}
          startIcon={<StorefrontIcon />}
          sx={{ borderRadius: 2, px: 3, py: 1.2, fontWeight: 700, bgcolor: '#0284c7' }}
        >
          Return to Shop Dashboard
        </Button>
      </Box>
    );
  }

  const drawerContent = (
    <Box sx={{ width: 260, display: 'flex', flexDirection: 'column', height: '100%', py: 1, bgcolor: '#0f172a', color: '#f8fafc' }}>
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
          Switch to Shop View
        </Button>
        <Typography variant="caption" sx={{ display: 'block', color: '#475569', mt: 1.5, fontSize: 11, textAlign: 'center' }}>
          ShopFlow Platform Engine v1.0
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
        <Toolbar sx={{ justifyContent: 'space-between', minHeight: 64 }}>
          <Box sx={{ display: 'flex', alignItems: 'center', gap: 1.5 }}>
            <IconButton edge="start" color="inherit" onClick={handleToggleSidebar} sx={{ mr: 1 }}>
              <MenuIcon />
            </IconButton>

            <Box
              sx={{ display: 'flex', alignItems: 'center', gap: 1, cursor: 'pointer' }}
              onClick={() => navigate('/admin/organizations')}
            >
              <AdminPanelSettingsIcon sx={{ color: '#ef4444', fontSize: 30 }} />
              <div>
                <Typography variant="h6" sx={{ fontWeight: 800, color: '#ffffff', lineHeight: 1.2 }}>
                  ShopFlow Master Admin
                </Typography>
                <Typography variant="caption" sx={{ color: '#94a3b8', fontSize: 11 }}>
                  Cross-Tenant Cloud Governance
                </Typography>
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
            <Button
              variant="text"
              size="small"
              startIcon={<StorefrontIcon />}
              onClick={() => navigate('/app/dashboard')}
              sx={{ color: '#94a3b8', fontSize: 12, display: { xs: 'none', sm: 'inline-flex' } }}
            >
              Tenant View
            </Button>

            {/* Admin Avatar & Dropdown */}
            <IconButton onClick={handleMenuOpen} size="small">
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
                  {profile?.full_name || 'Super Administrator'}
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

              <MenuItem onClick={() => { handleMenuClose(); navigate('/app/dashboard'); }} sx={{ color: '#f8fafc', fontSize: 13 }}>
                <ListItemIcon sx={{ color: '#38bdf8' }}>
                  <StorefrontIcon fontSize="small" />
                </ListItemIcon>
                Switch to Shop App
              </MenuItem>

              <Divider sx={{ borderColor: '#1e293b' }} />

              <MenuItem onClick={handleSignOut} sx={{ color: '#f87171', fontSize: 13 }}>
                <ListItemIcon sx={{ color: '#ef4444' }}>
                  <LogoutIcon fontSize="small" />
                </ListItemIcon>
                Sign Out of Admin
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
            PaperProps={{ sx: { bgcolor: '#0f172a', borderRight: '1px solid #1e293b' } }}
          >
            {drawerContent}
          </Drawer>
        ) : (
          <Drawer
            variant="persistent"
            open={sidebarOpen}
            PaperProps={{
              sx: {
                width: 260,
                bgcolor: '#0f172a',
                borderRight: '1px solid #1e293b',
                top: 64,
                height: 'calc(100% - 64px)',
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
            p: { xs: 2, sm: 3, md: 4 },
            ml: !isMobile && sidebarOpen ? '260px' : 0,
            transition: theme.transitions.create(['margin', 'width'], {
              easing: theme.transitions.easing.sharp,
              duration: theme.transitions.duration.leavingScreen,
            }),
            minHeight: 'calc(100vh - 64px)',
            maxWidth: '100%',
            overflowX: 'hidden',
          }}
        >
          <Outlet />
        </Box>
      </Box>
    </Box>
  );
};
