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
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/lib/supabase';
import { useOrg } from '@/context/OrgContext';
import { useNotification } from '@/context/NotificationContext';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import * as z from 'zod';
import { useI18n } from '@/i18n/I18nContext';

const supplierSchema = z.object({
  name: z.string().min(1, 'Supplier name is required'),
  contactPerson: z.string().optional(),
  phone: z.string().optional(),
  email: z.string().optional(),
  address: z.string().optional(),
  openingBalance: z.coerce.number().default(0),
});

type SupplierFormData = z.infer<typeof supplierSchema>;

export const SuppliersPage: React.FC = () => {
  const { t } = useI18n();
  const { currentOrg, formatCurrency } = useOrg();
  const { showSuccess, showError } = useNotification();
  const queryClient = useQueryClient();
  const orgId = currentOrg?.id;

  const [search, setSearch] = useState('');
  const [modalOpen, setModalOpen] = useState(false);

  const { data: suppliers = [], isLoading } = useQuery({
    queryKey: ['suppliers', orgId, search],
    queryFn: async () => {
      if (!orgId) return [];

      const { data, error } = await supabase
        .from('supplier_balances_summary')
        .select('*')
        .eq('organization_id', orgId)
        .ilike('supplier_name', `%${search}%`)
        .order('supplier_name');

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
  } = useForm<SupplierFormData>({
    resolver: zodResolver(supplierSchema),
    defaultValues: {
      name: '',
      contactPerson: '',
      phone: '',
      email: '',
      address: '',
      openingBalance: 0,
    },
  });

  const handleOpenAdd = () => {
    reset({
      name: '',
      contactPerson: '',
      phone: '',
      email: '',
      address: '',
      openingBalance: 0,
    });
    setModalOpen(true);
  };

  const onSubmit = async (data: SupplierFormData) => {
    if (!currentOrg) return;

    try {
      const { error } = await supabase.from('suppliers').insert({
        organization_id: currentOrg.id,
        name: data.name,
        contact_person: data.contactPerson || null,
        phone: data.phone || null,
        email: data.email || null,
        address: data.address || null,
        opening_balance: data.openingBalance,
      } as any);

      if (error) throw error;

      showSuccess('Supplier created successfully');
      queryClient.invalidateQueries({ queryKey: ['suppliers'] });
      setModalOpen(false);
    } catch (err: any) {
      showError(err.message || 'Failed to create supplier');
    }
  };

  return (
    <Box>
      <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', mb: 3 }}>
        <div>
          <Typography variant="h4" sx={{ fontWeight: 800 }}>
            {t("Supplier Directory & Accounts Payable")}</Typography>
          <Typography variant="body2" color="text.secondary">
            {t("Manage product manufacturers, distributors, and outstanding payables.")}</Typography>
        </div>
        <Button
          variant="contained"
          startIcon={<AddIcon />}
          onClick={handleOpenAdd}
          sx={{ borderRadius: 2, bgcolor: '#0f172a', fontWeight: 600 }}
        >
          {t("Add Supplier")}</Button>
      </Box>

      {/* Search */}
      <Paper elevation={0} sx={{ p: 2, mb: 3, borderRadius: 3, border: '1px solid #e2e8f0', bgcolor: '#ffffff' }}>
        <TextField
          size="small"
          placeholder={t("Search suppliers by name...")}
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
                <TableCell>{t("Supplier Name")}</TableCell>
                <TableCell>{t("Phone")}</TableCell>
                <TableCell align="right">{t("Opening Bal")}</TableCell>
                <TableCell align="right">{t("Received Purchases")}</TableCell>
                <TableCell align="right">{t("Payments Made")}</TableCell>
                <TableCell align="right">{t("Current Payable")}</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {isLoading ? (
                <TableRow>
                  <TableCell colSpan={6} align="center" sx={{ py: 6 }}>
                    <CircularProgress size={32} />
                  </TableCell>
                </TableRow>
              ) : suppliers.length > 0 ? (
                suppliers.map((s: any) => (
                  <TableRow key={s.supplier_id} hover>
                    <TableCell sx={{ fontWeight: 600 }}>{s.supplier_name}</TableCell>
                    <TableCell>{s.phone || '-'}</TableCell>
                    <TableCell align="right">{formatCurrency(s.opening_balance)}</TableCell>
                    <TableCell align="right">{formatCurrency(s.total_received_purchases)}</TableCell>
                    <TableCell align="right">{formatCurrency(s.total_payments_made)}</TableCell>
                    <TableCell align="right" sx={{ fontWeight: 700, color: s.current_payable > 0 ? '#ef4444' : 'inherit' }}>
                      {formatCurrency(s.current_payable)}
                    </TableCell>
                  </TableRow>
                ))
              ) : (
                <TableRow>
                  <TableCell colSpan={6} align="center" sx={{ py: 6, color: 'text.secondary' }}>
                    No suppliers found. Click &quot;Add Supplier&quot; to register vendors.
                  </TableCell>
                </TableRow>
              )}
            </TableBody>
          </Table>
        </TableContainer>
      </Paper>

      {/* Add Supplier Modal */}
      <Dialog open={modalOpen} onClose={() => setModalOpen(false)} maxWidth="sm" fullWidth>
        <DialogTitle sx={{ fontWeight: 700 }}>{t("New Supplier")}</DialogTitle>
        <form onSubmit={handleSubmit(onSubmit)}>
          <DialogContent dividers>
            <Grid container spacing={2}>
              <Grid item xs={12}>
                <TextField
                  fullWidth
                  size="small"
                  label={t("Supplier / Company Name")}
                  {...register('name')}
                  error={Boolean(errors.name)}
                  helperText={errors.name?.message}
                />
              </Grid>
              <Grid item xs={12} sm={6}>
                <TextField
                  fullWidth
                  size="small"
                  label={t("Contact Person")}
                  {...register('contactPerson')}
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
                  label={t("Opening Payable Balance (MMK)")}
                  {...register('openingBalance')}
                />
              </Grid>
              <Grid item xs={12}>
                <TextField
                  fullWidth
                  size="small"
                  label={t("Office / Warehouse Address")}
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
              {isSubmitting ? <CircularProgress size={20} color="inherit" /> : 'Save Supplier'}
            </Button>
          </DialogActions>
        </form>
      </Dialog>
    </Box>
  );
};

