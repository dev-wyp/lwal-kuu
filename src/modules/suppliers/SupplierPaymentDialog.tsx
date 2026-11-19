import React, { useMemo, useRef, useState } from 'react';
import {
  Alert,
  Button,
  Dialog,
  DialogActions,
  DialogContent,
  DialogTitle,
  MenuItem,
  Stack,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableRow,
  TextField,
  Typography,
} from '@mui/material';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/lib/supabase';
import { useOrg } from '@/context/OrgContext';
import { useNotification } from '@/context/NotificationContext';
import { useI18n } from '@/i18n/I18nContext';

interface SupplierPaymentDialogProps {
  supplierId: string;
  supplierName: string;
  onClose: () => void;
}

interface PayablePurchase {
  id: string;
  purchase_number: string;
  purchase_date: string;
  total_amount: number;
  paid_amount: number;
}

export const SupplierPaymentDialog: React.FC<SupplierPaymentDialogProps> = ({ supplierId, supplierName, onClose }) => {
  const { t } = useI18n();
  const { currentOrg, formatCurrency } = useOrg();
  const { showError, showSuccess } = useNotification();
  const queryClient = useQueryClient();
  const orgId = currentOrg?.id;
  const [amount, setAmount] = useState(0);
  const [method, setMethod] = useState('cash');
  const [reference, setReference] = useState('');
  const [notes, setNotes] = useState('');
  const [allocations, setAllocations] = useState<Record<string, number>>({});
  const [saving, setSaving] = useState(false);
  const pendingRequest = useRef<{ fingerprint: string; key: string } | null>(null);

  const { data: purchases = [], isLoading } = useQuery({
    queryKey: ['supplier_unpaid_purchases', orgId, supplierId],
    enabled: Boolean(orgId && supplierId),
    queryFn: async () => {
      const { data, error } = await supabase.from('purchases')
        .select('id,purchase_number,purchase_date,total_amount,paid_amount')
        .eq('organization_id', orgId!)
        .eq('supplier_id', supplierId)
        .eq('status', 'received')
        .order('purchase_date', { ascending: true });
      if (error) throw error;
      return (data ?? []).filter((purchase) => Number(purchase.total_amount) > Number(purchase.paid_amount)) as PayablePurchase[];
    },
  });

  const allocated = useMemo(() => Object.values(allocations).reduce((sum, value) => sum + (Number(value) || 0), 0), [allocations]);
  const unallocated = Math.max(0, amount - allocated);

  const allocateFifo = () => {
    let remaining = amount;
    const next: Record<string, number> = {};
    for (const purchase of purchases) {
      if (remaining <= 0) break;
      const due = Math.max(0, Number(purchase.total_amount) - Number(purchase.paid_amount));
      const assign = Math.min(remaining, due);
      if (assign > 0) next[purchase.id] = assign;
      remaining -= assign;
    }
    setAllocations(next);
  };

  const handleClose = () => {
    if (pendingRequest.current) {
      showError(t('The last request may still have completed. Retry it with the same details before closing this payment.'));
      return;
    }
    onClose();
  };

  const recordPayment = async () => {
    if (!orgId || amount <= 0) {
      showError(t('Enter a payment amount greater than zero.'));
      return;
    }
    if (allocated > amount) {
      showError(t('Invoice allocations cannot exceed the payment amount.'));
      return;
    }
    const allocationRows = Object.entries(allocations)
      .filter(([, value]) => Number(value) > 0)
      .map(([purchaseId, value]) => ({ purchase_id: purchaseId, amount: Number(value) }))
      .sort((left, right) => left.purchase_id.localeCompare(right.purchase_id));
    const fingerprint = JSON.stringify({ orgId, supplierId, amount, method, reference, notes, allocationRows });
    if (pendingRequest.current && pendingRequest.current.fingerprint !== fingerprint) {
      showError(t('A previous payment result is pending. Retry the same details or check the supplier statement first.'));
      return;
    }

    setSaving(true);
    try {
      const key = pendingRequest.current?.key ?? crypto.randomUUID();
      pendingRequest.current = { fingerprint, key };
      const { data, error } = await supabase.rpc('record_supplier_payment_and_allocate' as any, {
        p_org_id: orgId,
        p_supplier_id: supplierId,
        p_amount: amount,
        p_payment_method: method,
        p_allocations: allocationRows,
        p_reference_number: reference || null,
        p_notes: notes || null,
        p_idempotency_key: key,
      });
      if (error) {
        if ('code' in error && error.code) pendingRequest.current = null;
        throw error;
      }
      pendingRequest.current = null;
      showSuccess(unallocated > 0
        ? t('Supplier payment recorded. {{amount}} remains as an advance.', { amount: formatCurrency(unallocated) })
        : t('Supplier payment {{number}} recorded.', { number: data.payment_number }));
      await Promise.all([
        queryClient.invalidateQueries({ queryKey: ['suppliers'] }),
        queryClient.invalidateQueries({ queryKey: ['supplier_statement'] }),
        queryClient.invalidateQueries({ queryKey: ['supplier_unpaid_purchases'] }),
        queryClient.invalidateQueries({ queryKey: ['purchases'] }),
      ]);
      onClose();
    } catch (error) {
      showError(error instanceof Error ? error.message : t('Could not record supplier payment.'));
    } finally {
      setSaving(false);
    }
  };

  return <Dialog open onClose={saving ? undefined : handleClose} maxWidth="md" fullWidth>
    <DialogTitle>{t('Record payment to {{supplier}}', { supplier: supplierName })}</DialogTitle>
    <DialogContent dividers>
      <Stack spacing={2}>
        <Alert severity="info">{t('You can pay received invoices or leave an unallocated amount as a supplier advance.')}</Alert>
        <Stack direction={{ xs: 'column', sm: 'row' }} spacing={2}>
          <TextField fullWidth type="number" label={t('Payment amount')} value={amount || ''}
            inputProps={{ min: 0, step: 1 }} onChange={(event) => setAmount(Math.max(0, Number(event.target.value) || 0))} />
          <TextField fullWidth select label={t('Payment method')} value={method} onChange={(event) => setMethod(event.target.value)}>
            <MenuItem value="cash">{t('Cash')}</MenuItem>
            <MenuItem value="bank_transfer">{t('Bank transfer')}</MenuItem>
            <MenuItem value="mobile_money">{t('Mobile money')}</MenuItem>
            <MenuItem value="kbz_pay">KBZPay</MenuItem>
            <MenuItem value="wave_pay">WavePay</MenuItem>
            <MenuItem value="other">{t('Other')}</MenuItem>
          </TextField>
        </Stack>
        <Stack direction={{ xs: 'column', sm: 'row' }} spacing={2}>
          <TextField fullWidth label={t('Reference number (optional)')} value={reference} onChange={(event) => setReference(event.target.value)} />
          <TextField fullWidth label={t('Notes (optional)')} value={notes} onChange={(event) => setNotes(event.target.value)} />
        </Stack>
        <Stack direction="row" alignItems="center" justifyContent="space-between" spacing={2}>
          <Typography variant="subtitle1" fontWeight={700}>{t('Received invoices')}</Typography>
          <Button size="small" onClick={allocateFifo} disabled={amount <= 0 || purchases.length === 0}>{t('Allocate oldest first')}</Button>
        </Stack>
        {isLoading ? <Typography color="text.secondary">{t('Loading invoices…')}</Typography> : purchases.length === 0
          ? <Typography color="text.secondary">{t('No received invoices are currently outstanding. You can record this as an advance.')}</Typography>
          : <Table size="small"><TableHead><TableRow>
            <TableCell>{t('Purchase')}</TableCell><TableCell>{t('Date')}</TableCell>
            <TableCell align="right">{t('Outstanding')}</TableCell><TableCell align="right">{t('Allocate')}</TableCell>
          </TableRow></TableHead><TableBody>{purchases.map((purchase) => {
            const due = Math.max(0, Number(purchase.total_amount) - Number(purchase.paid_amount));
            return <TableRow key={purchase.id}>
              <TableCell>{purchase.purchase_number}</TableCell><TableCell>{purchase.purchase_date}</TableCell>
              <TableCell align="right">{formatCurrency(due)}</TableCell>
              <TableCell align="right"><TextField size="small" type="number" value={allocations[purchase.id] ?? ''}
                inputProps={{ min: 0, max: due, step: 1 }} sx={{ maxWidth: 150 }}
                onChange={(event) => setAllocations((current) => ({ ...current, [purchase.id]: Math.max(0, Number(event.target.value) || 0) }))} /></TableCell>
            </TableRow>;
          })}</TableBody></Table>}
        <Alert severity={allocated > amount ? 'error' : 'success'}>
          {t('Allocated: {{allocated}} · Unallocated advance: {{advance}}', {
            allocated: formatCurrency(allocated),
            advance: formatCurrency(unallocated),
          })}
        </Alert>
      </Stack>
    </DialogContent>
    <DialogActions>
      <Button onClick={handleClose} disabled={saving || Boolean(pendingRequest.current)}>{t('Cancel')}</Button>
      <Button variant="contained" onClick={recordPayment} disabled={saving || isLoading || amount <= 0 || allocated > amount}>
        {saving ? t('Recording…') : t('Record payment')}
      </Button>
    </DialogActions>
  </Dialog>;
};
