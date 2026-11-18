import React, { useState } from 'react';
import {
  AppBar,
  Toolbar,
  Typography,
  IconButton,
  Box,
  Menu,
  MenuItem,
  Avatar,
  ListItemIcon,
  Divider,
  Button,
  Chip,
  Select,
  FormControl,
  SelectChangeEvent,
  ButtonBase,
} from '@mui/material';
import MenuIcon from '@mui/icons-material/Menu';
import AddShoppingCartIcon from '@mui/icons-material/AddShoppingCart';
import LogoutIcon from '@mui/icons-material/Logout';
import SettingsIcon from '@mui/icons-material/Settings';
import StorefrontIcon from '@mui/icons-material/Storefront';
import AddBusinessIcon from '@mui/icons-material/AddBusiness';
import AdminPanelSettingsIcon from '@mui/icons-material/AdminPanelSettings';
import { useAuth } from '@/context/AuthContext';
import { useOrg } from '@/context/OrgContext';
import { useNavigate } from 'react-router-dom';
import { LanguageSwitcher } from '@/i18n/LanguageSwitcher';
import { useI18n } from '@/i18n/I18nContext';

interface NavbarProps {
  onToggleSidebar: () => void;
}

export const Navbar: React.FC<NavbarProps> = ({ onToggleSidebar }) => {
  const { user, profile, signOut } = useAuth();
  const { currentOrg, organizations, switchOrg, role } = useOrg();
  const navigate = useNavigate();
  const { t } = useI18n();

  const [anchorEl, setAnchorEl] = useState<null | HTMLElement>(null);

  const handleMenuOpen = (event: React.MouseEvent<HTMLElement>) => {
    setAnchorEl(event.currentTarget);
  };

  const handleMenuClose = () => {
    setAnchorEl(null);
  };

  const handleSignOut = async () => {
    handleMenuClose();
    await signOut();
    navigate('/login');
  };

  const handleOrgChange = (event: SelectChangeEvent) => {
    switchOrg(event.target.value);
  };

  return (
    <AppBar
      position="sticky"
      sx={{
        bgcolor: '#ffffff',
        color: '#172b35',
        borderBottom: '1px solid #e3eaec',
        boxShadow: 'none',
        zIndex: (theme) => theme.zIndex.drawer + 1,
      }}
    >
      <Toolbar sx={{ justifyContent: 'space-between', minHeight: { xs: 58, sm: 68 }, px: { xs: 1, sm: 2.5 } }}>
        <Box sx={{ display: 'flex', alignItems: 'center', gap: 2 }}>
          <IconButton edge="start" color="inherit" onClick={onToggleSidebar} aria-label={t('Open navigation menu')} sx={{ mr: { xs: 0, sm: 0.5 } }}>
            <MenuIcon />
          </IconButton>

          <ButtonBase
            sx={{ display: 'flex', alignItems: 'center', gap: 1, cursor: 'pointer' }}
            onClick={() => navigate('/app/dashboard')}
            aria-label={t('Lwal Kuu home')}
          >
            <StorefrontIcon sx={{ color: '#176B5B', fontSize: 28 }} />
            <Typography variant="h6" sx={{ fontWeight: 750, color: '#172B35', fontSize: { xs: 16, sm: 19 } }}>
              Lwal Kuu
            </Typography>
          </ButtonBase>

          {/* Org Selector */}
          {organizations.length > 0 && currentOrg && (
            <FormControl size="small" sx={{ minWidth: 180, ml: 2, display: { xs: 'none', md: 'block' } }}>
              <Select
                value={currentOrg.id}
                onChange={handleOrgChange}
                inputProps={{ 'aria-label': t('Current shop') }}
                sx={{
                  bgcolor: '#f6f9f9',
                  fontSize: 13,
                  fontWeight: 600,
                  borderRadius: 2,
                  '& .MuiOutlinedInput-notchedOutline': { borderColor: '#e3eaec' },
                }}
              >
                {organizations.map((org) => (
                  <MenuItem key={org.id} value={org.id} sx={{ fontSize: 13, fontWeight: 500 }}>
                    {org.name}
                  </MenuItem>
                ))}
              </Select>
            </FormControl>
          )}

          {role && (
            <Chip
              label={t(role)}
              size="small"
              variant="outlined"
              color={role === 'owner' ? 'primary' : 'default'}
              sx={{ display: { xs: 'none', lg: 'inline-flex' }, height: 26, fontSize: 11, fontWeight: 650 }}
            />
          )}
        </Box>

        <Box sx={{ display: 'flex', alignItems: 'center', gap: 1.5 }}>
          {/* Quick Sale Button */}
          <Button
            variant="contained"
            color="secondary"
            size="small"
            startIcon={<AddShoppingCartIcon />}
            onClick={() => navigate('/app/sales')}
            sx={{
              fontWeight: 600,
              bgcolor: '#176B5B',
              borderRadius: 2,
              '&:hover': { bgcolor: '#105246' },
              display: { xs: 'none', sm: 'inline-flex' },
            }}
          >
            {t('New Sale')}
          </Button>

          {/* User Profile Avatar */}
          <IconButton onClick={handleMenuOpen} size="small" aria-label={t('Open account menu')} sx={{ ml: { xs: 0, sm: 0.5 } }}>
            <Avatar sx={{ bgcolor: '#176B5B', width: 36, height: 36, fontSize: 14, fontWeight: 650 }}>
              {profile?.full_name ? profile.full_name[0].toUpperCase() : 'U'}
            </Avatar>
          </IconButton>

          <Menu
            anchorEl={anchorEl}
            open={Boolean(anchorEl)}
            onClose={handleMenuClose}
            transformOrigin={{ horizontal: 'right', vertical: 'top' }}
            anchorOrigin={{ horizontal: 'right', vertical: 'bottom' }}
            PaperProps={{
              sx: { width: 220, borderRadius: 2, mt: 1, boxShadow: '0 4px 20px rgba(0,0,0,0.08)' },
            }}
          >
            <Box sx={{ px: 2, py: 1.5 }}>
              <Typography variant="subtitle2" sx={{ fontWeight: 700 }}>
                {profile?.full_name || t('Lwal Kuu User')}
              </Typography>
              <Typography variant="caption" color="text.secondary" noWrap sx={{ display: 'block' }}>
                {user?.email}
              </Typography>
            </Box>
            <Divider />

            <Box sx={{ px: 2, py: 1.5 }}><LanguageSwitcher compact /></Box>

            <MenuItem
              onClick={() => {
                handleMenuClose();
                navigate('/app/settings');
              }}
            >
              <ListItemIcon>
                <SettingsIcon fontSize="small" />
              </ListItemIcon>
              {t('Org Settings')}
            </MenuItem>

            <MenuItem
              onClick={() => {
                handleMenuClose();
                navigate('/onboarding');
              }}
            >
              <ListItemIcon>
                <AddBusinessIcon fontSize="small" />
              </ListItemIcon>
              {t('New Organization')}
            </MenuItem>

            {profile?.is_platform_admin && (
              <MenuItem
                onClick={() => {
                  handleMenuClose();
                  navigate('/admin/organizations');
                }}
                sx={{ color: '#dc2626', fontWeight: 600 }}
              >
                <ListItemIcon>
                  <AdminPanelSettingsIcon fontSize="small" sx={{ color: '#dc2626' }} />
                </ListItemIcon>
                {t('Super-Admin Portal')}
              </MenuItem>
            )}

            <Divider />
            <MenuItem onClick={handleSignOut} sx={{ color: 'error.main' }}>
              <ListItemIcon>
                <LogoutIcon fontSize="small" color="error" />
              </ListItemIcon>
              {t('Sign Out')}
            </MenuItem>
          </Menu>
        </Box>
      </Toolbar>

      {organizations.length > 0 && currentOrg && (
        <Box sx={{ display: { xs: 'flex', md: 'none' }, alignItems: 'center', gap: 1, px: 2, pb: 1.25 }}>
          <FormControl size="small" fullWidth>
            <Select
              value={currentOrg.id}
              onChange={handleOrgChange}
              inputProps={{ 'aria-label': t('Current shop') }}
              sx={{ bgcolor: '#f6f9f9', fontSize: 13, fontWeight: 600, borderRadius: 2.5, '& .MuiOutlinedInput-notchedOutline': { borderColor: '#e3eaec' } }}
            >
              {organizations.map((org) => <MenuItem key={org.id} value={org.id}>{org.name}</MenuItem>)}
            </Select>
          </FormControl>
          <Button
            variant="contained"
            size="small"
            startIcon={<AddShoppingCartIcon />}
            onClick={() => navigate('/app/sales')}
            sx={{ minWidth: 124, bgcolor: '#176B5B', '&:hover': { bgcolor: '#105246' } }}
          >
            {t('New Sale')}
          </Button>
        </Box>
      )}
    </AppBar>
  );
};

