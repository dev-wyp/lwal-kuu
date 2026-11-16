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
  TextField,
  InputAdornment,
  CircularProgress,
  Dialog,
  DialogTitle,
  DialogContent,
  DialogActions,
  Grid,
} from '@mui/material';
import AddIcon from '@mui/icons-material/Add';
import SearchIcon from '@mui/icons-material/Search';
import ReceiptLongIcon from '@mui/icons-material/ReceiptLong';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/lib/supabase';
import { useOrg } from '@/context/OrgContext';
import { useNotification } from '@/context/NotificationContext';
import { CustomerLedgerModal } from './CustomerLedgerModal';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import * as z from 'zod';
import { useI18n } from '@/i18n/I18nContext';

const customerSchema = z.object({
  name: z.string().min(1, 'Name is required'),
  phone: z.string().optional(),
  email: z.string().optional(),
  address: z.string().optional(),
  creditLimit: z.coerce.number().min(0, 'Credit limit must be positive'),
  openingBalance: z.coerce.number().default(0),
});

type CustomerFormData = z.infer<typeof customerSchema>;

export const CustomersPage: React.FC = () => {
  const { t } = useI18n();
  const { currentOrg, formatCurrency } = useOrg();
  const { showSuccess, showError } = useNotification();
  const queryClient = useQueryClient();
  const orgId = currentOrg?.id;

  const [search, setSearch] = useState('');
  const [modalOpen, setModalOpen] = useState(false);
  const [statementCustomer, setStatementCustomer] = useState<any>(null);

  const { data: customers = [], isLoading } = useQuery({
    queryKey: ['customers', orgId, search],
    queryFn: async () => {
      if (!orgId) return [];

      const { data, error } = await supabase
        .from('customer_balances_summary')
        .select('*')
        .eq('organization_id', orgId)
        .ilike('customer_name', `%${search}%`)
        .order('customer_name');

      if (error) throw error;
      return data || [];
    },
    enabled: Boolean(orgId),
  });

  const {
    register,
    handleSubmit,
    reset,
    formState: { errors, isSubmitting },
  } = useForm<CustomerFormData>({
    resolver: zodResolver(customerSchema),
    defaultValues: {
      name: '',
      phone: '',
      email: '',
      address: '',
      creditLimit: 0,
      openingBalance: 0,
    },
  });

  const handleOpenAdd = () => {
    reset({
      name: '',
      phone: '',
      email: '',
      address: '',
      creditLimit: 0,
      openingBalance: 0,
    });
    setModalOpen(true);
  };

  const onSubmit = async (data: CustomerFormData) => {
    if (!currentOrg) return;

    try {
      const { error } = await supabase.from('customers').insert({
        organization_id: currentOrg.id,
        name: data.name,
        phone: data.phone || null,
        email: data.email || null,
        address: data.address || null,
        credit_limit: data.creditLimit,
        opening_balance: data.openingBalance,
      } as any);

      if (error) throw error;

      showSuccess('Customer created successfully');
      queryClient.invalidateQueries({ queryKey: ['customers'] });
      setModalOpen(false);
    } catch (err: any) {
      showError(err.message || 'Failed to create customer');
    }
  };

  return (
    <Box>
      <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', mb: 3 }}>
        <div>
          <Typography variant="h4" sx={{ fontWeight: 800 }}>
            {t("Customer Directory & Credit Ledgers")}</Typography>
          <Typography variant="body2" color="text.secondary">
            {t("Manage wholesale customers, credit limits, and real-time outstanding balances.")}</Typography>
        </div>
        <Button
          variant="contained"
          startIcon={<AddIcon />}
          onClick={handleOpenAdd}
          sx={{ borderRadius: 2, bgcolor: '#0f172a', fontWeight: 600 }}
        >
          {t("Add Customer")}</Button>
      </Box>

      {/* Search */}
      <Paper elevation={0} sx={{ p: 2, mb: 3, borderRadius: 3, border: '1px solid #e2e8f0', bgcolor: '#ffffff' }}>
        <TextField
          size="small"
          placeholder={t("Search customers by name...")}
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          sx={{ minWidth: 280 }}
          InputProps={{
            startAdornment: (
              <InputAdornment position="start">
                <SearchIcon fontSize="small" sx={{ color: 'text.secondary' }} />
              </InputAdornment>
            ),
          }}
        />
      </Paper>

      {/* Table */}
      <Paper elevation={0} sx={{ borderRadius: 3, border: '1px solid #e2e8f0', bgcolor: '#ffffff' }}>
        <TableContainer>
          <Table>
            <TableHead>
              <TableRow>
                <TableCell>{t("Customer Name")}</TableCell>
                <TableCell>{t("Phone Number")}</TableCell>
                <TableCell align="right">{t("Credit Limit")}</TableCell>
                <TableCell align="right">{t("Opening Bal")}</TableCell>
                <TableCell align="right">{t("Confirmed Sales")}</TableCell>
                <TableCell align="right">{t("Payments")}</TableCell>
                <TableCell align="right">{t("Current Balance")}</TableCell>
                <TableCell align="center">{t("Ledger Statement")}</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {isLoading ? (
                <TableRow>
                  <TableCell colSpan={8} align="center" sx={{ py: 6 }}>
                    <CircularProgress size={32} />
                  </TableCell>
                </TableRow>
              ) : customers.length > 0 ? (
                customers.map((c: any) => (
                  <TableRow key={c.customer_id} hover>
                    <TableCell sx={{ fontWeight: 600 }}>{c.customer_name}</TableCell>
                    <TableCell>{c.phone || '-'}</TableCell>
                    <TableCell align="right">{formatCurrency(c.credit_limit)}</TableCell>
                    <TableCell align="right">{formatCurrency(c.opening_balance)}</TableCell>
                    <TableCell align="right">{formatCurrency(c.total_confirmed_sales)}</TableCell>
                    <TableCell align="right">{formatCurrency(c.total_payments_received)}</TableCell>
                    <TableCell align="right" sx={{ fontWeight: 700, color: c.current_balance > 0 ? '#d97706' : 'inherit' }}>
                      {formatCurrency(c.current_balance)}
                    </TableCell>
                    <TableCell align="center">
                      <Button
                        size="small"
                        variant="outlined"
                        startIcon={<ReceiptLongIcon fontSize="small" />}
                        onClick={() =>
                          setStatementCustomer({
                            id: c.customer_id,
                            name: c.customer_name,
                            phone: c.phone,
                            credit_limit: c.credit_limit,
                            opening_balance: c.opening_balance,
                            current_balance: c.current_balance,
                          })
                        }
                      >
                        {t("Statement")}</Button>
                    </TableCell>
                  </TableRow>
                ))
              ) : (
                <TableRow>
                  <TableCell colSpan={8} align="center" sx={{ py: 6, color: 'text.secondary' }}>
                    No customers found. Click &quot;Add Customer&quot; to add clients.
                  </TableCell>
                </TableRow>
              )}
            </TableBody>
          </Table>
        </TableContainer>
      </Paper>

      {/* Add Customer Modal */}
      <Dialog open={modalOpen} onClose={() => setModalOpen(false)} maxWidth="sm" fullWidth>
        <DialogTitle sx={{ fontWeight: 700 }}>{t("New Customer")}</DialogTitle>
        <form onSubmit={handleSubmit(onSubmit)}>
          <DialogContent dividers>
            <Grid container spacing={2}>
              <Grid item xs={12}>
                <TextField
                  fullWidth
                  size="small"
                  label={t("Customer / Shop Name")}
                  {...register('name')}
                  error={Boolean(errors.name)}
                  helperText={errors.name?.message}
                />
              </Grid>
              <Grid item xs={12} sm={6}>
                <TextField
                  fullWidth
                  size="small"
                  label={t("Phone Number")}
                  placeholder="09..."
                  {...register('phone')}
                />
              </Grid>
              <Grid item xs={12} sm={6}>
                <TextField
                  fullWidth
                  size="small"
                  label={t("Email (Optional)")}
                  {...register('email')}
                />
              </Grid>
              <Grid item xs={12} sm={6}>
                <TextField
                  fullWidth
                  size="small"
                  type="number"
                  label={t("Credit Limit (MMK)")}
                  {...register('creditLimit')}
                />
              </Grid>
              <Grid item xs={12} sm={6}>
                <TextField
                  fullWidth
                  size="small"
                  type="number"
                  label={t("Opening Receivable Balance (MMK)")}
                  {...register('openingBalance')}
                />
              </Grid>
              <Grid item xs={12}>
                <TextField
                  fullWidth
                  size="small"
                  label="Physical Address / Delivery Location"
                  multiline
                  rows={2}
                  {...register('address')}
                />
              </Grid>
            </Grid>
          </DialogContent>
          <DialogActions sx={{ px: 3, py: 2 }}>
            <Button onClick={() => setModalOpen(false)} disabled={isSubmitting}>
              {t("Cancel")}</Button>
            <Button
              type="submit"
              variant="contained"
              disabled={isSubmitting}
              sx={{ bgcolor: '#0f172a', fontWeight: 600 }}
            >
              {isSubmitting ? <CircularProgress size={20} color="inherit" /> : 'Save Customer'}
            </Button>
          </DialogActions>
        </form>
      </Dialog>

      {/* Customer Ledger Modal */}
      {statementCustomer && (
        <CustomerLedgerModal
          open={Boolean(statementCustomer)}
          onClose={() => setStatementCustomer(null)}
          customer={statementCustomer}
        />
      )}
    </Box>
  );
};

