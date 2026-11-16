import React from 'react';
import {
  Box,
  Grid,
  Card,
  CardContent,
  Typography,
  Chip,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
  Paper,
  CircularProgress,
  Button,
} from '@mui/material';
import TrendingUpIcon from '@mui/icons-material/TrendingUp';
import AccountBalanceWalletIcon from '@mui/icons-material/AccountBalanceWallet';
import InventoryIcon from '@mui/icons-material/Inventory';
import WarningAmberIcon from '@mui/icons-material/WarningAmber';
import ShoppingCartIcon from '@mui/icons-material/ShoppingCart';
import PointOfSaleIcon from '@mui/icons-material/PointOfSale';
import CheckCircleOutlineIcon from '@mui/icons-material/CheckCircleOutline';
import CategoryIcon from '@mui/icons-material/Category';
import PeopleIcon from '@mui/icons-material/People';
import { useQuery } from '@tanstack/react-query';
import { supabase } from '@/lib/supabase';
import { useOrg } from '@/context/OrgContext';
import { useNavigate } from 'react-router-dom';
import { useI18n } from '@/i18n/I18nContext';

export const DashboardPage: React.FC = () => {
  const { t } = useI18n();
  const { currentOrg, formatCurrency } = useOrg();
  const navigate = useNavigate();
  const orgId = currentOrg?.id;

  // 1. Fetch Dashboard Metrics
  const { data: metrics, isLoading } = useQuery({
    queryKey: ['dashboard_metrics', orgId],
    queryFn: async () => {
      if (!orgId) return null;

      const today = new Date().toISOString().split('T')[0];
      const startOfMonth = new Date(new Date().getFullYear(), new Date().getMonth(), 1)
        .toISOString()
        .split('T')[0];

      // Today's Sales
      const { data: todaySales } = await supabase
        .from('sales')
        .select('total_amount, total_cost')
        .eq('organization_id', orgId)
        .eq('status', 'confirmed')
        .eq('sale_date', today);

      const todayTotal = todaySales?.reduce((acc, s) => acc + Number(s.total_amount), 0) || 0;
      const todayProfit = todaySales?.reduce((acc, s) => acc + (Number(s.total_amount) - Number(s.total_cost)), 0) || 0;

      // Monthly Sales
      const { data: monthSales } = await supabase
        .from('sales')
        .select('total_amount')
        .eq('organization_id', orgId)
        .eq('status', 'confirmed')
        .gte('sale_date', startOfMonth);

      const monthTotal = monthSales?.reduce((acc, s) => acc + Number(s.total_amount), 0) || 0;

      // Customer Receivables (Total outstanding)
      const { data: customerBalances } = await supabase
        .from('customer_balances_summary')
        .select('current_balance')
        .eq('organization_id', orgId);

      const totalReceivables = customerBalances?.reduce((acc, c) => acc + Math.max(0, Number(c.current_balance)), 0) || 0;

      // Supplier Payables
      const { data: supplierBalances } = await supabase
        .from('supplier_balances_summary')
        .select('current_payable')
        .eq('organization_id', orgId);

      const totalPayables = supplierBalances?.reduce((acc, s) => acc + Math.max(0, Number(s.current_payable)), 0) || 0;

      // Current Stock Value & Low Stock Count
      const { data: stockItems } = await supabase
        .from('product_stock_balances')
        .select('stock_value, is_low_stock')
        .eq('organization_id', orgId);

      const totalStockVal = stockItems?.reduce((acc, item) => acc + Number(item.stock_value || 0), 0) || 0;
      const lowStockCount = stockItems?.filter((item) => item.is_low_stock).length || 0;

      // Recent 5 Sales Invoices
      const { data: recentSales } = await supabase
        .from('sales')
        .select('id, invoice_number, sale_date, total_amount, paid_amount, payment_status, status, customers(name)')
        .eq('organization_id', orgId)
        .order('created_at', { ascending: false })
        .limit(5);

      return {
        todayTotal,
        todayProfit,
        monthTotal,
        totalReceivables,
        totalPayables,
        totalStockVal,
        lowStockCount,
        recentSales: recentSales || [],
      };
    },
    enabled: Boolean(orgId),
    refetchInterval: 30000,
  });

  if (isLoading) {
    return (
      <Box sx={{ display: 'flex', justifyContent: 'center', py: 8 }}>
        <CircularProgress size={36} />
      </Box>
    );
  }

  return (
    <Box>
      <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', mb: 3 }}>
        <div>
          <Typography variant="h4" sx={{ fontWeight: 800 }}>
            {t("Business Overview")}</Typography>
          <Typography variant="body2" color="text.secondary">
            {t("Live operations and financial metrics for") + " "}{currentOrg?.name}
          </Typography>
        </div>
        <Button
          variant="contained"
          startIcon={<PointOfSaleIcon />}
          onClick={() => navigate('/app/sales')}
          sx={{ borderRadius: 2, bgcolor: '#0284c7', '&:hover': { bgcolor: '#0369a1' } }}
        >
          {t("Open POS")}</Button>
      </Box>

      {/* Guided Onboarding Checklist for New Shop */}
      {metrics?.recentSales?.length === 0 && (
        <Paper
          elevation={0}
          sx={{
            p: 3,
            mb: 4,
            borderRadius: 3,
            bgcolor: '#ffffff',
            border: '1px solid #bae6fd',
            boxShadow: '0 4px 20px -2px rgba(2, 132, 199, 0.08)',
          }}
        >
          <Box sx={{ display: 'flex', alignItems: 'center', gap: 1, mb: 1 }}>
            <CheckCircleOutlineIcon sx={{ color: '#0284c7', fontSize: 24 }} />
            <Typography variant="h6" sx={{ fontWeight: 800, color: '#0f172a' }}>
              {t("Welcome to Lwal Kuu! Quick Setup Checklist")}</Typography>
            <Chip label={t("Guided Onboarding")} size="small" sx={{ bgcolor: '#e0f2fe', color: '#0369a1', fontWeight: 700, height: 20, fontSize: 10 }} />
          </Box>
          <Typography variant="body2" color="text.secondary" sx={{ mb: 2.5 }}>
            {t("Follow these 4 automated steps to initialize your shop catalog, stock ledger, and POS billing:")}</Typography>

          <Grid container spacing={2}>
            <Grid item xs={12} sm={6} md={3}>
              <Paper
                variant="outlined"
                sx={{
                  p: 2,
                  borderRadius: 2,
                  cursor: 'pointer',
                  '&:hover': { borderColor: '#0284c7', bgcolor: '#f8fafc' },
                }}
                onClick={() => navigate('/app/categories')}
              >
                <CategoryIcon sx={{ color: '#0284c7', mb: 1 }} />
                <Typography variant="subtitle2" sx={{ fontWeight: 700 }}>
                  {t("1. Setup Categories")}</Typography>
                <Typography variant="caption" color="text.secondary">
                  Organize items into departments or brands &rarr;
                </Typography>
              </Paper>
            </Grid>

            <Grid item xs={12} sm={6} md={3}>
              <Paper
                variant="outlined"
                sx={{
                  p: 2,
                  borderRadius: 2,
                  cursor: 'pointer',
                  '&:hover': { borderColor: '#0284c7', bgcolor: '#f8fafc' },
                }}
                onClick={() => navigate('/app/products')}
              >
                <InventoryIcon sx={{ color: '#6366f1', mb: 1 }} />
                <Typography variant="subtitle2" sx={{ fontWeight: 700 }}>
                  {t("2. Add / Import Products")}</Typography>
                <Typography variant="caption" color="text.secondary">
                  Add items or import via CSV template &rarr;
                </Typography>
              </Paper>
            </Grid>

            <Grid item xs={12} sm={6} md={3}>
              <Paper
                variant="outlined"
                sx={{
                  p: 2,
                  borderRadius: 2,
                  cursor: 'pointer',
                  '&:hover': { borderColor: '#0284c7', bgcolor: '#f8fafc' },
                }}
                onClick={() => navigate('/app/customers')}
              >
                <PeopleIcon sx={{ color: '#10b981', mb: 1 }} />
                <Typography variant="subtitle2" sx={{ fontWeight: 700 }}>
                  {t("3. Add Customers & Debt")}</Typography>
                <Typography variant="caption" color="text.secondary">
                  Register buyers and credit terms &rarr;
                </Typography>
              </Paper>
            </Grid>

            <Grid item xs={12} sm={6} md={3}>
              <Paper
                variant="outlined"
                sx={{
                  p: 2,
                  borderRadius: 2,
                  cursor: 'pointer',
                  '&:hover': { borderColor: '#0284c7', bgcolor: '#f8fafc' },
                }}
                onClick={() => navigate('/app/sales')}
              >
                <PointOfSaleIcon sx={{ color: '#f59e0b', mb: 1 }} />
                <Typography variant="subtitle2" sx={{ fontWeight: 700 }}>
                  {t("4. Make First POS Sale")}</Typography>
                <Typography variant="caption" color="text.secondary">
                  Create invoice & deduct stock ledger &rarr;
                </Typography>
              </Paper>
            </Grid>
          </Grid>
        </Paper>
      )}

      {/* KPI Cards */}
      <Grid container spacing={2.5} sx={{ mb: 4 }}>
        <Grid item xs={12} sm={6} md={3}>
          <Card sx={{ bgcolor: '#ffffff', borderRadius: 3 }}>
            <CardContent>
              <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', mb: 1 }}>
                <Typography variant="caption" sx={{ fontWeight: 700, color: '#64748b' }}>
                  TODAY&apos;S SALES
                </Typography>
                <TrendingUpIcon sx={{ color: '#10b981', fontSize: 20 }} />
              </Box>
              <Typography variant="h5" sx={{ fontWeight: 800 }}>
                {formatCurrency(metrics?.todayTotal || 0)}
              </Typography>
              <Typography variant="caption" color="text.secondary">
                {t("Profit:") + " "}{formatCurrency(metrics?.todayProfit || 0)}
              </Typography>
            </CardContent>
          </Card>
        </Grid>

        <Grid item xs={12} sm={6} md={3}>
          <Card sx={{ bgcolor: '#ffffff', borderRadius: 3 }}>
            <CardContent>
              <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', mb: 1 }}>
                <Typography variant="caption" sx={{ fontWeight: 700, color: '#64748b' }}>
                  {t("MONTHLY SALES")}</Typography>
                <ShoppingCartIcon sx={{ color: '#0284c7', fontSize: 20 }} />
              </Box>
              <Typography variant="h5" sx={{ fontWeight: 800 }}>
                {formatCurrency(metrics?.monthTotal || 0)}
              </Typography>
              <Typography variant="caption" color="text.secondary">
                {t("This calendar month")}</Typography>
            </CardContent>
          </Card>
        </Grid>

        <Grid item xs={12} sm={6} md={3}>
          <Card sx={{ bgcolor: '#ffffff', borderRadius: 3 }}>
            <CardContent>
              <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', mb: 1 }}>
                <Typography variant="caption" sx={{ fontWeight: 700, color: '#64748b' }}>
                  {t("CUSTOMER RECEIVABLES")}</Typography>
                <AccountBalanceWalletIcon sx={{ color: '#f59e0b', fontSize: 20 }} />
              </Box>
              <Typography variant="h5" sx={{ fontWeight: 800, color: '#d97706' }}>
                {formatCurrency(metrics?.totalReceivables || 0)}
              </Typography>
              <Typography variant="caption" color="text.secondary">
                {t("Unpaid customer credit")}</Typography>
            </CardContent>
          </Card>
        </Grid>

        <Grid item xs={12} sm={6} md={3}>
          <Card sx={{ bgcolor: '#ffffff', borderRadius: 3 }}>
            <CardContent>
              <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', mb: 1 }}>
                <Typography variant="caption" sx={{ fontWeight: 700, color: '#64748b' }}>
                  {t("TOTAL STOCK VALUE")}</Typography>
                <InventoryIcon sx={{ color: '#8b5cf6', fontSize: 20 }} />
              </Box>
              <Typography variant="h5" sx={{ fontWeight: 800 }}>
                {formatCurrency(metrics?.totalStockVal || 0)}
              </Typography>
              <Box sx={{ display: 'flex', alignItems: 'center', gap: 0.5 }}>
                {metrics && metrics.lowStockCount > 0 ? (
                  <Chip
                    icon={<WarningAmberIcon sx={{ fontSize: '14px !important' }} />}
                    label={`${metrics.lowStockCount} low stock`}
                    size="small"
                    color="error"
                    sx={{ height: 20, fontSize: 10, fontWeight: 700 }}
                  />
                ) : (
                  <Typography variant="caption" color="text.secondary">
                    {t("Stock levels healthy")}</Typography>
                )}
              </Box>
            </CardContent>
          </Card>
        </Grid>
      </Grid>

      {/* Recent Sales Invoices */}
      <Paper elevation={0} sx={{ p: 3, borderRadius: 3, border: '1px solid #e2e8f0', bgcolor: '#ffffff' }}>
        <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', mb: 2 }}>
          <Typography variant="h6" sx={{ fontWeight: 700 }}>
            {t("Recent Sales Invoices")}</Typography>
          <Button size="small" onClick={() => navigate('/app/sales')}>
            {t("View All Sales")}</Button>
        </Box>

        <TableContainer>
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>{t("Invoice #")}</TableCell>
                <TableCell>{t("Date")}</TableCell>
                <TableCell>{t("Customer")}</TableCell>
                <TableCell align="right">{t("Total")}</TableCell>
                <TableCell align="right">{t("Paid")}</TableCell>
                <TableCell align="center">{t("Payment")}</TableCell>
                <TableCell align="center">{t("Status")}</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {metrics?.recentSales && metrics.recentSales.length > 0 ? (
                metrics.recentSales.map((sale: any) => (
                  <TableRow key={sale.id} hover>
                    <TableCell sx={{ fontWeight: 600 }}>{sale.invoice_number}</TableCell>
                    <TableCell>{sale.sale_date}</TableCell>
                    <TableCell>{sale.customers?.name || 'Walk-in Customer'}</TableCell>
                    <TableCell align="right" sx={{ fontWeight: 700 }}>
                      {formatCurrency(sale.total_amount)}
                    </TableCell>
                    <TableCell align="right">{formatCurrency(sale.paid_amount)}</TableCell>
                    <TableCell align="center">
                      <Chip
                        label={sale.payment_status}
                        size="small"
                        color={
                          sale.payment_status === 'paid'
                            ? 'success'
                            : sale.payment_status === 'partial'
                            ? 'warning'
                            : 'default'
                        }
                        sx={{ height: 22, fontSize: 11, fontWeight: 600 }}
                      />
                    </TableCell>
                    <TableCell align="center">
                      <Chip
                        label={sale.status}
                        size="small"
                        variant="outlined"
                        color={sale.status === 'confirmed' ? 'primary' : 'default'}
                        sx={{ height: 22, fontSize: 11 }}
                      />
                    </TableCell>
                  </TableRow>
                ))
              ) : (
                <TableRow>
                  <TableCell colSpan={7} align="center" sx={{ py: 4, color: 'text.secondary' }}>
                    No sales invoices recorded yet. Click &quot;Open POS&quot; to make your first sale.
                  </TableCell>
                </TableRow>
              )}
            </TableBody>
          </Table>
        </TableContainer>
      </Paper>
    </Box>
  );
};

