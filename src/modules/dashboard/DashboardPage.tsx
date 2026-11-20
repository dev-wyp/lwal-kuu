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
  Alert,
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
import { localDateString } from '@/lib/dates';
import { useEntitlements } from '@/modules/subscription/useEntitlements';

type DashboardRows<T> = { rows: T[] | null; error?: string };

export const DashboardPage: React.FC = () => {
  const { t } = useI18n();
  const { currentOrg, formatCurrency } = useOrg();
  const navigate = useNavigate();
  const { data: entitlements = [] } = useEntitlements();
  const canViewCustomerLedger = entitlements.some((item) =>
    ['customer_ledger', 'customer_debt_tracking'].includes(item.feature_key) && item.is_allowed
  );
  const canViewSupplierPayables = entitlements.some((item) => item.feature_key === 'supplier_payables' && item.is_allowed);
  const orgId = currentOrg?.id;

  // 1. Fetch Dashboard Metrics
  const { data: metrics, isLoading, isError, error: dashboardError, refetch } = useQuery({
    queryKey: ['dashboard_metrics', orgId, canViewCustomerLedger, canViewSupplierPayables],
    queryFn: async () => {
      if (!orgId) return null;

      const now = new Date();
      const today = localDateString(now);
      const startOfMonth = localDateString(new Date(now.getFullYear(), now.getMonth(), 1));
      const loadErrors: string[] = [];
      const readRows = async <T,>(name: string, request: PromiseLike<{ data: T[] | null; error: { message: string } | null }>): Promise<DashboardRows<T>> => {
        try {
          const { data, error } = await request;
          if (error) throw error;
          return { rows: data ?? [] };
        } catch (requestError) {
          const detail = requestError instanceof Error ? requestError.message : String(requestError);
          console.error(`Dashboard request failed (${name}):`, detail);
          loadErrors.push(name);
          return { rows: null, error: detail };
        }
      };

      // Today's Sales
      const todayResult = await readRows('today sales', supabase
        .from('sales')
        .select('total_amount, total_cost')
        .eq('organization_id', orgId)
        .eq('status', 'confirmed')
        .eq('sale_date', today));
      const todaySales = todayResult.rows;

      const todayTotal = todaySales?.reduce((acc, s) => acc + Number(s.total_amount), 0) ?? null;
      const todayProfit = todaySales?.reduce((acc, s) => acc + (Number(s.total_amount) - Number(s.total_cost)), 0) ?? null;

      // Monthly Sales
      const monthResult = await readRows('monthly sales', supabase
        .from('sales')
        .select('total_amount')
        .eq('organization_id', orgId)
        .eq('status', 'confirmed')
        .gte('sale_date', startOfMonth)
        .lte('sale_date', today));
      const monthSales = monthResult.rows;

      const monthTotal = monthSales?.reduce((acc, s) => acc + Number(s.total_amount), 0) ?? null;

      // Customer Receivables (Total outstanding)
      let totalReceivables: number | null = null;
      if (canViewCustomerLedger) {
        const customerBalanceResult = await readRows('customer balances', supabase
          .from('customer_balances_summary')
          .select('current_balance')
          .eq('organization_id', orgId));
        totalReceivables = customerBalanceResult.rows?.reduce((acc, c) => acc + Math.max(0, Number(c.current_balance)), 0) ?? null;
      }

      // Supplier Payables
      let supplierBalances: any[] = [];
      let totalPayables: number | null = 0;
      if (canViewSupplierPayables) {
        const supplierBalanceResult = await readRows('supplier balances', supabase
          .from('supplier_balances_summary')
          .select('current_payable')
          .eq('organization_id', orgId));
        supplierBalances = supplierBalanceResult.rows ?? [];
        totalPayables = supplierBalanceResult.rows
          ? supplierBalances.reduce((acc, s) => acc + Math.max(0, Number(s.current_payable)), 0)
          : null;
      }

      // Current Stock Value & Low Stock Count
      const stockResult = await readRows('stock balances', supabase
        .from('product_stock_balances')
        .select('stock_value, is_low_stock')
        .eq('organization_id', orgId));
      const stockItems = stockResult.rows;

      const totalStockVal = stockItems?.reduce((acc, item) => acc + Number(item.stock_value || 0), 0) ?? null;
      const lowStockCount = stockItems?.filter((item) => item.is_low_stock).length ?? null;

      // Recent 5 Sales Invoices
      const recentSalesResult = await readRows('recent sales', supabase
        .from('sales')
        .select('id, invoice_number, sale_date, total_amount, paid_amount, payment_status, status, customers!sales_customer_id_fkey(name)')
        .eq('organization_id', orgId)
        .eq('status', 'confirmed')
        .order('created_at', { ascending: false })
        .limit(5));

      return {
        todayTotal,
        todayProfit,
        monthTotal,
        totalReceivables,
        totalPayables,
        totalStockVal,
        lowStockCount,
        recentSales: recentSalesResult.rows ?? [],
        recentSalesAvailable: recentSalesResult.rows !== null,
        loadErrors,
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

  if (isError) {
    return (
      <Alert
        severity="error"
        action={<Button color="inherit" size="small" onClick={() => void refetch()}>{t('Try again')}</Button>}
      >
      {t('The dashboard could not be displayed.')}{dashboardError instanceof Error ? ` ${dashboardError.message}` : ''}
      </Alert>
    );
  }

  return (
    <Box>
      {Boolean(metrics?.loadErrors.length) && <Alert severity="warning" sx={{ mb: 2 }}>
        {t('Some dashboard sections could not be loaded:')} {metrics?.loadErrors.join(', ')}. {t('Available sections are still shown; use Try again to reload.')}
        <Button color="inherit" size="small" onClick={() => void refetch()} sx={{ ml: 1 }}>{t('Try again')}</Button>
      </Alert>}
      <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: { xs: 'flex-start', sm: 'center' }, gap: 2, mb: 3, flexWrap: 'wrap' }}>
        <Box>
          <Typography variant="h4" sx={{ fontWeight: 750, fontSize: { xs: 25, sm: 30 } }}>
            {t("Business Overview")}</Typography>
          <Typography variant="body2" color="text.secondary" sx={{ mt: 0.5 }}>
            {t(canViewCustomerLedger ? "A quick look at today’s sales, customer balances, and stock." : "A quick look at today’s sales and stock.")}
          </Typography>
        </Box>
        <Button
          variant="contained"
          startIcon={<PointOfSaleIcon />}
          onClick={() => navigate('/app/sales')}
          sx={{ borderRadius: 2.5, px: 2.25, bgcolor: 'primary.main', '&:hover': { bgcolor: 'primary.dark' } }}
        >
          {t("Start a Sale")}</Button>
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
            border: '1px solid #CDE6DF',
            boxShadow: '0 4px 20px -2px rgba(23, 107, 91, 0.07)',
          }}
        >
          <Box sx={{ display: 'flex', alignItems: 'center', gap: 1, mb: 1 }}>
            <CheckCircleOutlineIcon sx={{ color: 'primary.main', fontSize: 24 }} />
            <Typography variant="h6" sx={{ fontWeight: 750, color: 'text.primary' }}>
              {t("Welcome! Set up your shop")}</Typography>
            <Chip label={t("4 easy steps")} size="small" sx={{ bgcolor: '#E7F3F0', color: '#14594C' }} />
          </Box>
          <Typography variant="body2" color="text.secondary" sx={{ mb: 2.5 }}>
            {t("Complete these steps to add your items and start recording sales.")}</Typography>

          <Grid container spacing={2}>
            <Grid item xs={12} sm={6} md={3}>
              <Paper
                component="button"
                variant="outlined"
                sx={{
                  p: 2,
                  width: '100%',
                  textAlign: 'left',
                  appearance: 'none',
                  borderRadius: 2,
                  cursor: 'pointer',
                  '&:hover': { borderColor: 'primary.main', bgcolor: '#F6FAF9', transform: 'translateY(-1px)' },
                  transition: 'transform 160ms ease, border-color 160ms ease, background-color 160ms ease',
                }}
                onClick={() => navigate('/app/categories')}
              >
                <CategoryIcon sx={{ color: 'primary.main', mb: 1 }} />
                <Typography variant="subtitle2" sx={{ fontWeight: 700 }}>
                  {t("1. Setup Categories")}</Typography>
                <Typography variant="caption" color="text.secondary">
                  Organize items into departments or brands &rarr;
                </Typography>
              </Paper>
            </Grid>

            <Grid item xs={12} sm={6} md={3}>
              <Paper
                component="button"
                variant="outlined"
                sx={{
                  p: 2,
                  width: '100%',
                  textAlign: 'left',
                  appearance: 'none',
                  borderRadius: 2,
                  cursor: 'pointer',
                  '&:hover': { borderColor: 'primary.main', bgcolor: '#F6FAF9', transform: 'translateY(-1px)' },
                  transition: 'transform 160ms ease, border-color 160ms ease, background-color 160ms ease',
                }}
                onClick={() => navigate('/app/products')}
              >
                <InventoryIcon sx={{ color: '#3978D4', mb: 1 }} />
                <Typography variant="subtitle2" sx={{ fontWeight: 700 }}>
                  {t("2. Add / Import Products")}</Typography>
                <Typography variant="caption" color="text.secondary">
                  Add items or import via CSV template &rarr;
                </Typography>
              </Paper>
            </Grid>

            <Grid item xs={12} sm={6} md={3}>
              <Paper
                component="button"
                variant="outlined"
                sx={{
                  p: 2,
                  width: '100%',
                  textAlign: 'left',
                  appearance: 'none',
                  borderRadius: 2,
                  cursor: 'pointer',
                  '&:hover': { borderColor: 'primary.main', bgcolor: '#F6FAF9', transform: 'translateY(-1px)' },
                  transition: 'transform 160ms ease, border-color 160ms ease, background-color 160ms ease',
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
                component="button"
                variant="outlined"
                sx={{
                  p: 2,
                  width: '100%',
                  textAlign: 'left',
                  appearance: 'none',
                  borderRadius: 2,
                  cursor: 'pointer',
                  '&:hover': { borderColor: 'primary.main', bgcolor: '#F6FAF9', transform: 'translateY(-1px)' },
                  transition: 'transform 160ms ease, border-color 160ms ease, background-color 160ms ease',
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
      <Grid container spacing={2} sx={{ mb: 3 }}>
        <Grid item xs={12} sm={6} md={3}>
          <Card sx={{ bgcolor: '#ffffff', height: '100%' }}>
            <CardContent>
              <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', mb: 1 }}>
                <Typography variant="body2" sx={{ fontWeight: 650, color: 'text.secondary' }}>
                  {t("Sales today")}
                </Typography>
                <TrendingUpIcon sx={{ color: 'success.main', fontSize: 20 }} />
              </Box>
              <Typography variant="h5" sx={{ fontWeight: 750, fontSize: { xs: 21, sm: 24 }, overflowWrap: 'anywhere' }}>
                {metrics?.todayTotal === null ? '—' : formatCurrency(metrics?.todayTotal || 0)}
              </Typography>
              <Typography variant="caption" color="text.secondary">
                {t("Profit:") + " "}{metrics?.todayProfit === null ? '—' : formatCurrency(metrics?.todayProfit || 0)}
              </Typography>
            </CardContent>
          </Card>
        </Grid>

        <Grid item xs={12} sm={6} md={3}>
          <Card sx={{ bgcolor: '#ffffff', height: '100%' }}>
            <CardContent>
              <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', mb: 1 }}>
                <Typography variant="body2" sx={{ fontWeight: 650, color: 'text.secondary' }}>
                  {t("Sales this month")}</Typography>
                <ShoppingCartIcon sx={{ color: 'secondary.main', fontSize: 20 }} />
              </Box>
              <Typography variant="h5" sx={{ fontWeight: 750, fontSize: { xs: 21, sm: 24 }, overflowWrap: 'anywhere' }}>
                {metrics?.monthTotal === null ? '—' : formatCurrency(metrics?.monthTotal || 0)}
              </Typography>
              <Typography variant="caption" color="text.secondary">
                {t("This calendar month")}</Typography>
            </CardContent>
          </Card>
        </Grid>

        {canViewCustomerLedger && <Grid item xs={12} sm={6} md={3}>
          <Card sx={{ bgcolor: '#ffffff', height: '100%' }}>
            <CardContent>
              <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', mb: 1 }}>
                <Typography variant="body2" sx={{ fontWeight: 650, color: 'text.secondary' }}>
                  {t("Customers owe")}</Typography>
                <AccountBalanceWalletIcon sx={{ color: 'warning.main', fontSize: 20 }} />
              </Box>
              <Typography variant="h5" sx={{ fontWeight: 750, color: 'warning.dark', fontSize: { xs: 21, sm: 24 }, overflowWrap: 'anywhere' }}>
                {metrics?.totalReceivables === null ? '—' : formatCurrency(metrics?.totalReceivables || 0)}
              </Typography>
              <Typography variant="caption" color="text.secondary">
                {t("Unpaid customer credit")}</Typography>
            </CardContent>
          </Card>
        </Grid>}

        <Grid item xs={12} sm={6} md={3}>
          <Card sx={{ bgcolor: '#ffffff', height: '100%' }}>
            <CardContent>
              <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', mb: 1 }}>
                <Typography variant="body2" sx={{ fontWeight: 650, color: 'text.secondary' }}>
                  {t("Stock value")}</Typography>
                <InventoryIcon sx={{ color: 'primary.main', fontSize: 20 }} />
              </Box>
              <Typography variant="h5" sx={{ fontWeight: 750, fontSize: { xs: 21, sm: 24 }, overflowWrap: 'anywhere' }}>
                {metrics?.totalStockVal === null ? '—' : formatCurrency(metrics?.totalStockVal || 0)}
              </Typography>
              <Box sx={{ display: 'flex', alignItems: 'center', gap: 0.5 }}>
                {metrics?.lowStockCount === null ? <Typography variant="caption" color="text.secondary">{t('Stock levels unavailable')}</Typography> : metrics && metrics.lowStockCount > 0 ? (
                  <Chip
                    icon={<WarningAmberIcon sx={{ fontSize: '14px !important' }} />}
                    label={`${metrics.lowStockCount} ${t('items need restocking')}`}
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
      <Paper elevation={0} sx={{ p: { xs: 1.5, sm: 2.5 }, borderRadius: 3, border: '1px solid #e3eaec', bgcolor: '#ffffff' }}>
        <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', mb: 2 }}>
          <Typography variant="h6" sx={{ fontWeight: 700 }}>
            {t("Latest sales")}</Typography>
          <Button size="small" onClick={() => navigate('/app/sales')}>
            {t("See all sales")}</Button>
        </Box>

        <TableContainer>
          <Table size="small" sx={{ minWidth: 760 }}>
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
              {metrics?.recentSalesAvailable === false ? (
                <TableRow><TableCell colSpan={7} align="center" sx={{ py: 4, color: 'text.secondary' }}>{t('Recent sales are unavailable. Try again shortly.')}</TableCell></TableRow>
              ) : metrics?.recentSales && metrics.recentSales.length > 0 ? (
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
                    {t('No sales have been recorded yet. Choose “Start a Sale” to record your first sale.')}
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

