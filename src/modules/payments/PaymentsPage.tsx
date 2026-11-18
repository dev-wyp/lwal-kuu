import React, { useState } from 'react';
import {
  Box,
  Typography,
  Button,
  Paper,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
  Chip,
  Dialog,
  DialogTitle,
  DialogContent,
  DialogActions,
  Grid,
  TextField,
  MenuItem,
  CircularProgress,
  Divider,
} from '@mui/material';
import AddIcon from '@mui/icons-material/Add';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/lib/supabase';
import { useOrg } from '@/context/OrgContext';
import { useNotification } from '@/context/NotificationContext';
import { useI18n } from '@/i18n/I18nContext';

export const PaymentsPage: React.FC = () => {
  const { t } = useI18n();
  const { currentOrg, formatCurrency } = useOrg();
  const { showSuccess, showError } = useNotification();
  const queryClient = useQueryClient();
  const orgId = currentOrg?.id;

  const [modalOpen, setModalOpen] = useState(false);
  const [customerId, setCustomerId] = useState('');
  const [paymentAmount, setPaymentAmount] = useState<number>(0);
  const [paymentMethod, setPaymentMethod] = useState('cash');
  const [referenceNumber, setReferenceNumber] = useState('');
  const [notes, setNotes] = useState('');
  const [allocations, setAllocations] = useState<{ [saleId: string]: number }>({});
  const [submitting, setSubmitting] = useState(false);

  // 1. Fetch Customers
  const { data: customers = [] } = useQuery({
    queryKey: ['customers_for_payment', orgId],
    queryFn: async () => {
      if (!orgId) return [];
      const { data } = await supabase
        .from('customer_balances_summary')
        .select('*')
        .eq('organization_id', orgId)
        .order('customer_name');
      return data || [];
    },
    enabled: Boolean(orgId),
  });

  // 2. Fetch Customer Unpaid Invoices
  const { data: unpaidInvoices = [] } = useQuery({
    queryKey: ['unpaid_invoices', orgId, customerId],
    queryFn: async () => {
      if (!orgId || !customerId) return [];
      const { data, error } = await supabase
        .from('sales')
        .select('*')
        .eq('organization_id', orgId)
        .eq('customer_id', customerId)
        .eq('status', 'confirmed')
        .in('payment_status', ['unpaid', 'partial'])
        .order('sale_date', { ascending: true });

      if (error) throw error;
      return data || [];
    },
    enabled: Boolean(orgId && customerId && modalOpen),
  });

  // 3. Fetch Payments History
  const { data: payments = [], isLoading } = useQuery({
    queryKey: ['payments_list', orgId],
    queryFn: async () => {
      if (!orgId) return [];
      const { data, error } = await supabase
        .from('payments')
        .select(`
          *,
          customers(name)
        `)
        .eq('organization_id', orgId)
        .order('created_at', { ascending: false });

      if (error) throw error;
      return data || [];
    },
    enabled: Boolean(orgId),
  });

  const handleAllocationChange = (saleId: string, val: number) => {
    setAllocations({
      ...allocations,
      [saleId]: val,
    });
  };

  const handleAutoAllocate = () => {
    let remaining = paymentAmount;
    const newAlloc: { [saleId: string]: number } = {};

    for (const inv of unpaidInvoices) {
      if (remaining <= 0) break;
      const due = Number(inv.total_amount) - Number(inv.paid_amount);
      const toAllocate = Math.min(remaining, due);
      newAlloc[inv.id] = toAllocate;
      remaining -= toAllocate;
    }

    setAllocations(newAlloc);
  };

  const handleRecordPayment = async () => {
    if (!currentOrg || !customerId || paymentAmount <= 0) {
      showError('Please select a customer and enter payment amount');
      return;
    }

    const allocList = Object.entries(allocations)
      .filter(([_, amt]) => amt > 0)
      .map(([saleId, amt]) => ({ sale_id: saleId, amount: amt }));

    try {
      setSubmitting(true);
      const idempotencyKey = crypto.randomUUID();

      const { data, error } = await supabase.rpc('record_customer_payment_and_allocate', {
        p_org_id: currentOrg.id,
        p_customer_id: customerId,
        p_amount: paymentAmount,
        p_payment_method: paymentMethod,
        p_allocations: allocList,
        p_reference_number: referenceNumber || null,
        p_notes: notes || null,
        p_idempotency_key: idempotencyKey,
      });

      if (error) throw error;

      showSuccess(`Payment ${data.payment_number} recorded and allocated!`);
      queryClient.invalidateQueries({ queryKey: ['payments_list'] });
      queryClient.invalidateQueries({ queryKey: ['customers'] });
      queryClient.invalidateQueries({ queryKey: ['dashboard_metrics'] });
      queryClient.invalidateQueries({ queryKey: ['sales_history'] });
      setModalOpen(false);
      setPaymentAmount(0);
      setAllocations({});
    } catch (err: any) {
      showError(err.message || 'Failed to record payment');
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <Box>
      <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: { xs: 'flex-start', sm: 'center' }, mb: 3, flexWrap: 'wrap', gap: 2 }}>
        <div>
          <Typography variant="h4" sx={{ fontWeight: 800 }}>
            {t("Customer Payments & Allocations")}</Typography>
          <Typography variant="body2" color="text.secondary">
            {t("Collect lump-sum or invoice-specific customer payments and clear accounts receivable.")}</Typography>
        </div>
        <Button
          variant="contained"
          startIcon={<AddIcon />}
          onClick={() => {
            setCustomerId(customers[0]?.customer_id || '');
            setPaymentAmount(0);
            setAllocations({});
            setModalOpen(true);
          }}
          sx={{ borderRadius: 2, bgcolor: '#0f172a', fontWeight: 600 }}
        >
          {t("Receive Payment")}</Button>
      </Box>

      {/* Table */}
      <Paper elevation={0} sx={{ borderRadius: 3, border: '1px solid #e2e8f0', bgcolor: '#ffffff' }}>
        <TableContainer>
          <Table>
            <TableHead>
              <TableRow>
                <TableCell>{t("Receipt #")}</TableCell>
                <TableCell>{t("Payment Date")}</TableCell>
                <TableCell>{t("Customer")}</TableCell>
                <TableCell>{t("Method")}</TableCell>
                <TableCell align="right">{t("Amount Collected")}</TableCell>
                <TableCell align="right">{t("Allocated")}</TableCell>
                <TableCell>{t("Reference")}</TableCell>
                <TableCell align="center">{t("Status")}</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {isLoading ? (
                <TableRow>
                  <TableCell colSpan={8} align="center" sx={{ py: 6 }}>
                    <CircularProgress size={32} />
                  </TableCell>
                </TableRow>
              ) : payments.length > 0 ? (
                payments.map((p: any) => (
                  <TableRow key={p.id} hover>
                    <TableCell sx={{ fontWeight: 600, color: '#0284c7' }}>{p.payment_number}</TableCell>
                    <TableCell>{p.payment_date}</TableCell>
                    <TableCell sx={{ fontWeight: 500 }}>{p.customers?.name}</TableCell>
                    <TableCell>
                      <Chip label={p.payment_method.toUpperCase()} size="small" sx={{ height: 20, fontSize: 10 }} />
                    </TableCell>
                    <TableCell align="right" sx={{ fontWeight: 700, color: '#10b981' }}>
                      {formatCurrency(p.amount)}
                    </TableCell>
                    <TableCell align="right">{formatCurrency(p.allocated_amount)}</TableCell>
                    <TableCell>{p.reference_number || '-'}</TableCell>
                    <TableCell align="center">
                      <Chip
                        label={p.status.toUpperCase()}
                        size="small"
                        color={p.status === 'posted' ? 'success' : 'default'}
                        sx={{ height: 22, fontSize: 11, fontWeight: 600 }}
                      />
                    </TableCell>
                  </TableRow>
                ))
              ) : (
                <TableRow>
                  <TableCell colSpan={8} align="center" sx={{ py: 6, color: 'text.secondary' }}>
                    No payments recorded yet. Click &quot;Receive Payment&quot; to collect funds.
                  </TableCell>
                </TableRow>
              )}
            </TableBody>
          </Table>
        </TableContainer>
      </Paper>

      {/* Receive Payment Modal */}
      <Dialog open={modalOpen} onClose={() => setModalOpen(false)} maxWidth="md" fullWidth>
        <DialogTitle sx={{ fontWeight: 700 }}>{t("Receive Customer Payment")}</DialogTitle>
        <DialogContent dividers>
          <Grid container spacing={2} sx={{ mb: 3 }}>
            <Grid item xs={12} sm={6}>
              <TextField
                fullWidth
                size="small"
                select
                label={t("Customer")}
                value={customerId}
                onChange={(e) => setCustomerId(e.target.value)}
              >
                {customers.map((c: any) => (
                  <MenuItem key={c.customer_id} value={c.customer_id}>
                    {c.customer_name} (Balance: {formatCurrency(c.current_balance)})
                  </MenuItem>
                ))}
              </TextField>
            </Grid>
            <Grid item xs={12} sm={6}>
              <TextField
                fullWidth
                size="small"
                type="number"
                label={t("Payment Amount Received (MMK)")}
                value={paymentAmount}
                onChange={(e) => setPaymentAmount(Number(e.target.value))}
              />
            </Grid>
            <Grid item xs={12} sm={6}>
              <TextField
                fullWidth
                size="small"
                select
                label={t("Payment Method")}
                value={paymentMethod}
                onChange={(e) => setPaymentMethod(e.target.value)}
              >
                <MenuItem value="cash">{t("Cash")}</MenuItem>
                <MenuItem value="kbz_pay">KBZPay</MenuItem>
                <MenuItem value="wave_pay">WavePay</MenuItem>
                <MenuItem value="bank_transfer">Bank Transfer (AYA/CB/KBZ)</MenuItem>
              </TextField>
            </Grid>
            <Grid item xs={12} sm={6}>
              <TextField
                fullWidth
                size="small"
                label="Transaction Reference"
                placeholder="e.g. KBZPay Trx ID 982341..."
                value={referenceNumber}
                onChange={(e) => setReferenceNumber(e.target.value)}
              />
            </Grid>
            <Grid item xs={12}>
              <TextField
                fullWidth
                size="small"
                label="Payment Notes"
                placeholder="e.g. Settlement for October delivery"
                value={notes}
                onChange={(e) => setNotes(e.target.value)}
              />
            </Grid>
          </Grid>

          <Divider sx={{ my: 2 }} />

          {/* Allocation Section */}
          <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', mb: 1.5 }}>
            <Typography variant="subtitle2" sx={{ fontWeight: 700 }}>
              {t("Allocate Payment Across Open Invoices:")}</Typography>
            <Button size="small" variant="outlined" onClick={handleAutoAllocate} disabled={paymentAmount <= 0}>
              {t("Auto-Allocate (FIFO)")}</Button>
          </Box>

          <TableContainer component={Paper} elevation={0} sx={{ border: '1px solid #e2e8f0', mb: 2 }}>
            <Table size="small">
              <TableHead>
                <TableRow>
                  <TableCell>{t("Invoice #")}</TableCell>
                  <TableCell>{t("Date")}</TableCell>
                  <TableCell align="right">Invoice Total</TableCell>
                  <TableCell align="right">Already Paid</TableCell>
                  <TableCell align="right">Remaining Due</TableCell>
                  <TableCell align="right" sx={{ width: 140 }}>Allocate (MMK)</TableCell>
                </TableRow>
              </TableHead>
              <TableBody>
                {unpaidInvoices.length > 0 ? (
                  unpaidInvoices.map((inv: any) => {
                    const remainingDue = Number(inv.total_amount) - Number(inv.paid_amount);
                    return (
                      <TableRow key={inv.id}>
                        <TableCell sx={{ fontWeight: 600 }}>{inv.invoice_number}</TableCell>
                        <TableCell>{inv.sale_date}</TableCell>
                        <TableCell align="right">{formatCurrency(inv.total_amount)}</TableCell>
                        <TableCell align="right">{formatCurrency(inv.paid_amount)}</TableCell>
                        <TableCell align="right" sx={{ fontWeight: 700, color: '#d97706' }}>
                          {formatCurrency(remainingDue)}
                        </TableCell>
                        <TableCell align="right">
                          <TextField
                            size="small"
                            type="number"
                            value={allocations[inv.id] || ''}
                            placeholder="0"
                            onChange={(e) => handleAllocationChange(inv.id, Number(e.target.value))}
                            inputProps={{ max: remainingDue, style: { padding: '4px 8px', textAlign: 'right' } }}
                          />
                        </TableCell>
                      </TableRow>
                    );
                  })
                ) : (
                  <TableRow>
                    <TableCell colSpan={6} align="center" sx={{ py: 3, color: 'text.secondary' }}>
                      {t("No unpaid invoices found for this customer. Payment will be credited to customer account.")}</TableCell>
                  </TableRow>
                )}
              </TableBody>
            </Table>
          </TableContainer>
        </DialogContent>
        <DialogActions sx={{ px: 3, py: 2 }}>
          <Button onClick={() => setModalOpen(false)} disabled={submitting}>
            {t("Cancel")}</Button>
          <Button
            variant="contained"
            disabled={submitting || paymentAmount <= 0}
            onClick={handleRecordPayment}
            sx={{ bgcolor: '#0f172a', fontWeight: 600 }}
          >
            {submitting ? <CircularProgress size={20} color="inherit" /> : 'Record & Allocate'}
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
};
