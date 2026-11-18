import React from 'react';
import { Button, Dialog, DialogActions, DialogContent, DialogTitle, Table, TableBody, TableCell, TableContainer, TableHead, TableRow, Typography } from '@mui/material';
import PrintIcon from '@mui/icons-material/Print';
import { useQuery } from '@tanstack/react-query';
import { supabase } from '@/lib/supabase';
import { useOrg } from '@/context/OrgContext';
import { useI18n } from '@/i18n/I18nContext';

interface SupplierStatementModalProps {
  supplier: any;
  onClose: () => void;
}

export const SupplierStatementModal: React.FC<SupplierStatementModalProps> = ({ supplier, onClose }) => {
  const { t } = useI18n();
  const { currentOrg, formatCurrency } = useOrg();
  const orgId = currentOrg?.id;
  const { data: entries = [], isLoading } = useQuery({
    queryKey: ['supplier_statement', orgId, supplier?.supplier_id],
    enabled: Boolean(orgId && supplier?.supplier_id),
    queryFn: async () => {
      const [purchaseResult, paymentResult] = await Promise.all([
        supabase.from('purchases').select('id,purchase_number,purchase_date,total_amount,status').eq('organization_id', orgId!).eq('supplier_id', supplier.supplier_id).eq('status', 'received'),
        supabase.from('supplier_payments').select('id,payment_number,payment_date,amount,payment_method').eq('organization_id', orgId!).eq('supplier_id', supplier.supplier_id),
      ]);
      if (purchaseResult.error) throw purchaseResult.error;
      if (paymentResult.error) throw paymentResult.error;
      return [
        ...(purchaseResult.data ?? []).map((row) => ({ date: row.purchase_date, reference: row.purchase_number, type: t('Purchase'), debit: 0, credit: Number(row.total_amount), id: `purchase-${row.id}` })),
        ...(paymentResult.data ?? []).map((row) => ({ date: row.payment_date, reference: row.payment_number, type: t('Supplier Payment'), debit: Number(row.amount), credit: 0, id: `payment-${row.id}` })),
      ].sort((a, b) => a.date.localeCompare(b.date) || a.id.localeCompare(b.id));
    },
  });
  let balance = Number(supplier?.opening_balance ?? 0);

  return <Dialog open onClose={onClose} maxWidth="md" fullWidth>
    <DialogTitle>{t('Supplier Statement:')} {supplier?.supplier_name}</DialogTitle>
    <DialogContent dividers>
      <Typography sx={{ mb: 2 }}>{t('Current Payable')}: {formatCurrency(supplier?.current_payable ?? balance)}</Typography>
      <TableContainer>
        <Table size="small" sx={{ minWidth: 700 }}>
          <TableHead><TableRow>
            <TableCell>{t('Date')}</TableCell><TableCell>{t('Type')}</TableCell><TableCell>{t('Ref #')}</TableCell>
            <TableCell align="right">{t('Purchase')}</TableCell><TableCell align="right">{t('Payment')}</TableCell><TableCell align="right">{t('Running Balance')}</TableCell>
          </TableRow></TableHead>
          <TableBody>
            <TableRow><TableCell colSpan={5}>{t('Opening Balance')}</TableCell><TableCell align="right">{formatCurrency(balance)}</TableCell></TableRow>
            {isLoading ? <TableRow><TableCell colSpan={6}>{t('Loading…')}</TableCell></TableRow> : entries.map((entry) => {
              balance += entry.credit - entry.debit;
              return <TableRow key={entry.id}>
                <TableCell>{entry.date}</TableCell><TableCell>{entry.type}</TableCell><TableCell>{entry.reference}</TableCell>
                <TableCell align="right">{entry.credit ? formatCurrency(entry.credit) : '—'}</TableCell>
                <TableCell align="right">{entry.debit ? formatCurrency(entry.debit) : '—'}</TableCell>
                <TableCell align="right">{formatCurrency(balance)}</TableCell>
              </TableRow>;
            })}
          </TableBody>
        </Table>
      </TableContainer>
    </DialogContent>
    <DialogActions sx={{ flexWrap: 'wrap', justifyContent: { xs: 'center', sm: 'flex-end' }, px: { xs: 1.5, sm: 3 }, pb: 2 }}>
      <Button onClick={onClose}>{t('Close')}</Button>
      <Button startIcon={<PrintIcon />} onClick={() => window.print()}>{t('Print Statement')}</Button>
    </DialogActions>
  </Dialog>;
};
