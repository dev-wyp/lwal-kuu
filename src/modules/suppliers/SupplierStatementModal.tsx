import React, { useRef, useState } from 'react';
import {
  Alert,
  Button,
  Dialog,
  DialogActions,
  DialogContent,
  DialogTitle,
  Stack,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
  TextField,
  Typography,
} from '@mui/material';
import PrintIcon from '@mui/icons-material/Print';
import UndoIcon from '@mui/icons-material/Undo';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/lib/supabase';
import { useOrg } from '@/context/OrgContext';
import { useNotification } from '@/context/NotificationContext';
import { useI18n } from '@/i18n/I18nContext';

interface SupplierStatementModalProps {
  supplier: any;
  onClose: () => void;
}

interface StatementEntry {
  date: string;
  reference: string;
  type: string;
  debit: number;
  credit: number;
  id: string;
  paymentId?: string;
  reversed?: boolean;
}

export const SupplierStatementModal: React.FC<SupplierStatementModalProps> = ({ supplier, onClose }) => {
  const { t } = useI18n();
  const { currentOrg, formatCurrency } = useOrg();
  const { showError, showSuccess } = useNotification();
  const queryClient = useQueryClient();
  const orgId = currentOrg?.id;
  const [paymentToReverse, setPaymentToReverse] = useState<{ id: string; reference: string; amount: number } | null>(null);
  const [reversalReason, setReversalReason] = useState('');
  const [reversing, setReversing] = useState(false);
  const pendingReversal = useRef<{ fingerprint: string; key: string } | null>(null);

  const { data: entries = [], isLoading } = useQuery<StatementEntry[]>({
    queryKey: ['supplier_statement', orgId, supplier?.supplier_id],
    enabled: Boolean(orgId && supplier?.supplier_id),
    queryFn: async () => {
      const [purchaseResult, paymentResult, reversalResult] = await Promise.all([
        supabase.from('purchases').select('id,purchase_number,purchase_date,total_amount,status')
          .eq('organization_id', orgId!).eq('supplier_id', supplier.supplier_id).eq('status', 'received'),
        supabase.from('supplier_payments').select('id,payment_number,payment_date,amount,payment_method')
          .eq('organization_id', orgId!).eq('supplier_id', supplier.supplier_id),
        (supabase as any).from('supplier_payment_reversals')
          .select('id,supplier_payment_id,amount,created_at')
          .eq('organization_id', orgId!),
      ]);
      if (purchaseResult.error) throw purchaseResult.error;
      if (paymentResult.error) throw paymentResult.error;
      if (reversalResult.error) throw reversalResult.error;

      const paymentById = new Map((paymentResult.data ?? []).map((payment) => [payment.id, payment]));
      const reversedPaymentIds = new Set((reversalResult.data ?? []).map((reversal: { supplier_payment_id: string }) => reversal.supplier_payment_id));
      const result: StatementEntry[] = [
        ...(purchaseResult.data ?? []).map((row) => ({
          date: row.purchase_date,
          reference: row.purchase_number,
          type: t('Purchase'),
          debit: 0,
          credit: Number(row.total_amount),
          id: `purchase-${row.id}`,
        })),
        ...(paymentResult.data ?? []).map((row) => ({
          date: row.payment_date,
          reference: row.payment_number,
          type: t('Supplier Payment'),
          debit: Number(row.amount),
          credit: 0,
          id: `payment-${row.id}`,
          paymentId: row.id,
          reversed: reversedPaymentIds.has(row.id),
        })),
        ...(reversalResult.data ?? []).map((row: { id: string; supplier_payment_id: string; amount: number; created_at: string }) => ({
          date: row.created_at.slice(0, 10),
          reference: paymentById.get(row.supplier_payment_id)?.payment_number ?? row.supplier_payment_id,
          type: t('Supplier Payment Reversal'),
          debit: 0,
          credit: Number(row.amount),
          id: `reversal-${row.id}`,
        })),
      ];
      return result.sort((a, b) => a.date.localeCompare(b.date) || a.id.localeCompare(b.id));
    },
  });

  let balance = Number(supplier?.opening_balance ?? 0);

  const reversePayment = async () => {
    if (!orgId || !paymentToReverse) return;
    const reason = reversalReason.trim();
    if (reason.length < 5 || reason.length > 1000) {
      showError(t('Enter a reversal reason between 5 and 1000 characters.'));
      return;
    }
    const fingerprint = JSON.stringify({ orgId, paymentId: paymentToReverse.id, reason });
    if (pendingReversal.current && pendingReversal.current.fingerprint !== fingerprint) {
      showError(t('A previous reversal result is pending. Retry the same details before changing the request.'));
      return;
    }

    setReversing(true);
    try {
      const key = pendingReversal.current?.key ?? crypto.randomUUID();
      pendingReversal.current = { fingerprint, key };
      const { error } = await (supabase as any).rpc('reverse_supplier_payment', {
        p_org_id: orgId,
        p_supplier_payment_id: paymentToReverse.id,
        p_reason: reason,
        p_idempotency_key: key,
      });
      if (error) {
        if (error.code) pendingReversal.current = null;
        throw error;
      }
      pendingReversal.current = null;
      showSuccess(t('Supplier payment {{number}} reversed.', { number: paymentToReverse.reference }));
      setPaymentToReverse(null);
      setReversalReason('');
      void Promise.all([
        queryClient.invalidateQueries({ queryKey: ['supplier_statement'] }),
        queryClient.invalidateQueries({ queryKey: ['suppliers'] }),
        queryClient.invalidateQueries({ queryKey: ['purchases'] }),
        queryClient.invalidateQueries({ queryKey: ['cash_flow_performance'] }),
      ]).catch(() => undefined);
    } catch (error) {
      const message = error instanceof Error
        ? error.message
        : error && typeof error === 'object' && 'message' in error
          ? String(error.message)
          : t('Could not reverse the supplier payment.');
      showError(message);
    } finally {
      setReversing(false);
    }
  };

  return <>
    <Dialog open onClose={reversing || pendingReversal.current ? undefined : onClose} maxWidth="md" fullWidth>
      <DialogTitle>{t('Supplier Statement:')} {supplier?.supplier_name}</DialogTitle>
      <DialogContent dividers>
        <Typography sx={{ mb: 2 }}>{t('Current Payable')}: {formatCurrency(supplier?.current_payable ?? balance)}</Typography>
        <TableContainer>
          <Table size="small" sx={{ minWidth: 760 }}>
            <TableHead><TableRow>
              <TableCell>{t('Date')}</TableCell><TableCell>{t('Type')}</TableCell><TableCell>{t('Ref #')}</TableCell>
              <TableCell align="right">{t('Purchase')}</TableCell><TableCell align="right">{t('Payment')}</TableCell>
              <TableCell align="right">{t('Running Balance')}</TableCell><TableCell>{t('Action')}</TableCell>
            </TableRow></TableHead>
            <TableBody>
              <TableRow><TableCell colSpan={6}>{t('Opening Balance')}</TableCell><TableCell align="right">{formatCurrency(balance)}</TableCell></TableRow>
              {isLoading ? <TableRow><TableCell colSpan={7}>{t('Loading…')}</TableCell></TableRow> : entries.map((entry) => {
                balance += entry.credit - entry.debit;
                return <TableRow key={entry.id}>
                  <TableCell>{entry.date}</TableCell><TableCell>{entry.type}{entry.reversed ? ` (${t('Reversed')})` : ''}</TableCell>
                  <TableCell>{entry.reference}</TableCell>
                  <TableCell align="right">{entry.credit ? formatCurrency(entry.credit) : '—'}</TableCell>
                  <TableCell align="right">{entry.debit ? formatCurrency(entry.debit) : '—'}</TableCell>
                  <TableCell align="right">{formatCurrency(balance)}</TableCell>
                  <TableCell>
                    {entry.paymentId && !entry.reversed && <Button size="small" color="warning" startIcon={<UndoIcon />}
                      onClick={() => { setReversalReason(''); setPaymentToReverse({ id: entry.paymentId!, reference: entry.reference, amount: entry.debit }); }}>
                      {t('Reverse')}
                    </Button>}
                  </TableCell>
                </TableRow>;
              })}
            </TableBody>
          </Table>
        </TableContainer>
      </DialogContent>
      <DialogActions sx={{ flexWrap: 'wrap', justifyContent: { xs: 'center', sm: 'flex-end' }, px: { xs: 1.5, sm: 3 }, pb: 2 }}>
        <Button onClick={onClose} disabled={reversing || Boolean(pendingReversal.current)}>{t('Close')}</Button>
        <Button startIcon={<PrintIcon />} onClick={() => window.print()}>{t('Print Statement')}</Button>
      </DialogActions>
    </Dialog>

    <Dialog open={Boolean(paymentToReverse)} onClose={reversing || pendingReversal.current ? undefined : () => setPaymentToReverse(null)} maxWidth="sm" fullWidth>
      <DialogTitle>{t('Reverse supplier payment')}</DialogTitle>
      <DialogContent>
        <Stack spacing={2} sx={{ pt: 1 }}>
          <Alert severity="warning">{t('This records a full reversal, restores allocated purchase balances, and keeps the original payment and audit history. This action cannot be undone.')}</Alert>
          <Typography>{paymentToReverse?.reference}: {formatCurrency(paymentToReverse?.amount ?? 0)}</Typography>
          <TextField autoFocus required multiline minRows={3} label={t('Reason for reversal')} value={reversalReason}
            onChange={(event) => setReversalReason(event.target.value)} disabled={Boolean(pendingReversal.current)} inputProps={{ maxLength: 1000 }} />
        </Stack>
      </DialogContent>
      <DialogActions>
        <Button onClick={() => setPaymentToReverse(null)} disabled={reversing || Boolean(pendingReversal.current)}>{t('Cancel')}</Button>
        <Button color="warning" variant="contained" onClick={reversePayment} disabled={reversing || reversalReason.trim().length < 5}>
          {reversing ? t('Reversing…') : t('Confirm reversal')}
        </Button>
      </DialogActions>
    </Dialog>
  </>;
};
