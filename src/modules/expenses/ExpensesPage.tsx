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
} from '@mui/material';
import AddIcon from '@mui/icons-material/Add';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/lib/supabase';
import { useOrg } from '@/context/OrgContext';
import { useNotification } from '@/context/NotificationContext';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import * as z from 'zod';

const expenseSchema = z.object({
  title: z.string().min(1, 'Title is required'),
  categoryId: z.string().min(1, 'Category is required'),
  amount: z.coerce.number().min(1, 'Amount must be greater than zero'),
  expenseDate: z.string().min(1, 'Date is required'),
  paymentMethod: z.string().min(1, 'Payment method is required'),
  notes: z.string().optional(),
});

type ExpenseFormData = z.infer<typeof expenseSchema>;

export const ExpensesPage: React.FC = () => {
  const { currentOrg, formatCurrency } = useOrg();
  const { showSuccess, showError } = useNotification();
  const queryClient = useQueryClient();
  const orgId = currentOrg?.id;

  const [modalOpen, setModalOpen] = useState(false);

  // 1. Fetch Categories
  const { data: categories = [] } = useQuery({
    queryKey: ['expense_categories', orgId],
    queryFn: async () => {
      if (!orgId) return [];
      const { data } = await supabase
        .from('expense_categories')
        .select('*')
        .eq('organization_id', orgId)
        .order('name');
      return data || [];
    },
    enabled: Boolean(orgId),
  });

  // 2. Fetch Expenses
  const { data: expenses = [], isLoading } = useQuery({
    queryKey: ['expenses_list', orgId],
    queryFn: async () => {
      if (!orgId) return [];
      const { data, error } = await supabase
        .from('expenses')
        .select(`
          *,
          expense_categories(name)
        `)
        .eq('organization_id', orgId)
        .order('expense_date', { ascending: false });

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
  } = useForm<ExpenseFormData>({
    resolver: zodResolver(expenseSchema),
    defaultValues: {
      title: '',
      categoryId: '',
      amount: 0,
      expenseDate: new Date().toISOString().split('T')[0],
      paymentMethod: 'cash',
      notes: '',
    },
  });

  const handleOpenAdd = async () => {
    // If no categories exist, seed baseline categories
    if (categories.length === 0 && currentOrg) {
      await supabase.from('expense_categories').insert([
        { organization_id: currentOrg.id, name: 'Shop Rent' },
        { organization_id: currentOrg.id, name: 'Utilities & Electricity' },
        { organization_id: currentOrg.id, name: 'Staff Salaries' },
        { organization_id: currentOrg.id, name: 'Transportation & Logistics' },
        { organization_id: currentOrg.id, name: 'Packaging & Bags' },
      ]);
      queryClient.invalidateQueries({ queryKey: ['expense_categories'] });
    }

    reset({
      title: '',
      categoryId: categories[0]?.id || '',
      amount: 0,
      expenseDate: new Date().toISOString().split('T')[0],
      paymentMethod: 'cash',
      notes: '',
    });
    setModalOpen(true);
  };

  const onSubmit = async (data: ExpenseFormData) => {
    if (!currentOrg) return;

    try {
      const { error } = await supabase.from('expenses').insert({
        organization_id: currentOrg.id,
        title: data.title,
        category_id: data.categoryId,
        amount: data.amount,
        expense_date: data.expenseDate,
        payment_method: data.paymentMethod,
        notes: data.notes || null,
      } as any);

      if (error) throw error;

      showSuccess('Expense recorded successfully');
      queryClient.invalidateQueries({ queryKey: ['expenses_list'] });
      setModalOpen(false);
    } catch (err: any) {
      showError(err.message || 'Failed to record expense');
    }
  };

  const totalExpenses = expenses.reduce((acc, ex) => acc + Number(ex.amount), 0);

  return (
    <Box>
      <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', mb: 3 }}>
        <div>
          <Typography variant="h4" sx={{ fontWeight: 800 }}>
            Operational Expenses
          </Typography>
          <Typography variant="body2" color="text.secondary">
            Track overhead costs, logistics, utilities, and daily petty cash.
          </Typography>
        </div>
        <Button
          variant="contained"
          startIcon={<AddIcon />}
          onClick={handleOpenAdd}
          sx={{ borderRadius: 2, bgcolor: '#0f172a', fontWeight: 600 }}
        >
          Add Expense
        </Button>
      </Box>

      {/* Summary Banner */}
      <Paper elevation={0} sx={{ p: 2.5, mb: 3, borderRadius: 3, border: '1px solid #e2e8f0', bgcolor: '#ffffff', display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
        <Typography variant="subtitle1" sx={{ fontWeight: 600 }}>
          Total Recorded Expenses:
        </Typography>
        <Typography variant="h5" sx={{ fontWeight: 800, color: '#ef4444' }}>
          {formatCurrency(totalExpenses)}
        </Typography>
      </Paper>

      {/* Table */}
      <Paper elevation={0} sx={{ borderRadius: 3, border: '1px solid #e2e8f0', bgcolor: '#ffffff' }}>
        <TableContainer>
          <Table>
            <TableHead>
              <TableRow>
                <TableCell>Date</TableCell>
                <TableCell>Expense Title</TableCell>
                <TableCell>Category</TableCell>
                <TableCell>Method</TableCell>
                <TableCell align="right">Amount</TableCell>
                <TableCell>Notes</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {isLoading ? (
                <TableRow>
                  <TableCell colSpan={6} align="center" sx={{ py: 6 }}>
                    <CircularProgress size={32} />
                  </TableCell>
                </TableRow>
              ) : expenses.length > 0 ? (
                expenses.map((ex: any) => (
                  <TableRow key={ex.id} hover>
                    <TableCell>{ex.expense_date}</TableCell>
                    <TableCell sx={{ fontWeight: 600 }}>{ex.title}</TableCell>
                    <TableCell>
                      <Chip label={ex.expense_categories?.name || 'General'} size="small" sx={{ height: 22, fontSize: 11 }} />
                    </TableCell>
                    <TableCell>
                      <Chip label={ex.payment_method.toUpperCase()} size="small" variant="outlined" sx={{ height: 20, fontSize: 10 }} />
                    </TableCell>
                    <TableCell align="right" sx={{ fontWeight: 700, color: '#ef4444' }}>
                      {formatCurrency(ex.amount)}
                    </TableCell>
                    <TableCell color="text.secondary">{ex.notes || '-'}</TableCell>
                  </TableRow>
                ))
              ) : (
                <TableRow>
                  <TableCell colSpan={6} align="center" sx={{ py: 6, color: 'text.secondary' }}>
                    No expenses recorded yet.
                  </TableCell>
                </TableRow>
              )}
            </TableBody>
          </Table>
        </TableContainer>
      </Paper>

      {/* Add Expense Modal */}
      <Dialog open={modalOpen} onClose={() => setModalOpen(false)} maxWidth="sm" fullWidth>
        <DialogTitle sx={{ fontWeight: 700 }}>Record Operational Expense</DialogTitle>
        <form onSubmit={handleSubmit(onSubmit)}>
          <DialogContent dividers>
            <Grid container spacing={2}>
              <Grid item xs={12}>
                <TextField
                  fullWidth
                  size="small"
                  label="Expense Description / Title"
                  placeholder="e.g. November Shop Electricity Bill"
                  {...register('title')}
                  error={Boolean(errors.title)}
                  helperText={errors.title?.message}
                />
              </Grid>
              <Grid item xs={12} sm={6}>
                <TextField
                  fullWidth
                  size="small"
                  select
                  label="Category"
                  defaultValue={categories[0]?.id || ''}
                  {...register('categoryId')}
                  error={Boolean(errors.categoryId)}
                  helperText={errors.categoryId?.message}
                >
                  {categories.map((c) => (
                    <MenuItem key={c.id} value={c.id}>
                      {c.name}
                    </MenuItem>
                  ))}
                </TextField>
              </Grid>
              <Grid item xs={12} sm={6}>
                <TextField
                  fullWidth
                  size="small"
                  type="number"
                  label="Amount (MMK)"
                  {...register('amount')}
                  error={Boolean(errors.amount)}
                  helperText={errors.amount?.message}
                />
              </Grid>
              <Grid item xs={12} sm={6}>
                <TextField
                  fullWidth
                  size="small"
                  type="date"
                  label="Expense Date"
                  {...register('expenseDate')}
                  InputLabelProps={{ shrink: true }}
                />
              </Grid>
              <Grid item xs={12} sm={6}>
                <TextField
                  fullWidth
                  size="small"
                  select
                  label="Payment Method"
                  defaultValue="cash"
                  {...register('paymentMethod')}
                >
                  <MenuItem value="cash">Cash</MenuItem>
                  <MenuItem value="kbz_pay">KBZPay</MenuItem>
                  <MenuItem value="wave_pay">WavePay</MenuItem>
                  <MenuItem value="bank_transfer">Bank Transfer</MenuItem>
                </TextField>
              </Grid>
              <Grid item xs={12}>
                <TextField
                  fullWidth
                  size="small"
                  label="Notes / Receipt Reference"
                  multiline
                  rows={2}
                  {...register('notes')}
                />
              </Grid>
            </Grid>
          </DialogContent>
          <DialogActions sx={{ px: 3, py: 2 }}>
            <Button onClick={() => setModalOpen(false)} disabled={isSubmitting}>
              Cancel
            </Button>
            <Button
              type="submit"
              variant="contained"
              disabled={isSubmitting}
              sx={{ bgcolor: '#0f172a', fontWeight: 600 }}
            >
              {isSubmitting ? <CircularProgress size={20} color="inherit" /> : 'Save Expense'}
            </Button>
          </DialogActions>
        </form>
      </Dialog>
    </Box>
  );
};

