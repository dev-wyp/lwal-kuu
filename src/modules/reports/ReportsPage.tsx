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
import { localDateString } from '@/lib/dates';

export const ReportsPage: React.FC = () => {
  const { t } = useI18n();
  const { currentOrg, formatCurrency } = useOrg();
  const { data: entitlements = [] } = useEntitlements();
  const navigate = useNavigate();
  const orgId = currentOrg?.id;
  const canViewCustomerLedger = entitlements.some((item) => ['customer_ledger', 'customer_debt_tracking'].includes(item.feature_key) && item.is_allowed);
  const canViewSupplierPayables = entitlements.some((item) => item.feature_key === 'supplier_payables' && item.is_allowed);
  const hasFeature = (key: string) => entitlements.some((item) => item.feature_key === key && item.is_allowed);
  const canViewProductReport = hasFeature('basic_product_report');
  const canViewMonthlyYearly = hasFeature('monthly_yearly_reports');
  const canViewPurchaseAnalytics = hasFeature('purchase_analytics');
  const canViewSalesAnalytics = hasFeature('sales_analytics');
  const canViewProfitLoss = hasFeature('profit_loss_report');
  const canViewCashFlow = hasFeature('cash_flow_report');
  const canExportCsv = hasFeature('manual_data_export');
  const canExportExcel = hasFeature('excel_export');

  const [activeTab, setActiveTab] = useState(0);
  const [startDate, setStartDate] = useState(
    localDateString(new Date(new Date().getFullYear(), new Date().getMonth(), 1))
  );
  const [endDate, setEndDate] = useState(localDateString());

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
  const salesTrend = [...dailyPerformance].sort((a: any, b: any) => String(a.sale_date).localeCompare(String(b.sale_date))).slice(-14);
  const peakSales = Math.max(1, ...salesTrend.map((row: any) => Number(row.total_revenue || 0)));

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

  const { data: productPerformance = [], isLoading: productReportLoading } = useQuery({
    queryKey: ['product_sales_performance', orgId],
    queryFn: async () => {
      const { data, error } = await (supabase as any).from('product_sales_performance').select('*')
        .eq('organization_id', orgId).order('revenue', { ascending: false }).limit(100);
      if (error) throw error;
      return data ?? [];
    },
    enabled: Boolean(orgId && canViewProductReport),
  });

  const { data: monthlyPerformance = [], isLoading: monthlyLoading } = useQuery({
    queryKey: ['monthly_sales_performance', orgId],
    queryFn: async () => {
      const { data, error } = await (supabase as any).from('monthly_sales_performance').select('*')
        .eq('organization_id', orgId).order('period_start', { ascending: false });
      if (error) throw error;
      return data ?? [];
    },
    enabled: Boolean(orgId && canViewMonthlyYearly),
  });

  const { data: yearlyPerformance = [], isLoading: yearlyLoading } = useQuery({
    queryKey: ['yearly_sales_performance', orgId],
    queryFn: async () => {
      const { data, error } = await (supabase as any).from('yearly_sales_performance').select('*')
        .eq('organization_id', orgId).order('period_start', { ascending: false });
      if (error) throw error;
      return data ?? [];
    },
    enabled: Boolean(orgId && canViewMonthlyYearly),
  });

  const { data: purchaseAnalytics = [], isLoading: purchaseAnalyticsLoading } = useQuery({
    queryKey: ['purchase_analytics', orgId],
    queryFn: async () => {
      const { data, error } = await (supabase as any).from('purchase_analytics').select('*')
        .eq('organization_id', orgId).order('period_start', { ascending: false }).limit(100);
      if (error) throw error;
      return data ?? [];
    },
    enabled: Boolean(orgId && canViewPurchaseAnalytics),
  });

  const { data: profitLoss = [], isLoading: profitLossLoading } = useQuery({
    queryKey: ['profit_loss_performance', orgId],
    queryFn: async () => {
      const { data, error } = await (supabase as any).from('profit_loss_performance').select('*')
        .eq('organization_id', orgId).order('period_start', { ascending: false });
      if (error) throw error;
      return data ?? [];
    },
    enabled: Boolean(orgId && canViewProfitLoss),
  });

  const { data: cashFlow = [], isLoading: cashFlowLoading } = useQuery({
    queryKey: ['cash_flow_performance', orgId],
    queryFn: async () => {
      const { data, error } = await (supabase as any).from('cash_flow_performance').select('*')
        .eq('organization_id', orgId).order('period_start', { ascending: false });
      if (error) throw error;
      return data ?? [];
    },
    enabled: Boolean(orgId && canViewCashFlow),
  });

  // Export to CSV helper
  const exportToCSV = (data: any[], filename: string) => {
    if (!data || data.length === 0) return;
    const cell = (value: unknown) => {
      const textValue = String(value ?? '');
      const safeValue = typeof value === 'string' && /^[\t\r ]*[=+\-@]/.test(textValue) ? `'${textValue}` : textValue;
      return `"${safeValue.replace(/"/g, '""')}"`;
    };
    const headers = Object.keys(data[0]).map(cell).join(',');
    const rows = data.map((obj) => Object.values(obj).map(cell).join(','));
    const csvContent = `\uFEFF${[headers, ...rows].join('\r\n')}`;
    const objectUrl = URL.createObjectURL(new Blob([csvContent], { type: 'text/csv;charset=utf-8' }));
    const link = document.createElement('a');
    link.setAttribute('href', objectUrl);
    link.setAttribute('download', `${filename}.csv`);
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
    window.setTimeout(() => URL.revokeObjectURL(objectUrl), 1000);
  };

  const exportCurrentExcel = () => {
    const [rows, filename] = activeTab === 0
      ? [dailyPerformance, `Daily_Gross_Profit_${startDate}_${endDate}`]
      : activeTab === 1
        ? [customerReceivables, `Customer_Receivables_${endDate}`]
        : [supplierPayables, `Supplier_Payables_${endDate}`];
    if (!rows.length) return;
    const escape = (value: unknown) => String(value ?? '').replace(/[&<>"']/g, (char) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[char] ?? char));
    const keys = Object.keys(rows[0]);
    const html = `<html><head><meta charset="utf-8"></head><body><table><thead><tr>${keys.map((key) => `<th>${escape(key)}</th>`).join('')}</tr></thead><tbody>${rows.map((row: any) => `<tr>${keys.map((key) => `<td>${escape(row[key])}</td>`).join('')}</tr>`).join('')}</tbody></table></body></html>`;
    const link = document.createElement('a');
    link.href = URL.createObjectURL(new Blob([html], { type: 'application/vnd.ms-excel;charset=utf-8' }));
    link.download = `${filename}.xls`;
    link.click();
    window.setTimeout(() => URL.revokeObjectURL(link.href), 1000);
  };

  return (
    <Box>
      <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: { xs: 'flex-start', sm: 'center' }, mb: 3, flexWrap: 'wrap', gap: 2 }}>
        <div>
          <Typography variant="h4" sx={{ fontWeight: 800 }}>
            {t("Reports & Business Intelligence")}</Typography>
          <Typography variant="body2" color="text.secondary">
            {t("Gross profit margins, daily revenue, customer receivables, and vendor payables.")}</Typography>
        </div>
        {canExportCsv && <Button
          variant="outlined"
          startIcon={<DownloadIcon />}
          onClick={() => {
            if (activeTab === 0) exportToCSV(dailyPerformance, `Daily_Gross_Profit_${startDate}_${endDate}`);
            else if (activeTab === 1) exportToCSV(customerReceivables, `Customer_Receivables_${endDate}`);
            else exportToCSV(supplierPayables, `Supplier_Payables_${endDate}`);
          }}
          sx={{ borderRadius: 2 }}
        >
          {t("Export CSV")}</Button>}
        {canExportExcel && <Button variant="outlined" startIcon={<DownloadIcon />} onClick={exportCurrentExcel} sx={{ borderRadius: 2, ml: 1 }}>{t('Export Excel')}</Button>}
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
          variant="scrollable"
          scrollButtons="auto"
          allowScrollButtonsMobile
          sx={{ px: { xs: 0.5, sm: 2 }, borderBottom: '1px solid #e2e8f0' }}
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

      <Grid container spacing={2} sx={{ mt: 1 }}>
        {canViewProductReport && <Grid item xs={12}>
          <AdditionalReportTable title={t('Product Performance')} rows={productPerformance} loading={productReportLoading} formatCurrency={formatCurrency}
            columns={[
              ['sku', t('SKU')], ['product_name', t('Product')], ['invoice_count', t('Invoices')],
              ['units_sold', t('Units Sold')], ['revenue', t('Revenue'), true], ['cost_of_goods', t('Cost of Goods'), true], ['gross_profit', t('Gross Profit'), true],
            ]} />
        </Grid>}
        {canViewMonthlyYearly && <>
          <Grid item xs={12}>
            <AdditionalReportTable title={t('Monthly Sales & Gross Profit')} rows={monthlyPerformance} loading={monthlyLoading} formatCurrency={formatCurrency}
              columns={[
                ['period_start', t('Month')], ['invoice_count', t('Invoices')], ['revenue', t('Revenue'), true],
                ['cost_of_goods', t('Cost of Goods'), true], ['gross_profit', t('Gross Profit'), true],
              ]} />
          </Grid>
          <Grid item xs={12}>
            <AdditionalReportTable title={t('Yearly Sales & Gross Profit')} rows={yearlyPerformance} loading={yearlyLoading} formatCurrency={formatCurrency}
              columns={[
                ['period_start', t('Year')], ['invoice_count', t('Invoices')], ['revenue', t('Revenue'), true],
                ['cost_of_goods', t('Cost of Goods'), true], ['gross_profit', t('Gross Profit'), true],
              ]} />
          </Grid>
        </>}
        {canViewSalesAnalytics && <Grid item xs={12}>
          <Paper elevation={0} sx={{ p: 2.5, borderRadius: 3, border: '1px solid #e2e8f0', bgcolor: '#ffffff' }}>
            <Typography variant="h6" fontWeight={700} sx={{ mb: 1 }}>{t('Sales Analytics')}</Typography>
            <Typography color="text.secondary">{t('Selected range')}: {startDate} – {endDate}</Typography>
            <Grid container spacing={2} sx={{ mt: 0.5 }}>
              <Grid item xs={12} sm={4}><Typography variant="body2">{t('Invoices')}: <strong>{dailyPerformance.reduce((sum: number, row: any) => sum + Number(row.total_invoices || 0), 0).toLocaleString()}</strong></Typography></Grid>
              <Grid item xs={12} sm={4}><Typography variant="body2">{t('Revenue')}: <strong>{formatCurrency(dailyPerformance.reduce((sum: number, row: any) => sum + Number(row.total_revenue || 0), 0))}</strong></Typography></Grid>
              <Grid item xs={12} sm={4}><Typography variant="body2">{t('Gross Profit')}: <strong>{formatCurrency(dailyPerformance.reduce((sum: number, row: any) => sum + Number(row.gross_profit || 0), 0))}</strong></Typography></Grid>
            </Grid>
            <Box sx={{ display: 'flex', alignItems: 'flex-end', gap: 1, height: 150, mt: 2, pt: 1, borderBottom: '1px solid #cbd5e1' }} aria-label={t('Daily revenue trend for the last 14 days in the selected range')}>
              {salesTrend.map((row: any) => <Box key={row.sale_date} title={`${row.sale_date}: ${formatCurrency(Number(row.total_revenue || 0))}`} sx={{ flex: 1, minWidth: 8, height: `${Math.max(4, Number(row.total_revenue || 0) / peakSales * 100)}%`, bgcolor: '#0284c7', borderRadius: '4px 4px 0 0', position: 'relative' }}>
                <Typography variant="caption" sx={{ position: 'absolute', bottom: -22, left: '50%', transform: 'translateX(-50%)', whiteSpace: 'nowrap', color: 'text.secondary', fontSize: 9 }}>{String(row.sale_date).slice(5)}</Typography>
              </Box>)}
              {salesTrend.length === 0 && <Typography color="text.secondary">{t('No daily sales data to chart.')}</Typography>}
            </Box>
          </Paper>
        </Grid>}
        {canViewPurchaseAnalytics && <Grid item xs={12}>
          <AdditionalReportTable title={t('Purchase Analytics by Supplier')} rows={purchaseAnalytics} loading={purchaseAnalyticsLoading} formatCurrency={formatCurrency}
            columns={[
              ['period_start', t('Month')], ['supplier_name', t('Supplier')], ['purchase_count', t('Purchases')],
              ['purchase_amount', t('Purchase Amount'), true], ['paid_amount', t('Paid'), true], ['outstanding_amount', t('Outstanding'), true],
            ]} />
        </Grid>}
        {canViewProfitLoss && <Grid item xs={12}>
          <AdditionalReportTable title={t('Monthly Profit & Loss')} rows={profitLoss} loading={profitLossLoading} formatCurrency={formatCurrency}
            columns={[
              ['period_start', t('Month')], ['revenue', t('Revenue'), true], ['cost_of_goods', t('Cost of Goods'), true],
              ['gross_profit', t('Gross Profit'), true], ['operating_expenses', t('Operating Expenses'), true], ['net_operating_profit', t('Net Operating Profit'), true],
            ]} />
        </Grid>}
        {canViewCashFlow && <Grid item xs={12}>
          <AdditionalReportTable title={t('Monthly Cash Flow')} rows={cashFlow} loading={cashFlowLoading} formatCurrency={formatCurrency}
            columns={[
              ['period_start', t('Month')], ['cash_in', t('Cash In'), true], ['cash_out', t('Cash Out'), true], ['net_cash_flow', t('Net Cash Flow'), true],
            ]} />
        </Grid>}
      </Grid>
    </Box>
  );
};

