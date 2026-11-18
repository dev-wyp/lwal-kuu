import React, { useState } from 'react';
import {
  Dialog,
  DialogTitle,
  DialogContent,
  DialogActions,
  Button,
  Box,
  Typography,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
  Paper,
  CircularProgress,
  TextField,
  Chip,
} from '@mui/material';
import PrintIcon from '@mui/icons-material/Print';
import { useQuery } from '@tanstack/react-query';
import { supabase } from '@/lib/supabase';
import { useOrg } from '@/context/OrgContext';
import { useI18n } from '@/i18n/I18nContext';
import { useEntitlements } from '@/modules/subscription/useEntitlements';

interface CustomerLedgerModalProps {
  open: boolean;
  onClose: () => void;
  customer: any;
}

export const CustomerLedgerModal: React.FC<CustomerLedgerModalProps> = ({
  open,
  onClose,
  customer,
}) => {
  const { t } = useI18n();
  const { currentOrg, formatCurrency } = useOrg();
  const { data: entitlements = [] } = useEntitlements();
  const canPrintStatement = entitlements.some((item) => item.feature_key === 'customer_statement_pdf' && item.is_allowed);
  const orgId = currentOrg?.id;

  const [startDate, setStartDate] = useState('');
  const [endDate, setEndDate] = useState('');

  const { data: statementEntries = [], isLoading } = useQuery({
    queryKey: ['customer_statement', orgId, customer?.id, startDate, endDate],
    queryFn: async () => {
      if (!orgId || !customer?.id) return [];

      const { data, error } = await supabase.rpc('get_customer_statement', {
        p_org_id: orgId,
        p_customer_id: customer.id,
        p_start_date: startDate || null,
        p_end_date: endDate || null,
      });

      if (error) throw error;
      return data || [];
    },
    enabled: Boolean(open && orgId && customer?.id),
  });

  const handlePrint = () => {
    window.print();
  };

  // Compute running balance
  let runningBalance = Number(customer?.opening_balance || 0);

  return (
    <Dialog open={open} onClose={onClose} maxWidth="md" fullWidth>
      <DialogTitle sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
        <div>
          <Typography variant="h6" sx={{ fontWeight: 800 }}>
            {t("Customer Statement:")}{customer?.name}
          </Typography>
          <Typography variant="caption" color="text.secondary">
            Phone: {customer?.phone || 'N/A'} &bull; Credit Limit: {formatCurrency(customer?.credit_limit || 0)}
          </Typography>
        </div>
        {canPrintStatement && <Button startIcon={<PrintIcon />} variant="outlined" size="small" onClick={handlePrint}>
          {t("Print Statement")}</Button>}
      </DialogTitle>

      <DialogContent dividers>
        {/* Date Filter & Current Balance summary */}
        <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', mb: 3, flexWrap: 'wrap', gap: 2 }}>
          <Box sx={{ display: 'flex', gap: 1.5 }}>
            <TextField
              size="small"
              type="date"
              label="From Date"
              value={startDate}
              onChange={(e) => setStartDate(e.target.value)}
              InputLabelProps={{ shrink: true }}
            />
            <TextField
              size="small"
              type="date"
              label="To Date"
              value={endDate}
              onChange={(e) => setEndDate(e.target.value)}
              InputLabelProps={{ shrink: true }}
            />
          </Box>

          <Box sx={{ textAlign: 'right' }}>
            <Typography variant="caption" color="text.secondary" sx={{ display: 'block' }}>
              {t("Current Outstanding Balance")}</Typography>
            <Typography variant="h6" sx={{ fontWeight: 800, color: '#d97706' }}>
              {formatCurrency(customer?.current_balance || 0)}
            </Typography>
          </Box>
        </Box>

        <TableContainer component={Paper} elevation={0} sx={{ border: '1px solid #e2e8f0' }}>
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>{t("Date")}</TableCell>
                <TableCell>{t("Type")}</TableCell>
                <TableCell>{t("Ref #")}</TableCell>
                <TableCell align="right">{t("Debit (+Sale)")}</TableCell>
                <TableCell align="right">{t("Credit (-Paid)")}</TableCell>
                <TableCell align="right">{t("Running Balance")}</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {/* Opening Balance Row */}
              <TableRow sx={{ bgcolor: '#f8fafc' }}>
                <TableCell colSpan={3} sx={{ fontWeight: 600 }}>
                  {t("Opening Balance")}</TableCell>
                <TableCell align="right">-</TableCell>
                <TableCell align="right">-</TableCell>
                <TableCell align="right" sx={{ fontWeight: 700 }}>
                  {formatCurrency(customer?.opening_balance || 0)}
                </TableCell>
              </TableRow>

              {isLoading ? (
                <TableRow>
                  <TableCell colSpan={6} align="center" sx={{ py: 4 }}>
                    <CircularProgress size={24} />
                  </TableCell>
                </TableRow>
              ) : statementEntries.length > 0 ? (
                statementEntries.map((row: any, idx: number) => {
                  const debit = Number(row.debit || 0);
                  const credit = Number(row.credit || 0);
                  runningBalance = runningBalance + debit - credit;

                  return (
                    <TableRow key={idx} hover>
                      <TableCell>{row.transaction_date}</TableCell>
                      <TableCell>
                        <Chip
                          label={row.transaction_type}
                          size="small"
                          color={debit > 0 ? 'default' : 'success'}
                          sx={{ height: 20, fontSize: 10, fontWeight: 600 }}
                        />
                      </TableCell>
                      <TableCell sx={{ fontWeight: 600 }}>{row.reference_number}</TableCell>
                      <TableCell align="right" sx={{ color: debit > 0 ? '#d97706' : 'inherit' }}>
                        {debit > 0 ? formatCurrency(debit) : '-'}
                      </TableCell>
                      <TableCell align="right" sx={{ color: credit > 0 ? '#10b981' : 'inherit' }}>
                        {credit > 0 ? formatCurrency(credit) : '-'}
                      </TableCell>
                      <TableCell align="right" sx={{ fontWeight: 700 }}>
                        {formatCurrency(runningBalance)}
                      </TableCell>
                    </TableRow>
                  );
                })
              ) : (
                <TableRow>
                  <TableCell colSpan={6} align="center" sx={{ py: 3, color: 'text.secondary' }}>
                    {t("No transactions found for this customer.")}</TableCell>
                </TableRow>
              )}
            </TableBody>
          </Table>
        </TableContainer>
      </DialogContent>

      <DialogActions sx={{ px: 3, py: 2 }}>
        <Button onClick={onClose} variant="contained" sx={{ bgcolor: '#0f172a' }}>
          {t("Close")}</Button>
      </DialogActions>
    </Dialog>
  );
};

