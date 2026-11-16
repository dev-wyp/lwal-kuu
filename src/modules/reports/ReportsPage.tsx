import React, { useState } from 'react';
import {
  Box,
  Typography,
  Button,
  Paper,
  Tabs,
  Tab,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
  Grid,
  TextField,
  CircularProgress,
  Alert,
} from '@mui/material';
import DownloadIcon from '@mui/icons-material/Download';
import { useQuery } from '@tanstack/react-query';
import { supabase } from '@/lib/supabase';
import { useOrg } from '@/context/OrgContext';
import { useEntitlements } from '@/modules/subscription/useEntitlements';
import { useNavigate } from 'react-router-dom';
import { useI18n } from '@/i18n/I18nContext';

export const ReportsPage: React.FC = () => {
  const { t } = useI18n();
  const { currentOrg, formatCurrency } = useOrg();
  const { data: entitlements = [] } = useEntitlements();
  const navigate = useNavigate();
  const orgId = currentOrg?.id;
  const canViewCustomerLedger = entitlements.some((item) => ['customer_ledger', 'customer_debt_tracking'].includes(item.feature_key) && item.is_allowed);
  const canViewSupplierPayables = entitlements.some((item) => item.feature_key === 'supplier_payables' && item.is_allowed);

  const [activeTab, setActiveTab] = useState(0);
  const [startDate, setStartDate] = useState(
    new Date(new Date().getFullYear(), new Date().getMonth(), 1).toISOString().split('T')[0]
  );
  const [endDate, setEndDate] = useState(new Date().toISOString().split('T')[0]);

  // 1. Daily Sales & Gross Profit
  const { data: dailyPerformance = [], isLoading: dailyLoading } = useQuery({
    queryKey: ['daily_sales_performance', orgId, startDate, endDate],
    queryFn: async () => {
      if (!orgId) return [];
      let query = supabase
        .from('daily_sales_performance')
        .select('*')
        .eq('organization_id', orgId);

      if (startDate) query = query.gte('sale_date', startDate);
      if (endDate) query = query.lte('sale_date', endDate);

      const { data, error } = await query.order('sale_date', { ascending: false });
      if (error) throw error;
      return data || [];
    },
    enabled: Boolean(orgId),
  });

  // 2. Customer Receivables Report
  const { data: customerReceivables = [], isLoading: custLoading } = useQuery({
    queryKey: ['customer_receivables_report', orgId],
    queryFn: async () => {
      if (!orgId) return [];
      const { data, error } = await supabase
        .from('customer_balances_summary')
        .select('*')
        .eq('organization_id', orgId)
        .gt('current_balance', 0)
        .order('current_balance', { ascending: false });
      if (error) throw error;
      return data || [];
    },
    enabled: Boolean(orgId) && canViewCustomerLedger,
  });

  // 3. Supplier Payables Report
  const { data: supplierPayables = [], isLoading: suppLoading } = useQuery({
    queryKey: ['supplier_payables_report', orgId],
    queryFn: async () => {
      if (!orgId) return [];
      const { data, error } = await supabase
        .from('supplier_balances_summary')
        .select('*')
        .eq('organization_id', orgId)
        .gt('current_payable', 0)
        .order('current_payable', { ascending: false });
      if (error) throw error;
      return data || [];
    },
    enabled: Boolean(orgId) && canViewSupplierPayables,
  });

  // Export to CSV helper
  const exportToCSV = (data: any[], filename: string) => {
    if (!data || data.length === 0) return;
    const headers = Object.keys(data[0]).join(',');
    const rows = data.map((obj) => Object.values(obj).map((v) => `"${v}"`).join(','));
    const csvContent = 'data:text/csv;charset=utf-8,' + [headers, ...rows].join('\n');
    const encodedUri = encodeURI(csvContent);
    const link = document.createElement('a');
    link.setAttribute('href', encodedUri);
    link.setAttribute('download', `${filename}.csv`);
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
  };

  return (
    <Box>
      <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', mb: 3 }}>
        <div>
          <Typography variant="h4" sx={{ fontWeight: 800 }}>
            {t("Reports & Business Intelligence")}</Typography>
          <Typography variant="body2" color="text.secondary">
            {t("Gross profit margins, daily revenue, customer receivables, and vendor payables.")}</Typography>
        </div>
        <Button
          variant="outlined"
          startIcon={<DownloadIcon />}
          onClick={() => {
            if (activeTab === 0) exportToCSV(dailyPerformance, `Daily_Gross_Profit_${startDate}_${endDate}`);
            else if (activeTab === 1) exportToCSV(customerReceivables, `Customer_Receivables_${endDate}`);
            else exportToCSV(supplierPayables, `Supplier_Payables_${endDate}`);
          }}
          sx={{ borderRadius: 2 }}
        >
          {t("Export CSV")}</Button>
      </Box>

      {(!canViewCustomerLedger || !canViewSupplierPayables) && <Alert severity="info" sx={{ mb: 2 }} action={<Button size="small" color="inherit" onClick={() => navigate('/app/subscription')}>{t("Compare plans")}</Button>}>
        {!canViewCustomerLedger && !canViewSupplierPayables ? 'Customer ledger and supplier payable reports' : !canViewCustomerLedger ? 'Customer ledger reports' : 'Supplier payable reports'} require a plan that includes those modules.
      </Alert>}

      {/* Date Filter Bar */}
      <Paper elevation={0} sx={{ p: 2, mb: 3, borderRadius: 3, border: '1px solid #e2e8f0', bgcolor: '#ffffff' }}>
        <Grid container spacing={2} alignItems="center">
          <Grid item xs={12} sm={4}>
            <TextField
              fullWidth
              size="small"
              type="date"
              label={t("Start Date")}
              value={startDate}
              onChange={(e) => setStartDate(e.target.value)}
              InputLabelProps={{ shrink: true }}
            />
          </Grid>
          <Grid item xs={12} sm={4}>
            <TextField
              fullWidth
              size="small"
              type="date"
              label={t("End Date")}
              value={endDate}
              onChange={(e) => setEndDate(e.target.value)}
              InputLabelProps={{ shrink: true }}
            />
          </Grid>
        </Grid>
      </Paper>

      <Paper elevation={0} sx={{ borderRadius: 3, border: '1px solid #e2e8f0', bgcolor: '#ffffff' }}>
        <Tabs
          value={activeTab}
          onChange={(_e, v) => setActiveTab(v)}
          sx={{ px: 2, borderBottom: '1px solid #e2e8f0' }}
        >
          <Tab label={t("Daily Sales & Gross Profit")} sx={{ fontWeight: 600 }} />
          <Tab label={t("Customer Outstanding Receivables")} disabled={!canViewCustomerLedger} sx={{ fontWeight: 600 }} />
          <Tab label={t("Supplier Outstanding Payables")} disabled={!canViewSupplierPayables} sx={{ fontWeight: 600 }} />
        </Tabs>

        {activeTab === 0 && (
          <TableContainer>
            <Table>
              <TableHead>
                <TableRow>
                  <TableCell>{t("Date")}</TableCell>
                  <TableCell align="center">{t("Invoices Confirmed")}</TableCell>
                  <TableCell align="right">{t("Revenue (MMK)")}</TableCell>
                  <TableCell align="right">{t("Cost of Goods (COGS)")}</TableCell>
                  <TableCell align="right">{t("Gross Profit (MMK)")}</TableCell>
                  <TableCell align="right">{t("Gross Margin %")}</TableCell>
                </TableRow>
              </TableHead>
              <TableBody>
                {dailyLoading ? (
                  <TableRow>
                    <TableCell colSpan={6} align="center" sx={{ py: 6 }}>
                      <CircularProgress size={32} />
                    </TableCell>
                  </TableRow>
                ) : dailyPerformance.length > 0 ? (
                  dailyPerformance.map((row: any) => (
                    <TableRow key={row.sale_date} hover>
                      <TableCell sx={{ fontWeight: 600 }}>{row.sale_date}</TableCell>
                      <TableCell align="center">{row.total_invoices}</TableCell>
                      <TableCell align="right" sx={{ fontWeight: 700 }}>
                        {formatCurrency(row.total_revenue)}
                      </TableCell>
                      <TableCell align="right">{formatCurrency(row.total_cogs)}</TableCell>
                      <TableCell align="right" sx={{ fontWeight: 800, color: '#10b981' }}>
                        {formatCurrency(row.gross_profit)}
                      </TableCell>
                      <TableCell align="right" sx={{ fontWeight: 700, color: '#0284c7' }}>
                        {row.gross_margin_percentage}%
                      </TableCell>
                    </TableRow>
                  ))
                ) : (
                  <TableRow>
                    <TableCell colSpan={6} align="center" sx={{ py: 6, color: 'text.secondary' }}>
                      {t("No sales recorded in the selected date range.")}</TableCell>
                  </TableRow>
                )}
              </TableBody>
            </Table>
          </TableContainer>
        )}

        {activeTab === 1 && (
          <TableContainer>
            <Table>
              <TableHead>
                <TableRow>
                  <TableCell>{t("Customer Name")}</TableCell>
                  <TableCell>{t("Phone")}</TableCell>
                  <TableCell align="right">{t("Credit Limit")}</TableCell>
                  <TableCell align="right">{t("Opening Bal")}</TableCell>
                  <TableCell align="right">{t("Confirmed Sales")}</TableCell>
                  <TableCell align="right">{t("Payments Made")}</TableCell>
                  <TableCell align="right">{t("Outstanding Balance")}</TableCell>
                </TableRow>
              </TableHead>
              <TableBody>
                {custLoading ? (
                  <TableRow>
                    <TableCell colSpan={7} align="center" sx={{ py: 6 }}>
                      <CircularProgress size={32} />
                    </TableCell>
                  </TableRow>
                ) : customerReceivables.length > 0 ? (
                  customerReceivables.map((c: any) => (
                    <TableRow key={c.customer_id} hover>
                      <TableCell sx={{ fontWeight: 600 }}>{c.customer_name}</TableCell>
                      <TableCell>{c.phone || '-'}</TableCell>
                      <TableCell align="right">{formatCurrency(c.credit_limit)}</TableCell>
                      <TableCell align="right">{formatCurrency(c.opening_balance)}</TableCell>
                      <TableCell align="right">{formatCurrency(c.total_confirmed_sales)}</TableCell>
                      <TableCell align="right">{formatCurrency(c.total_payments_received)}</TableCell>
                      <TableCell align="right" sx={{ fontWeight: 800, color: '#d97706' }}>
                        {formatCurrency(c.current_balance)}
                      </TableCell>
                    </TableRow>
                  ))
                ) : (
                  <TableRow>
                    <TableCell colSpan={7} align="center" sx={{ py: 6, color: 'text.secondary' }}>
                      {t("No outstanding receivables. All customer invoices are fully settled!")}</TableCell>
                  </TableRow>
                )}
              </TableBody>
            </Table>
          </TableContainer>
        )}

        {activeTab === 2 && (
          <TableContainer>
            <Table>
              <TableHead>
                <TableRow>
                  <TableCell>{t("Supplier Name")}</TableCell>
                  <TableCell>{t("Phone")}</TableCell>
                  <TableCell align="right">{t("Opening Balance")}</TableCell>
                  <TableCell align="right">{t("Total Purchases")}</TableCell>
                  <TableCell align="right">{t("Total Payments Made")}</TableCell>
                  <TableCell align="right">{t("Outstanding Payable")}</TableCell>
                </TableRow>
              </TableHead>
              <TableBody>
                {suppLoading ? (
                  <TableRow>
                    <TableCell colSpan={6} align="center" sx={{ py: 6 }}>
                      <CircularProgress size={32} />
                    </TableCell>
                  </TableRow>
                ) : supplierPayables.length > 0 ? (
                  supplierPayables.map((s: any) => (
                    <TableRow key={s.supplier_id} hover>
                      <TableCell sx={{ fontWeight: 600 }}>{s.supplier_name}</TableCell>
                      <TableCell>{s.phone || '-'}</TableCell>
                      <TableCell align="right">{formatCurrency(s.opening_balance)}</TableCell>
                      <TableCell align="right">{formatCurrency(s.total_received_purchases)}</TableCell>
                      <TableCell align="right">{formatCurrency(s.total_payments_made)}</TableCell>
                      <TableCell align="right" sx={{ fontWeight: 800, color: '#ef4444' }}>
                        {formatCurrency(s.current_payable)}
                      </TableCell>
                    </TableRow>
                  ))
                ) : (
                  <TableRow>
                    <TableCell colSpan={6} align="center" sx={{ py: 6, color: 'text.secondary' }}>
                      {t("No outstanding payables to suppliers.")}</TableCell>
                  </TableRow>
                )}
              </TableBody>
            </Table>
          </TableContainer>
        )}
      </Paper>
    </Box>
  );
};

