import React, { useEffect, useState } from 'react';
import {
  Box,
  Typography,
  Button,
  Paper,
  Grid,
  TextField,
  MenuItem,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
  IconButton,
  Chip,
  Dialog,
  DialogTitle,
  DialogContent,
  DialogActions,
  CircularProgress,
  Divider,
  Alert,
} from '@mui/material';
import DeleteIcon from '@mui/icons-material/Delete';
import PrintIcon from '@mui/icons-material/Print';
import BlockIcon from '@mui/icons-material/Block';
import CheckCircleIcon from '@mui/icons-material/CheckCircle';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/lib/supabase';
import { useOrg } from '@/context/OrgContext';
import { useNotification } from '@/context/NotificationContext';
import { InvoiceReceiptModal } from './InvoiceReceiptModal';
import { useEntitlements } from '@/modules/subscription/useEntitlements';
import { useNavigate } from 'react-router-dom';
import { useI18n } from '@/i18n/I18nContext';

interface CartItem {
  productId: string;
  name: string;
  sku: string;
  quantity: number;
  unitPrice: number;
  unitCost: number;
  availableStock: number;
}

export const SalesPage: React.FC = () => {
  const { t } = useI18n();
  const { currentOrg, formatCurrency } = useOrg();
  const { showSuccess, showError } = useNotification();
  const queryClient = useQueryClient();
  const navigate = useNavigate();
  const { data: entitlements = [] } = useEntitlements();
  const canUseCredit = entitlements.some((item) => item.feature_key === 'credit_sales' && item.is_allowed);
  const canUsePartial = entitlements.some((item) => item.feature_key === 'partial_payments' && item.is_allowed);
  const canEstimateProfit = entitlements.some((item) => item.feature_key === 'profit_estimation' && item.is_allowed);
  const orgId = currentOrg?.id;

  // POS State
  const [selectedCustomerId, setSelectedCustomerId] = useState('');
  const [cart, setCart] = useState<CartItem[]>([]);
  const [discountAmount, setDiscountAmount] = useState<number>(0);
  const [paymentType, setPaymentType] = useState<'cash' | 'partial' | 'credit'>('cash');
  const [paidAmount, setPaidAmount] = useState<number>(0);
  const [paymentMethod, setPaymentMethod] = useState('cash');
  const [selectedBranchId, setSelectedBranchId] = useState('');
  const [confirming, setConfirming] = useState(false);

  // Modals
  const [receiptSale, setReceiptSale] = useState<any>(null);
  const [voidDialogOpen, setVoidDialogOpen] = useState(false);
  const [saleToVoid, setSaleToVoid] = useState<any>(null);
  const [voidReason, setVoidReason] = useState('');
  const [voiding, setVoiding] = useState(false);

  // 1. Fetch Customers
  const { data: customers = [] } = useQuery({
    queryKey: ['customers_select', orgId],
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

  const { data: branches = [] } = useQuery({
    queryKey: ['branches', orgId],
    queryFn: async () => {
      if (!orgId) return [];
      const { data, error } = await supabase.from('branches' as any).select('id,name,is_default')
        .eq('organization_id', orgId).eq('is_active', true).order('is_default', { ascending: false }).order('name');
      if (error) throw error;
      return data ?? [];
    },
    enabled: Boolean(orgId),
  });
  useEffect(() => {
    if (branches.length && !branches.some((branch: any) => branch.id === selectedBranchId)) {
      setSelectedBranchId(branches.find((branch: any) => branch.is_default)?.id ?? branches[0].id);
    }
  }, [branches, selectedBranchId]);

  // 2. Fetch Products with current stock
  const { data: products = [] } = useQuery({
    queryKey: ['products_for_pos', orgId, selectedBranchId],
    queryFn: async () => {
      if (!orgId || !selectedBranchId) return [];
      const { data, error } = await (supabase as any).from('branch_stock_balances').select('*')
        .eq('organization_id', orgId).eq('branch_id', selectedBranchId)
        .gt('stock_on_hand', 0)
        .order('name');
      if (error) throw error;
      return data || [];
    },
    enabled: Boolean(orgId && selectedBranchId),
  });

  // 3. Fetch Sales History
  const { data: salesHistory = [], isLoading: salesLoading } = useQuery({
    queryKey: ['sales_history', orgId],
    queryFn: async () => {
      if (!orgId) return [];
      const { data, error } = await supabase
        .from('sales')
        .select(`
          *,
          customers(name),
          sale_items(
            id, quantity, unit_price, total_amount,
            products(name, sku)
          )
        `)
        .eq('organization_id', orgId)
        .order('created_at', { ascending: false })
        .limit(30);

      if (error) throw error;
      return data || [];
    },
    enabled: Boolean(orgId),
  });

  const handleAddToCart = (pId: string) => {
    const prod = products.find((p: any) => p.product_id === pId);
    if (!prod) return;

    const existingIndex = cart.findIndex((item) => item.productId === pId);
    if (existingIndex > -1) {
      const updated = [...cart];
      if (updated[existingIndex].quantity < prod.stock_on_hand) {
        updated[existingIndex].quantity += 1;
        setCart(updated);
      } else {
        showError(`Max available stock is ${prod.stock_on_hand}`);
      }
    } else {
      setCart([
        ...cart,
        {
          productId: prod.product_id,
          name: prod.name,
          sku: prod.sku,
          quantity: 1,
          unitPrice: Number(prod.sale_price),
          unitCost: Number(prod.average_cost),
          availableStock: Number(prod.stock_on_hand),
        },
      ]);
    }
  };

  const handleUpdateQty = (index: number, newQty: number) => {
    if (newQty <= 0) return;
    const updated = [...cart];
    if (newQty > updated[index].availableStock) {
      showError(`Only ${updated[index].availableStock} available in stock`);
      return;
    }
    updated[index].quantity = newQty;
    setCart(updated);
  };

  const handleRemoveFromCart = (index: number) => {
    setCart(cart.filter((_, i) => i !== index));
  };

  const subtotal = cart.reduce((acc, it) => acc + (it.quantity * it.unitPrice), 0);
  const totalDue = Math.max(0, subtotal - discountAmount);
  const estimatedGrossProfit = cart.reduce((acc, item) => acc + item.quantity * (item.unitPrice - item.unitCost), 0) - discountAmount;

  const handleConfirmSale = async () => {
    if (!currentOrg) return;
    if (cart.length === 0) {
      showError('Please add items to cart');
      return;
    }

    if (paymentType === 'credit' && !selectedCustomerId) {
      showError('Please select a customer for credit sales');
      return;
    }

    let actualPaid = 0;
    if (paymentType === 'cash') {
      actualPaid = totalDue;
    } else if (paymentType === 'partial') {
      actualPaid = Number(paidAmount);
    }

    try {
      setConfirming(true);
      const idempotencyKey = crypto.randomUUID();

      // 1. Generate Next Invoice Number
      const invNumRes = await supabase.rpc('next_document_number', {
        p_org_id: currentOrg.id,
        p_doc_type: 'sale',
      });
      const invoiceNum = invNumRes.data;

      // 2. Create Draft Sale
      const { data: saleData, error: saleErr } = await supabase
        .from('sales')
        .insert({
          organization_id: currentOrg.id,
          branch_id: selectedBranchId,
          customer_id: selectedCustomerId || null,
          invoice_number: invoiceNum,
          status: 'draft',
          subtotal: subtotal,
          discount_amount: discountAmount,
          total_amount: totalDue,
          paid_amount: 0,
        } as any)
        .select()
        .single();

      if (saleErr) throw saleErr;

      // 3. Create Sale Items
      const itemRows = cart.map((it) => ({
        organization_id: currentOrg.id,
        sale_id: saleData.id,
        product_id: it.productId,
        quantity: it.quantity,
        unit_price: it.unitPrice,
        discount_amount: 0,
        total_amount: it.quantity * it.unitPrice,
      }));

      const { error: itemsErr } = await supabase.from('sale_items').insert(itemRows as any);
      if (itemsErr) throw itemsErr;

      // 4. Atomic Confirm Sale RPC
      const { error: confirmErr } = await supabase.rpc('confirm_sale', {
        p_org_id: currentOrg.id,
        p_sale_id: saleData.id,
        p_payment_method: paymentMethod,
        p_amount_paid: actualPaid,
        p_idempotency_key: idempotencyKey,
      });

      if (confirmErr) throw confirmErr;

      showSuccess(`Invoice ${invoiceNum} confirmed!`);

      // Open printable receipt
      setReceiptSale({
        ...saleData,
        invoice_number: invoiceNum,
        total_amount: totalDue,
        paid_amount: actualPaid,
        customer_name: customers.find((c: any) => c.customer_id === selectedCustomerId)?.customer_name,
        payment_status: actualPaid >= totalDue ? 'paid' : actualPaid > 0 ? 'partial' : 'unpaid',
        items: cart,
      });

      // Clear cart
      setCart([]);
      setDiscountAmount(0);
      setPaidAmount(0);
      setSelectedCustomerId('');

      // Refresh queries
      queryClient.invalidateQueries({ queryKey: ['sales_history'] });
      queryClient.invalidateQueries({ queryKey: ['products_for_pos'] });
      queryClient.invalidateQueries({ queryKey: ['branch_stock_balances'] });
      queryClient.invalidateQueries({ queryKey: ['product_stock_balances'] });
      queryClient.invalidateQueries({ queryKey: ['dashboard_metrics'] });
      queryClient.invalidateQueries({ queryKey: ['customers'] });
    } catch (err: any) {
      showError(err.message || 'Failed to confirm sale');
    } finally {
      setConfirming(false);
    }
  };

  const handleVoidSale = async () => {
    if (!currentOrg || !saleToVoid || !voidReason.trim()) return;

    try {
      setVoiding(true);
      const { error } = await supabase.rpc('void_or_reverse_sale', {
        p_org_id: currentOrg.id,
        p_sale_id: saleToVoid.id,
        p_reason: voidReason.trim(),
      });

      if (error) throw error;

      showSuccess(`Sale ${saleToVoid.invoice_number} reversed and stock returned to ledger!`);
      queryClient.invalidateQueries({ queryKey: ['sales_history'] });
      queryClient.invalidateQueries({ queryKey: ['stock_balances'] });
      queryClient.invalidateQueries({ queryKey: ['branch_stock_balances'] });
      queryClient.invalidateQueries({ queryKey: ['products_for_pos'] });
      queryClient.invalidateQueries({ queryKey: ['dashboard_metrics'] });
      setVoidDialogOpen(false);
      setSaleToVoid(null);
      setVoidReason('');
    } catch (err: any) {
      showError(err.message || 'Failed to void sale');
    } finally {
      setVoiding(false);
    }
  };

  return (
    <Box>
      <Box sx={{ mb: 3 }}>
        <Typography variant="h4" sx={{ fontWeight: 800 }}>
          {t("Sales Register & Invoicing")}</Typography>
        <Typography variant="body2" color="text.secondary">
          {t("Fast checkout, stock-aware cart, multi-payment options, and invoice printing.")}</Typography>
      </Box>

      {branches.length > 1 && <Box sx={{ mb: 2, maxWidth: 340 }}>
        <TextField select fullWidth size="small" label={t('Sales Branch')} value={selectedBranchId} onChange={(event) => { setSelectedBranchId(event.target.value); setCart([]); }}>
          {branches.map((branch: any) => <MenuItem key={branch.id} value={branch.id}>{branch.name}</MenuItem>)}
        </TextField>
      </Box>}

      {/* POS Register Section */}
      <Grid container spacing={3} sx={{ mb: 4 }}>
        {/* Left: Product Selector */}
        <Grid item xs={12} md={7}>
          <Paper elevation={0} sx={{ p: 2.5, borderRadius: 3, border: '1px solid #e2e8f0', bgcolor: '#ffffff', height: '100%' }}>
            <Typography variant="subtitle1" sx={{ fontWeight: 700, mb: 1.5 }}>
              {t("Available Products for Sale")}</Typography>

            <Grid container spacing={1.5}>
              {products.map((p: any) => (
                <Grid item xs={12} sm={6} key={p.product_id}>
                  <Box
                    onClick={() => handleAddToCart(p.product_id)}
                    sx={{
                      p: 1.5,
                      borderRadius: 2,
                      border: '1px solid #e2e8f0',
                      cursor: 'pointer',
                      transition: 'all 0.15s',
                      '&:hover': { borderColor: '#0284c7', bgcolor: '#f0f9ff' },
                    }}
                  >
                    <Typography variant="subtitle2" sx={{ fontWeight: 700 }} noWrap>
                      {p.name}
                    </Typography>
                    <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', mt: 0.5 }}>
                      <Typography variant="body2" sx={{ fontWeight: 800, color: '#0284c7' }}>
                        {formatCurrency(p.sale_price)}
                      </Typography>
                      <Chip
                        label={`${p.stock_on_hand} ${p.unit_code}`}
                        size="small"
                        sx={{ height: 20, fontSize: 10, bgcolor: '#f1f5f9' }}
                      />
                    </Box>
                  </Box>
                </Grid>
              ))}
            </Grid>
          </Paper>
        </Grid>

        {/* Right: Cart & Payment */}
        <Grid item xs={12} md={5}>
          <Paper elevation={0} sx={{ p: 2.5, borderRadius: 3, border: '1px solid #e2e8f0', bgcolor: '#ffffff' }}>
            <Typography variant="subtitle1" sx={{ fontWeight: 700, mb: 2 }}>
              {t("Current Cart")}</Typography>

            {/* Customer Selector */}
            <TextField
              fullWidth
              size="small"
              select
              label={t("Select Customer (Optional for Cash)")}
              value={selectedCustomerId}
              onChange={(e) => setSelectedCustomerId(e.target.value)}
              sx={{ mb: 2 }}
            >
              <MenuItem value="">{t("-- Walk-in Customer --")}</MenuItem>
              {customers.map((c: any) => (
                <MenuItem key={c.customer_id} value={c.customer_id}>
                  {c.customer_name} (Bal: {formatCurrency(c.current_balance)})
                </MenuItem>
              ))}
            </TextField>

            {/* Cart Items */}
            <TableContainer sx={{ maxHeight: 220, mb: 2 }}>
              <Table size="small">
                <TableBody>
                  {cart.map((item, idx) => (
                    <TableRow key={idx}>
                      <TableCell sx={{ p: 1 }}>
                        <Typography variant="body2" sx={{ fontWeight: 600 }}>
                          {item.name}
                        </Typography>
                        <Typography variant="caption" color="text.secondary">
                          {formatCurrency(item.unitPrice)} {t("each")}</Typography>
                      </TableCell>
                      <TableCell align="center" sx={{ p: 1, width: 80 }}>
                        <TextField
                          type="number"
                          size="small"
                          value={item.quantity}
                          onChange={(e) => handleUpdateQty(idx, Number(e.target.value))}
                          inputProps={{ min: 1, style: { padding: '4px 6px', textAlign: 'center' } }}
                        />
                      </TableCell>
                      <TableCell align="right" sx={{ p: 1, fontWeight: 700 }}>
                        {formatCurrency(item.quantity * item.unitPrice)}
                      </TableCell>
                      <TableCell align="right" sx={{ p: 0.5, width: 36 }}>
                        <IconButton size="small" color="error" onClick={() => handleRemoveFromCart(idx)}>
                          <DeleteIcon fontSize="small" />
                        </IconButton>
                      </TableCell>
                    </TableRow>
                  ))}
                  {cart.length === 0 && (
                    <TableRow>
                      <TableCell colSpan={4} align="center" sx={{ py: 3, color: 'text.secondary' }}>
                        {t("Cart is empty. Click a product to add.")}</TableCell>
                    </TableRow>
                  )}
                </TableBody>
              </Table>
            </TableContainer>

            <Divider sx={{ my: 1.5 }} />

            {/* Calculation summary */}
            <Box sx={{ display: 'flex', justifyContent: 'space-between', mb: 1 }}>
              <Typography variant="body2" color="text.secondary">{t("Subtotal:")}</Typography>
              <Typography variant="body2" sx={{ fontWeight: 600 }}>{formatCurrency(subtotal)}</Typography>
            </Box>

            <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', mb: 1.5 }}>
              <Typography variant="body2" color="text.secondary">{t("Discount (MMK):")}</Typography>
              <TextField
                type="number"
                size="small"
                value={discountAmount}
                onChange={(e) => setDiscountAmount(Number(e.target.value))}
                sx={{ width: 120 }}
                inputProps={{ style: { padding: '4px 8px', textAlign: 'right' } }}
              />
            </Box>

            <Box sx={{ display: 'flex', justifyContent: 'space-between', mb: 2 }}>
              <Typography variant="subtitle1" sx={{ fontWeight: 800 }}>{t("Total Due:")}</Typography>
              <Typography variant="h5" sx={{ fontWeight: 800, color: '#0f172a' }}>{formatCurrency(totalDue)}</Typography>
            </Box>
            {canEstimateProfit && <Box sx={{ display: 'flex', justifyContent: 'space-between', mb: 2 }}>
              <Typography variant="body2" color="text.secondary">{t('Estimated Gross Profit')}:</Typography>
              <Typography variant="body2" fontWeight={700} color={estimatedGrossProfit >= 0 ? 'success.main' : 'error.main'}>{formatCurrency(estimatedGrossProfit)}</Typography>
            </Box>}

            {/* Payment Options */}
            <Typography variant="caption" sx={{ fontWeight: 700, color: '#64748b', display: 'block', mb: 1 }}>
              {t("PAYMENT TERMS")}</Typography>

            <Grid container spacing={1} sx={{ mb: 2 }}>
              <Grid item xs={4}>
                <Button
                  fullWidth
                  size="small"
                  variant={paymentType === 'cash' ? 'contained' : 'outlined'}
                  onClick={() => setPaymentType('cash')}
                  sx={{ borderRadius: 2, fontSize: 12 }}
                >
                  {t("Full Cash")}</Button>
              </Grid>
              <Grid item xs={4}>
                <Button
                  fullWidth
                  size="small"
                  variant={paymentType === 'partial' ? 'contained' : 'outlined'}
                  disabled={!canUsePartial}
                  onClick={() => setPaymentType('partial')}
                  sx={{ borderRadius: 2, fontSize: 12 }}
                >
                  {t("Partial Paid")}</Button>
              </Grid>
              <Grid item xs={4}>
                <Button
                  fullWidth
                  size="small"
                  variant={paymentType === 'credit' ? 'contained' : 'outlined'}
                  disabled={!canUseCredit}
                  onClick={() => setPaymentType('credit')}
                  sx={{ borderRadius: 2, fontSize: 12 }}
                >
                  {t("Full Credit")}</Button>
              </Grid>
            </Grid>

            {(!canUseCredit || !canUsePartial) && <Box sx={{ mb: 2 }}>
              <Alert severity="info" action={<Button size="small" color="inherit" onClick={() => navigate('/app/subscription')}>{t("Compare plans")}</Button>}>
                {!canUseCredit && !canUsePartial ? 'Credit sales and partial payments' : !canUseCredit ? 'Credit sales' : 'Partial payments'} are available on higher plans.
              </Alert>
            </Box>}

            {paymentType === 'partial' && (
              <TextField
                fullWidth
                size="small"
                type="number"
                label={t("Amount Collected Now (MMK)")}
                value={paidAmount}
                onChange={(e) => setPaidAmount(Number(e.target.value))}
                sx={{ mb: 2 }}
              />
            )}

            {paymentType !== 'credit' && (
              <TextField
                fullWidth
                size="small"
                select
                label={t("Payment Method")}
                value={paymentMethod}
                onChange={(e) => setPaymentMethod(e.target.value)}
                sx={{ mb: 2 }}
              >
                <MenuItem value="cash">{t("Cash")}</MenuItem>
                <MenuItem value="kbz_pay">KBZPay</MenuItem>
                <MenuItem value="wave_pay">WavePay</MenuItem>
                <MenuItem value="bank_transfer">{t("Bank Transfer")}</MenuItem>
              </TextField>
            )}

            <Button
              fullWidth
              variant="contained"
              size="large"
              disabled={confirming || cart.length === 0}
              onClick={handleConfirmSale}
              startIcon={<CheckCircleIcon />}
              sx={{ py: 1.4, borderRadius: 2, fontWeight: 700, bgcolor: '#0284c7', '&:hover': { bgcolor: '#0369a1' } }}
            >
              {confirming ? <CircularProgress size={24} color="inherit" /> : 'Confirm Sale & Print'}
            </Button>
          </Paper>
        </Grid>
      </Grid>

      {/* Sales Invoices History */}
      <Paper elevation={0} sx={{ p: 3, borderRadius: 3, border: '1px solid #e2e8f0', bgcolor: '#ffffff' }}>
        <Typography variant="h6" sx={{ fontWeight: 700, mb: 2 }}>
          {t("Sales Invoices & Reversal History")}</Typography>

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
                <TableCell align="center">Actions</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {salesLoading ? (
                <TableRow>
                  <TableCell colSpan={8} align="center" sx={{ py: 4 }}>
                    <CircularProgress size={28} />
                  </TableCell>
                </TableRow>
              ) : salesHistory.length > 0 ? (
                salesHistory.map((s: any) => (
                  <TableRow key={s.id} hover>
                    <TableCell sx={{ fontWeight: 600, color: '#0284c7' }}>{s.invoice_number}</TableCell>
                    <TableCell>{s.sale_date}</TableCell>
                    <TableCell>{s.customers?.name || 'Walk-in'}</TableCell>
                    <TableCell align="right" sx={{ fontWeight: 700 }}>
                      {formatCurrency(s.total_amount)}
                    </TableCell>
                    <TableCell align="right">{formatCurrency(s.paid_amount)}</TableCell>
                    <TableCell align="center">
                      <Chip
                        label={s.payment_status}
                        size="small"
                        color={
                          s.payment_status === 'paid'
                            ? 'success'
                            : s.payment_status === 'partial'
                            ? 'warning'
                            : 'default'
                        }
                        sx={{ height: 22, fontSize: 11, fontWeight: 600 }}
                      />
                    </TableCell>
                    <TableCell align="center">
                      <Chip
                        label={s.status.toUpperCase()}
                        size="small"
                        color={s.status === 'confirmed' ? 'primary' : 'error'}
                        variant={s.status === 'confirmed' ? 'filled' : 'outlined'}
                        sx={{ height: 22, fontSize: 11, fontWeight: 700 }}
                      />
                    </TableCell>
                    <TableCell align="center">
                      <IconButton
                        size="small"
                        onClick={() =>
                          setReceiptSale({
                            ...s,
                            customer_name: s.customers?.name,
                            items: s.sale_items?.map((it: any) => ({
                              product_name: it.products?.name,
                              quantity: it.quantity,
                              unit_price: it.unit_price,
                              total_amount: it.total_amount,
                            })),
                          })
                        }
                      >
                        <PrintIcon fontSize="small" />
                      </IconButton>

                      {s.status === 'confirmed' && (
                        <IconButton
                          size="small"
                          color="error"
                          title="Void / Reverse Sale"
                          onClick={() => {
                            setSaleToVoid(s);
                            setVoidDialogOpen(true);
                          }}
                        >
                          <BlockIcon fontSize="small" />
                        </IconButton>
                      )}
                    </TableCell>
                  </TableRow>
                ))
              ) : (
                <TableRow>
                  <TableCell colSpan={8} align="center" sx={{ py: 4, color: 'text.secondary' }}>
                    {t("No sales recorded.")}</TableCell>
                </TableRow>
              )}
            </TableBody>
          </Table>
        </TableContainer>
      </Paper>

      {/* Printable Receipt Modal */}
      <InvoiceReceiptModal
        open={Boolean(receiptSale)}
        onClose={() => setReceiptSale(null)}
        sale={receiptSale}
      />

      {/* Void Dialog */}
      <Dialog open={voidDialogOpen} onClose={() => setVoidDialogOpen(false)} maxWidth="xs" fullWidth>
        <DialogTitle sx={{ fontWeight: 700, color: 'error.main' }}>
          Void Sale Invoice: {saleToVoid?.invoice_number}
        </DialogTitle>
        <DialogContent dividers>
          <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
            Voiding this sale will return all items back into stock movements via compensatory reversal entries and recalculate customer ledger balances.
          </Typography>

          <TextField
            fullWidth
            size="small"
            label="Mandatory Reason for Reversal"
            placeholder="e.g. Customer returned items, wrong order entry"
            value={voidReason}
            onChange={(e) => setVoidReason(e.target.value)}
          />
        </DialogContent>
        <DialogActions sx={{ px: 3, py: 2 }}>
          <Button onClick={() => setVoidDialogOpen(false)} disabled={voiding}>
            {t("Cancel")}</Button>
          <Button
            variant="contained"
            color="error"
            disabled={voiding || !voidReason.trim()}
            onClick={handleVoidSale}
            sx={{ fontWeight: 600 }}
          >
            {voiding ? <CircularProgress size={20} color="inherit" /> : 'Confirm Reversal'}
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
};
