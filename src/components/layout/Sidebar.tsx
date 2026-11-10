import React from 'react';
import {
  Drawer,
  List,
  ListItem,
  ListItemButton,
  ListItemIcon,
  ListItemText,
  Box,
  Typography,
  Divider,
} from '@mui/material';
import DashboardIcon from '@mui/icons-material/Dashboard';
import PointOfSaleIcon from '@mui/icons-material/PointOfSale';
import Inventory2Icon from '@mui/icons-material/Inventory2';
import CategoryIcon from '@mui/icons-material/Category';
import PeopleAltIcon from '@mui/icons-material/PeopleAlt';
import LocalShippingIcon from '@mui/icons-material/LocalShipping';
import ShoppingBagIcon from '@mui/icons-material/ShoppingBag';
import WarehouseIcon from '@mui/icons-material/Warehouse';
import PaymentIcon from '@mui/icons-material/Payment';
import ReceiptLongIcon from '@mui/icons-material/ReceiptLong';
import AssessmentIcon from '@mui/icons-material/Assessment';
import LoyaltyIcon from '@mui/icons-material/Loyalty';
import SettingsIcon from '@mui/icons-material/Settings';
import AdminPanelSettingsIcon from '@mui/icons-material/AdminPanelSettings';
import { useLocation, useNavigate } from 'react-router-dom';
import { useAuth } from '@/context/AuthContext';

interface SidebarProps {
  open: boolean;
  onClose: () => void;
  isMobile: boolean;
}

interface NavItem {
  title: string;
  path: string;
  icon: React.ReactNode;
}

const mainNavItems: NavItem[] = [
  { title: 'Dashboard', path: '/app/dashboard', icon: <DashboardIcon fontSize="small" /> },
  { title: 'POS / Sales', path: '/app/sales', icon: <PointOfSaleIcon fontSize="small" /> },
  { title: 'Products', path: '/app/products', icon: <Inventory2Icon fontSize="small" /> },
  { title: 'Categories', path: '/app/categories', icon: <CategoryIcon fontSize="small" /> },
  { title: 'Customers', path: '/app/customers', icon: <PeopleAltIcon fontSize="small" /> },
  { title: 'Suppliers', path: '/app/suppliers', icon: <LocalShippingIcon fontSize="small" /> },
  { title: 'Purchases', path: '/app/purchases', icon: <ShoppingBagIcon fontSize="small" /> },
  { title: 'Inventory Ledger', path: '/app/inventory', icon: <WarehouseIcon fontSize="small" /> },
  { title: 'Customer Payments', path: '/app/payments', icon: <PaymentIcon fontSize="small" /> },
  { title: 'Expenses', path: '/app/expenses', icon: <ReceiptLongIcon fontSize="small" /> },
  { title: 'Reports & Analytics', path: '/app/reports', icon: <AssessmentIcon fontSize="small" /> },
  { title: 'SaaS Subscription', path: '/app/subscription', icon: <LoyaltyIcon fontSize="small" /> },
  { title: 'Settings', path: '/app/settings', icon: <SettingsIcon fontSize="small" /> },
];

const platformNavItems: NavItem[] = [
  { title: 'All Organizations', path: '/platform/organizations', icon: <AdminPanelSettingsIcon fontSize="small" /> },
  { title: 'Subscriptions', path: '/platform/subscriptions', icon: <LoyaltyIcon fontSize="small" /> },
  { title: 'Usage Metrics', path: '/platform/usage', icon: <AssessmentIcon fontSize="small" /> },
  { title: 'Platform Audit Logs', path: '/platform/audit-logs', icon: <ReceiptLongIcon fontSize="small" /> },
];