type AdditionalReportColumn = [string, string, boolean?];

const AdditionalReportTable: React.FC<{
  title: string;
  rows: any[];
  loading: boolean;
  formatCurrency: (value: number) => string;
  columns: AdditionalReportColumn[];
}> = ({ title, rows, loading, formatCurrency, columns }) => (
  <Paper elevation={0} sx={{ borderRadius: 3, border: '1px solid #e2e8f0', bgcolor: '#ffffff', p: 2.5 }}>
    <Typography variant="h6" fontWeight={700} sx={{ mb: 1.5 }}>{title}</Typography>
    <TableContainer>
      <Table size="small">
        <TableHead><TableRow>{columns.map(([key, label]) => <TableCell key={key}>{label}</TableCell>)}</TableRow></TableHead>
        <TableBody>
          {loading ? <TableRow><TableCell colSpan={columns.length} align="center"><CircularProgress size={24} /></TableCell></TableRow>
            : rows.length === 0 ? <TableRow><TableCell colSpan={columns.length} align="center" sx={{ color: 'text.secondary' }}>No report data for this organization.</TableCell></TableRow>
              : rows.map((row, index) => <TableRow key={`${row.product_id ?? row.supplier_id ?? row.period_start}-${index}`} hover>
                {columns.map(([key, _label, isCurrency]) => <TableCell key={key}>
                  {row[key] === null || row[key] === undefined ? '—' : isCurrency ? formatCurrency(Number(row[key])) : String(row[key])}
                </TableCell>)}
              </TableRow>)}
        </TableBody>
      </Table>
    </TableContainer>
  </Paper>
);

