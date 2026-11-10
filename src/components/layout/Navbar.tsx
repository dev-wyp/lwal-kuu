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

interface NavbarProps {
  onToggleSidebar: () => void;
}

export const Navbar: React.FC<NavbarProps> = ({ onToggleSidebar }) => {
  const { user, profile, signOut } = useAuth();
  const { currentOrg, organizations, switchOrg, role } = useOrg();
  const navigate = useNavigate();

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
        color: '#0f172a',
        borderBottom: '1px solid #e2e8f0',
        boxShadow: 'none',
        zIndex: (theme) => theme.zIndex.drawer + 1,
      }}
    >
      <Toolbar sx={{ justifyContent: 'space-between', minHeight: 64 }}>
        <Box sx={{ display: 'flex', alignItems: 'center', gap: 2 }}>
          <IconButton edge="start" color="inherit" onClick={onToggleSidebar} sx={{ mr: 1 }}>
            <MenuIcon />
          </IconButton>

          <Box
            sx={{ display: 'flex', alignItems: 'center', gap: 1, cursor: 'pointer' }}
            onClick={() => navigate('/app/dashboard')}
          >
            <StorefrontIcon sx={{ color: '#0284c7', fontSize: 28 }} />
            <Typography variant="h6" sx={{ fontWeight: 700, color: '#0f172a' }}>
              ShopFlow
            </Typography>
            <Chip
              label="SaaS"
              size="small"
              sx={{ bgcolor: '#e0f2fe', color: '#0369a1', fontWeight: 600, height: 20, fontSize: 11 }}
            />
          </Box>

          {/* Org Selector */}
          {organizations.length > 0 && currentOrg && (
            <FormControl size="small" sx={{ minWidth: 180, ml: 2, display: { xs: 'none', sm: 'block' } }}>
              <Select
                value={currentOrg.id}
                onChange={handleOrgChange}
                sx={{
                  bgcolor: '#f8fafc',
                  fontSize: 13,
                  fontWeight: 600,
                  borderRadius: 2,
                  '& .MuiOutlinedInput-notchedOutline': { borderColor: '#e2e8f0' },
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
              label={role.toUpperCase()}
              size="small"
              variant="outlined"
              color={role === 'owner' ? 'primary' : 'default'}
              sx={{ display: { xs: 'none', md: 'inline-flex' }, height: 22, fontSize: 10, fontWeight: 700 }}
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
              bgcolor: '#0284c7',
              borderRadius: 2,
              '&:hover': { bgcolor: '#0369a1' },
              display: { xs: 'none', sm: 'inline-flex' },
            }}
          >
            New Sale
          </Button>

          {/* User Profile Avatar */}
          <IconButton onClick={handleMenuOpen} size="small" sx={{ ml: 1 }}>
            <Avatar sx={{ bgcolor: '#0f172a', width: 34, height: 34, fontSize: 14, fontWeight: 600 }}>
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
                {profile?.full_name || 'ShopFlow User'}
              </Typography>
              <Typography variant="caption" color="text.secondary" noWrap sx={{ display: 'block' }}>
                {user?.email}
              </Typography>
            </Box>
            <Divider />

            <MenuItem
              onClick={() => {
                handleMenuClose();
                navigate('/app/settings');
              }}
            >
              <ListItemIcon>
                <SettingsIcon fontSize="small" />
              </ListItemIcon>
              Org Settings
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
              New Organization
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
                Super-Admin Portal
              </MenuItem>
            )}

            <Divider />
            <MenuItem onClick={handleSignOut} sx={{ color: 'error.main' }}>
              <ListItemIcon>
                <LogoutIcon fontSize="small" color="error" />
              </ListItemIcon>
              Sign Out
            </MenuItem>
          </Menu>
        </Box>
      </Toolbar>
    </AppBar>
  );
};

