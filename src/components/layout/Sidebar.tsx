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
  Chip,
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
import LockOutlinedIcon from '@mui/icons-material/LockOutlined';
import { useLocation, useNavigate } from 'react-router-dom';
import { useAuth } from '@/context/AuthContext';
import { useEntitlements } from '@/modules/subscription/useEntitlements';
import { useI18n } from '@/i18n/I18nContext';

interface SidebarProps {
  open: boolean;
  onClose: () => void;
  isMobile: boolean;
}

interface NavItem {
  title: string;
  path: string;
  icon: React.ReactNode;
  feature?: string;
}

const mainNavItems: NavItem[] = [
  { title: 'Dashboard', path: '/app/dashboard', icon: <DashboardIcon fontSize="small" /> },
  { title: 'POS / Sales', path: '/app/sales', icon: <PointOfSaleIcon fontSize="small" />, feature: 'sales_management' },
  { title: 'Products', path: '/app/products', icon: <Inventory2Icon fontSize="small" />, feature: 'product_management' },
  { title: 'Categories', path: '/app/categories', icon: <CategoryIcon fontSize="small" />, feature: 'category_management' },
  { title: 'Customers', path: '/app/customers', icon: <PeopleAltIcon fontSize="small" />, feature: 'customer_management' },
  { title: 'Suppliers', path: '/app/suppliers', icon: <LocalShippingIcon fontSize="small" />, feature: 'supplier_management' },
  { title: 'Purchases', path: '/app/purchases', icon: <ShoppingBagIcon fontSize="small" />, feature: 'purchase_management' },
  { title: 'Inventory Ledger', path: '/app/inventory', icon: <WarehouseIcon fontSize="small" />, feature: 'inventory_management' },
  { title: 'Customer Payments', path: '/app/payments', icon: <PaymentIcon fontSize="small" />, feature: 'payment_receipt_mgmt' },
  { title: 'Expenses', path: '/app/expenses', icon: <ReceiptLongIcon fontSize="small" />, feature: 'expense_management' },
  { title: 'Reports & Analytics', path: '/app/reports', icon: <AssessmentIcon fontSize="small" />, feature: 'daily_sales_report' },
  { title: 'Plan & Features', path: '/app/subscription', icon: <LoyaltyIcon fontSize="small" /> },
  { title: 'Settings', path: '/app/settings', icon: <SettingsIcon fontSize="small" /> },
];

const platformNavItems: NavItem[] = [
  { title: 'Super-Admin Console', path: '/admin/organizations', icon: <AdminPanelSettingsIcon fontSize="small" /> },
  { title: 'Global Users', path: '/admin/users', icon: <PeopleAltIcon fontSize="small" /> },
];

export const Sidebar: React.FC<SidebarProps> = ({ open, onClose, isMobile }) => {
  const location = useLocation();
  const navigate = useNavigate();
  const { profile } = useAuth();
  const { t } = useI18n();
  const { data: entitlements = [], isLoading: entitlementsLoading } = useEntitlements();

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
          {t('Shop Operations')}
        </Typography>
      </Box>

      <List dense sx={{ px: 1 }}>
        {mainNavItems.map((item) => {
          const isActive = location.pathname === item.path || (item.path !== '/app/dashboard' && location.pathname.startsWith(item.path));
          const itemEntitlement = item.feature ? entitlements.find((value) => value.feature_key === item.feature) : undefined;
          const locked = !entitlementsLoading && Boolean(item.feature && !itemEntitlement?.is_allowed);
          return (
            <ListItem key={item.path} disablePadding sx={{ mb: 0.5 }}>
              <ListItemButton
                onClick={() => handleNavClick(item.path)}
                selected={isActive}
                sx={{
                  borderRadius: 2,
                  py: 1,
                  px: 1.5,
                  opacity: locked ? 0.66 : 1,
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
                  primary={t(item.title)}
                  primaryTypographyProps={{
                    fontSize: 13,
                    fontWeight: isActive ? 600 : 500,
                  }}
                />
                {locked && <Chip size="small" label={t('Upgrade')} icon={<LockOutlinedIcon />} sx={{ height: 22, fontSize: 10 }} />}
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
              {t("Platform Super-Admin")}</Typography>
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
          Lwal Kuu Cloud v1.0
        </Typography>
        <Typography variant="caption" sx={{ color: '#94a3b8', fontSize: 11 }}>
          {t('Myanmar & Southeast Asia')}
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