export const Sidebar: React.FC<SidebarProps> = ({ open, onClose, isMobile }) => {
  const location = useLocation();
  const navigate = useNavigate();
  const { profile } = useAuth();

  const handleNavClick = (path: string) => {
    navigate(path);
    if (isMobile) {
      onClose();
    }
  };

  const drawerContent = (
    <Box sx={{ width: 250, display: 'flex', flexDirection: 'column', height: '100%', py: 1 }}>
      <Box sx={{ px: 2, py: 1.5 }}>
        <Typography variant="overline" sx={{ fontWeight: 700, color: '#94a3b8', letterSpacing: '0.08em' }}>
          Shop Operations
        </Typography>
      </Box>

      <List dense sx={{ px: 1 }}>
        {mainNavItems.map((item) => {
          const isActive = location.pathname === item.path || (item.path !== '/app/dashboard' && location.pathname.startsWith(item.path));
          return (
            <ListItem key={item.path} disablePadding sx={{ mb: 0.5 }}>
              <ListItemButton
                onClick={() => handleNavClick(item.path)}
                selected={isActive}
                sx={{
                  borderRadius: 2,
                  py: 1,
                  px: 1.5,
                  '&.Mui-selected': {
                    bgcolor: '#0f172a',
                    color: '#ffffff',
                    '&:hover': { bgcolor: '#1e293b' },
                    '& .MuiListItemIcon-root': { color: '#38bdf8' },
                  },
                }}
              >
                <ListItemIcon sx={{ minWidth: 34, color: isActive ? '#38bdf8' : '#64748b' }}>
                  {item.icon}
                </ListItemIcon>
                <ListItemText
                  primary={item.title}
                  primaryTypographyProps={{
                    fontSize: 13,
                    fontWeight: isActive ? 600 : 500,
                  }}
                />
              </ListItemButton>
            </ListItem>
          );
        })}
      </List>

      {profile?.is_platform_admin && (
        <>
          <Divider sx={{ my: 1.5 }} />
          <Box sx={{ px: 2, py: 1 }}>
            <Typography variant="overline" sx={{ fontWeight: 700, color: '#dc2626', letterSpacing: '0.08em' }}>
              Platform Super-Admin
            </Typography>
          </Box>
          <List dense sx={{ px: 1 }}>
            {platformNavItems.map((item) => {
              const isActive = location.pathname.startsWith(item.path);
              return (
                <ListItem key={item.path} disablePadding sx={{ mb: 0.5 }}>
                  <ListItemButton
                    onClick={() => handleNavClick(item.path)}
                    selected={isActive}
                    sx={{
                      borderRadius: 2,
                      py: 0.8,
                      px: 1.5,
                      '&.Mui-selected': {
                        bgcolor: '#dc2626',
                        color: '#ffffff',
                        '&:hover': { bgcolor: '#b91c1c' },
                        '& .MuiListItemIcon-root': { color: '#ffffff' },
                      },
                    }}
                  >
                    <ListItemIcon sx={{ minWidth: 34, color: isActive ? '#ffffff' : '#ef4444' }}>
                      {item.icon}
                    </ListItemIcon>
                    <ListItemText
                      primary={item.title}
                      primaryTypographyProps={{ fontSize: 13, fontWeight: isActive ? 600 : 500 }}
                    />
                  </ListItemButton>
                </ListItem>
              );
            })}
          </List>
        </>
      )}

      <Box sx={{ mt: 'auto', px: 2, py: 1.5, borderTop: '1px solid #f1f5f9' }}>
        <Typography variant="caption" color="text.secondary" sx={{ display: 'block' }}>
          ShopFlow Cloud v1.0
        </Typography>
        <Typography variant="caption" sx={{ color: '#94a3b8', fontSize: 11 }}>
          Myanmar & Southeast Asia
        </Typography>
      </Box>
    </Box>
  );

  return (
    <>
      {isMobile ? (
        <Drawer
          variant="temporary"
          open={open}
          onClose={onClose}
          ModalProps={{ keepMounted: true }}
          PaperProps={{ sx: { bgcolor: '#ffffff', borderRight: '1px solid #e2e8f0' } }}
        >
          {drawerContent}
        </Drawer>
      ) : (
        <Drawer
          variant="persistent"
          open={open}
          PaperProps={{
            sx: {
              width: 250,
              bgcolor: '#ffffff',
              borderRight: '1px solid #e2e8f0',
              top: 64,
              height: 'calc(100% - 64px)',
            },
          }}
        >
          {drawerContent}
        </Drawer>
      )}
    </>
  );
};

