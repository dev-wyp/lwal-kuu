import React, { useEffect, useState } from 'react';
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
  IconButton,
  Divider,
  Alert,
} from '@mui/material';
import AddIcon from '@mui/icons-material/Add';
import DeleteIcon from '@mui/icons-material/Delete';
import CheckCircleIcon from '@mui/icons-material/CheckCircle';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/lib/supabase';
import { useOrg } from '@/context/OrgContext';
import { useNotification } from '@/context/NotificationContext';
import { useI18n } from '@/i18n/I18nContext';
import { localDateString } from '@/lib/dates';

export const PurchasesPage: React.FC = () => {
  const { t } = useI18n();
  const { currentOrg, formatCurrency } = useOrg();
  const { showSuccess, showError } = useNotification();
  const queryClient = useQueryClient();
  const orgId = currentOrg?.id;

  const [createModalOpen, setCreateModalOpen] = useState(false);
  const [receiveModalOpen, setReceiveModalOpen] = useState(false);
  const [selectedPurchase, setSelectedPurchase] = useState<any>(null);

  // New PO State
  const [supplierId, setSupplierId] = useState('');
  const [branchId, setBranchId] = useState('');
  const [purchaseDate, setPurchaseDate] = useState(localDateString());
  const [items, setItems] = useState<Array<{ productId: string; quantity: number; unitCost: number }>>([
    { productId: '', quantity: 1, unitCost: 0 },
  ]);
  const [submitting, setSubmitting] = useState(false);

  // Receive PO State
  const [receivePaidAmount, setReceivePaidAmount] = useState<number>(0);
  const [receivePaymentMethod, setReceivePaymentMethod] = useState('cash');
  const [receiving, setReceiving] = useState(false);

  const { data: branches = [], isError: branchesError } = useQuery({
    queryKey: ['branches', orgId],
    queryFn: async () => {
      if (!orgId) return [];
      const { data, error } = await supabase.from('branches' as any).select('id, name, is_default')
        .eq('organization_id', orgId).eq('is_active', true).order('is_default', { ascending: false }).order('name');
      if (error) throw error;
      return data ?? [];
    },
    enabled: Boolean(orgId),
  });

  useEffect(() => {
    if (!branches.length) return;
    setBranchId((current) => branches.some((branch: any) => branch.id === current)
      ? current
      : (branches.find((branch: any) => branch.is_default) ?? branches[0]).id);
  }, [branches]);

  // 1. Fetch Suppliers
  const { data: suppliers = [], isLoading: suppliersLoading, isError: suppliersError } = useQuery({
    queryKey: ['suppliers_list', orgId],
    queryFn: async () => {
      if (!orgId) return [];
      const { data, error } = await supabase
        .from('suppliers')
        .select('id, name')
        .eq('organization_id', orgId)
        .eq('is_active', true);
      if (error) throw error;
      return data || [];
    },
    enabled: Boolean(orgId),
  });

  // 2. Fetch Products
  const { data: products = [], isLoading: productsLoading, isError: productsError } = useQuery({
    queryKey: ['products_list', orgId],
    queryFn: async () => {
      if (!orgId) return [];
      const { data, error } = await supabase
        .from('products')
        .select('id, name, sku, purchase_price')
        .eq('organization_id', orgId)
        .eq('is_active', true);
      if (error) throw error;
      return data || [];
    },
    enabled: Boolean(orgId),
  });

  // 3. Fetch Purchases
  const { data: purchases = [], isLoading, isError: purchasesError, refetch: refetchPurchases } = useQuery({
    queryKey: ['purchases', orgId],
    queryFn: async () => {
      if (!orgId) return [];
      const { data, error } = await supabase
        .from('purchases')
        .select(`
          *,
          suppliers!purchases_supplier_id_fkey(name)
        `)
        .eq('organization_id', orgId)
        .order('created_at', { ascending: false });
      if (error) throw error;
      return data ?? [];
    },
    enabled: Boolean(orgId),
  });

  const handleAddItem = () => {
    setItems([...items, { productId: '', quantity: 1, unitCost: 0 }]);
  };

  const handleRemoveItem = (index: number) => {
    if (items.length > 1) {
      setItems(items.filter((_, i) => i !== index));
    }
  };

  const handleItemProductChange = (index: number, pId: string) => {
    const prod = products.find((p) => p.id === pId);
    const updated = [...items];
    updated[index].productId = pId;
    if (prod) {
      updated[index].unitCost = Number(prod.purchase_price || 0);
    }
    setItems(updated);
  };

  const handleItemChange = (index: number, field: 'quantity' | 'unitCost', val: number) => {
    const updated = [...items];
    updated[index][field] = val;
    setItems(updated);
  };

  const calculateTotal = () => {
    return items.reduce((acc, it) => it.productId && Number.isFinite(it.quantity) && it.quantity > 0 && Number.isFinite(it.unitCost) && it.unitCost >= 0
      ? acc + (it.quantity * it.unitCost)
      : acc, 0);
  };

  const handleCreatePurchase = async () => {
    if (!currentOrg || !supplierId) {
      showError('Please select a supplier');
      return;
    }

    const invalidItems = items.filter((it) => it.productId && (!Number.isFinite(it.quantity) || it.quantity <= 0 || !Number.isFinite(it.unitCost) || it.unitCost < 0));
    if (invalidItems.length) {
      showError('Each selected product needs a positive quantity and a non-negative unit cost');
      return;
    }
    const validItems = items.filter((it) => it.productId && it.quantity > 0 && it.unitCost >= 0);
    if (validItems.length === 0) {
      showError('Please add at least one product');
      return;
    }

    if (!branchId) {
      showError('Create or activate a branch before receiving stock');
      return;
    }

    try {
      setSubmitting(true);
      const { data, error } = await supabase.rpc('create_purchase_order' as any, {
        p_org_id: currentOrg.id,
        p_supplier_id: supplierId,
        p_branch_id: branchId,
        p_purchase_date: purchaseDate,
        p_items: validItems.map((it) => ({ product_id: it.productId, quantity: it.quantity, unit_cost: it.unitCost })),
      } as any);
      if (error) throw error;

      showSuccess(`Purchase Order ${data.purchase_number} created!`);
      queryClient.invalidateQueries({ queryKey: ['purchases'] });
      setCreateModalOpen(false);
    } catch (err: any) {
      showError(err.message || 'Failed to create purchase order');
    } finally {
      setSubmitting(false);
    }
  };

  const handleOpenReceive = (po: any) => {
    setSelectedPurchase(po);
    setReceivePaidAmount(0);
    setReceiveModalOpen(true);
  };

  const handleConfirmReceive = async () => {
    if (!currentOrg || !selectedPurchase) return;
    const outstanding = Math.max(0, Number(selectedPurchase.total_amount) - Number(selectedPurchase.paid_amount || 0));
    if (!Number.isFinite(receivePaidAmount) || receivePaidAmount < 0 || receivePaidAmount > outstanding) {
      showError('Enter a payment from zero up to the purchase outstanding balance');
      return;
    }

    try {
      setReceiving(true);
      const { error } = await supabase.rpc('receive_purchase', {
        p_org_id: currentOrg.id,
        p_purchase_id: selectedPurchase.id,
        p_amount_paid: receivePaidAmount,
        p_payment_method: receivePaymentMethod,
      });

      if (error) throw error;

      showSuccess(`PO ${selectedPurchase.purchase_number} marked received and stock ledger updated!`);
      queryClient.invalidateQueries({ queryKey: ['purchases'] });
      queryClient.invalidateQueries({ queryKey: ['product_stock_balances'] });
      queryClient.invalidateQueries({ queryKey: ['stock_balances'] });
      queryClient.invalidateQueries({ queryKey: ['branch_stock_balances'] });
      queryClient.invalidateQueries({ queryKey: ['products_for_pos'] });
      queryClient.invalidateQueries({ queryKey: ['dashboard_metrics'] });
      queryClient.invalidateQueries({ queryKey: ['suppliers'] });
      setReceiveModalOpen(false);
    } catch (err: any) {
      showError(err.message || 'Failed to receive purchase');
    } finally {
      setReceiving(false);
    }
  };

  return (
    <Box>
      <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: { xs: 'flex-start', sm: 'center' }, mb: 3, flexWrap: 'wrap', gap: 2 }}>
        <div>
          <Typography variant="h4" sx={{ fontWeight: 800 }}>
            {t("Purchase Orders & Receiving")}</Typography>
          <Typography variant="body2" color="text.secondary">
            {t("Manage vendor shipments, stock receipt, and automated weighted average costing.")}</Typography>
        </div>
        <Button
          variant="contained"
          startIcon={<AddIcon />}
          onClick={() => {
            setSupplierId(suppliers[0]?.id || '');
            setBranchId((branches.find((branch: any) => branch.is_default) ?? branches[0])?.id ?? '');
            setItems([{ productId: '', quantity: 1, unitCost: 0 }]);
            setCreateModalOpen(true);
          }}
          sx={{ borderRadius: 2, bgcolor: '#0f172a', fontWeight: 600 }}
        >
          {t("New Purchase Order")}</Button>
      </Box>

      {purchasesError && <Alert severity="error" sx={{ mb: 2 }} action={<Button color="inherit" size="small" onClick={() => void refetchPurchases()}>{t('Try again')}</Button>}>
        {t('Purchase history could not be loaded. Check your connection and try again.')}
      </Alert>}
      {(suppliersError || productsError || branchesError) && <Alert severity="error" sx={{ mb: 2 }}>
        {t('Supplier, branch, or product information could not be loaded. Refresh the page or check your connection.')}
      </Alert>}

      {/* Table */}
      <Paper elevation={0} sx={{ borderRadius: 3, border: '1px solid #e2e8f0', bgcolor: '#ffffff' }}>
        <TableContainer>
          <Table>
            <TableHead>
              <TableRow>
                <TableCell>{t("PO Number")}</TableCell>
                <TableCell>{t("Date")}</TableCell>
                <TableCell>{t("Supplier")}</TableCell>
                <TableCell align="right">{t("Total Amount")}</TableCell>
                <TableCell align="right">{t("Paid Upfront")}</TableCell>
                <TableCell align="center">{t("Status")}</TableCell>
                <TableCell align="center">Actions</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {isLoading ? (
                <TableRow>
                  <TableCell colSpan={7} align="center" sx={{ py: 6 }}>
                    <CircularProgress size={32} />
                  </TableCell>
                </TableRow>
              ) : purchases.length > 0 ? (
                purchases.map((po: any) => (
                  <TableRow key={po.id} hover>
                    <TableCell sx={{ fontWeight: 600, color: '#0284c7' }}>{po.purchase_number}</TableCell>
                    <TableCell>{po.purchase_date}</TableCell>
                    <TableCell sx={{ fontWeight: 500 }}>{po.suppliers?.name || 'Vendor'}</TableCell>
                    <TableCell align="right" sx={{ fontWeight: 700 }}>
                      {formatCurrency(po.total_amount)}
                    </TableCell>
                    <TableCell align="right">{formatCurrency(po.paid_amount)}</TableCell>
                    <TableCell align="center">
                      <Chip
                        label={po.status.toUpperCase()}
                        size="small"
                        color={po.status === 'received' ? 'success' : po.status === 'ordered' ? 'warning' : 'default'}
                        sx={{ height: 22, fontSize: 11, fontWeight: 700 }}
                      />
                    </TableCell>
                    <TableCell align="center">
                      {po.status === 'ordered' && (
                        <Button
                          size="small"
                          variant="contained"
                          color="success"
                          startIcon={<CheckCircleIcon fontSize="small" />}
                          onClick={() => handleOpenReceive(po)}
                          sx={{ borderRadius: 2, py: 0.4, fontSize: 12, fontWeight: 600 }}
                        >
                          {t("Receive Goods")}</Button>
                      )}
                    </TableCell>
                  </TableRow>
                ))
              ) : (
                <TableRow>
                  <TableCell colSpan={7} align="center" sx={{ py: 6, color: 'text.secondary' }}>
                    No purchase orders recorded yet. Click &quot;New Purchase Order&quot; to order stock.
                  </TableCell>
                </TableRow>
              )}
            </TableBody>
          </Table>
        </TableContainer>
      </Paper>

      {/* New Purchase Modal */}
      <Dialog open={createModalOpen} onClose={() => setCreateModalOpen(false)} maxWidth="md" fullWidth>
        <DialogTitle sx={{ fontWeight: 700 }}>{t("New Purchase Order")}</DialogTitle>
        <DialogContent dividers>
          <Grid container spacing={2} sx={{ mb: 3 }}>
            <Grid item xs={12} sm={6}>
              <TextField
                fullWidth
                size="small"
                select
                label={t("Supplier")}
                value={supplierId}
                onChange={(e) => setSupplierId(e.target.value)}
              >
                {suppliers.map((s) => (
                  <MenuItem key={s.id} value={s.id}>
                    {s.name}
                  </MenuItem>
                ))}
              </TextField>
            </Grid>
            <Grid item xs={12} sm={6}>
              <TextField fullWidth size="small" select label={t('Branch')} value={branchId} onChange={(e) => setBranchId(e.target.value)}>
                {branches.map((branch: any) => <MenuItem key={branch.id} value={branch.id}>{branch.name}</MenuItem>)}
              </TextField>
            </Grid>
            <Grid item xs={12} sm={6}>
              <TextField
                fullWidth
                size="small"
                type="date"
                label={t("Order Date")}
                value={purchaseDate}
                onChange={(e) => setPurchaseDate(e.target.value)}
                InputLabelProps={{ shrink: true }}
              />
            </Grid>
          </Grid>

          <Typography variant="subtitle2" sx={{ fontWeight: 700, mb: 1 }}>
            {t("Line Items:")}</Typography>

          {items.map((item, idx) => (
            <Grid container spacing={1.5} key={idx} sx={{ mb: 1.5 }} alignItems="center">
              <Grid item xs={12} sm={5}>
                <TextField
                  fullWidth
                  size="small"
                  select
                  label={t("Select Product")}
                  value={item.productId}
                  onChange={(e) => handleItemProductChange(idx, e.target.value)}
                >
                  {products.map((p) => (
                    <MenuItem key={p.id} value={p.id}>
                      {p.name} ({p.sku})
                    </MenuItem>
                  ))}
                </TextField>
              </Grid>
              <Grid item xs={5} sm={3}>
                <TextField
                  fullWidth
                  size="small"
                  type="number"
                  label={t("Quantity")}
                  value={item.quantity}
                  onChange={(e) => handleItemChange(idx, 'quantity', Number(e.target.value))}
                />
              </Grid>
              <Grid item xs={5} sm={3}>
                <TextField
                  fullWidth
                  size="small"
                  type="number"
                  label="Unit Cost (MMK)"
                  value={item.unitCost}
                  onChange={(e) => handleItemChange(idx, 'unitCost', Number(e.target.value))}
                />
              </Grid>
              <Grid item xs={2} sm={1}>
                <IconButton aria-label={t('Remove item')} size="small" color="error" onClick={() => handleRemoveItem(idx)}>
                  <DeleteIcon fontSize="small" />
                </IconButton>
              </Grid>
            </Grid>
          ))}

          <Button size="small" onClick={handleAddItem} sx={{ mt: 1 }}>
            {t("+ Add Another Item")}</Button>

          <Divider sx={{ my: 2 }} />
          <Box sx={{ display: 'flex', justifyContent: 'flex-end', alignItems: 'baseline', gap: 1 }}>
            <Typography variant="subtitle1" sx={{ fontWeight: 600 }}>
              {t("Total Order Cost:")}</Typography>
            <Typography variant="h5" sx={{ fontWeight: 800, color: '#0f172a' }}>
              {formatCurrency(calculateTotal())}
            </Typography>
          </Box>
        </DialogContent>
        <DialogActions sx={{ px: 3, py: 2 }}>
          <Button onClick={() => setCreateModalOpen(false)} disabled={submitting}>
            {t("Cancel")}</Button>
          <Button
            variant="contained"
            onClick={handleCreatePurchase}
            disabled={submitting || suppliersLoading || productsLoading || suppliersError || productsError || suppliers.length === 0 || products.length === 0 || branches.length === 0}
            sx={{ bgcolor: '#0f172a', fontWeight: 600 }}
          >
            {submitting ? <CircularProgress size={20} color="inherit" /> : 'Create Purchase Order'}
          </Button>
        </DialogActions>
      </Dialog>

      {/* Receive Purchase Modal */}
      <Dialog open={receiveModalOpen} onClose={() => setReceiveModalOpen(false)} maxWidth="xs" fullWidth>
        <DialogTitle sx={{ fontWeight: 700 }}>
          {t("Confirm Goods Receipt:") + " "}{selectedPurchase?.purchase_number}
        </DialogTitle>
        <DialogContent dividers>
          <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
            {t("Receiving this order will automatically increment inventory stock movements and recalculate weighted average costs.")}</Typography>

          <TextField
            fullWidth
            size="small"
            type="number"
            label={t("Upfront Cash/Payment Paid to Supplier (MMK)")}
            value={receivePaidAmount}
            onChange={(e) => setReceivePaidAmount(Number(e.target.value))}
            inputProps={{ min: 0, max: Math.max(0, Number(selectedPurchase?.total_amount || 0) - Number(selectedPurchase?.paid_amount || 0)), step: 0.01 }}
            sx={{ mb: 2 }}
          />

          <TextField
            fullWidth
            size="small"
            select
            label={t("Payment Method")}
            value={receivePaymentMethod}
            onChange={(e) => setReceivePaymentMethod(e.target.value)}
          >
            <MenuItem value="cash">{t("Cash on Delivery")}</MenuItem>
            <MenuItem value="bank_transfer">{t("Bank Transfer (KBZ / CB / AYA)")}</MenuItem>
            <MenuItem value="kbz_pay">KBZPay</MenuItem>
            <MenuItem value="wave_pay">WavePay</MenuItem>
          </TextField>
        </DialogContent>
        <DialogActions sx={{ px: 3, py: 2 }}>
          <Button onClick={() => setReceiveModalOpen(false)} disabled={receiving}>
            {t("Cancel")}</Button>
          <Button
            variant="contained"
            color="success"
            onClick={handleConfirmReceive}
            disabled={receiving}
            sx={{ fontWeight: 600 }}
          >
            {receiving ? <CircularProgress size={20} color="inherit" /> : 'Confirm & Post to Ledger'}
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
};
