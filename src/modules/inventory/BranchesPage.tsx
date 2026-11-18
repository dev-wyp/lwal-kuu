import React, { useMemo, useState } from 'react';
import { Alert, Box, Button, CircularProgress, Grid, MenuItem, Paper, Table, TableBody, TableCell, TableContainer, TableHead, TableRow, TextField, Typography } from '@mui/material';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/lib/supabase';
import { useOrg } from '@/context/OrgContext';
import { useEntitlements } from '@/modules/subscription/useEntitlements';
import { useNotification } from '@/context/NotificationContext';
import { UsageLimitIndicator } from '@/modules/subscription/UsageLimitIndicator';
import { useI18n } from '@/i18n/I18nContext';

export const BranchesPage: React.FC = () => {
  const { t } = useI18n();
  const { currentOrg, formatCurrency } = useOrg();
  const { data: entitlements = [] } = useEntitlements();
  const { showError, showSuccess } = useNotification();
  const queryClient = useQueryClient();
  const orgId = currentOrg?.id;
  const branchLimit = entitlements.find((item) => item.feature_key === 'max_branches');
  const canTransfer = entitlements.some((item) => item.feature_key === 'stock_transfer' && item.is_allowed);
  const canViewBranchReports = entitlements.some((item) => item.feature_key === 'branch_reports' && item.is_allowed);
  const [branchName, setBranchName] = useState('');
  const [branchCode, setBranchCode] = useState('');
  const [sourceBranch, setSourceBranch] = useState('');
  const [destinationBranch, setDestinationBranch] = useState('');
  const [productId, setProductId] = useState('');
  const [quantity, setQuantity] = useState(1);
  const [notes, setNotes] = useState('');

  const branchesQuery = useQuery({
    queryKey: ['branches', orgId],
    enabled: Boolean(orgId),
    queryFn: async () => {
      const { data, error } = await supabase.from('branches' as any).select('*').eq('organization_id', orgId).eq('is_active', true).order('is_default', { ascending: false }).order('name');
      if (error) throw error;
      return data ?? [];
    },
  });
  const branches = useMemo(() => branchesQuery.data ?? [], [branchesQuery.data]);
  const source = branches.find((branch: any) => branch.id === sourceBranch) ?? branches[0];

  const stockQuery = useQuery({
    queryKey: ['branch_stock_balances', orgId, source?.id],
    enabled: Boolean(orgId && source?.id && canTransfer),
    queryFn: async () => {
      const { data, error } = await supabase.from('branch_stock_balances' as any).select('*')
        .eq('organization_id', orgId).eq('branch_id', source.id).gt('stock_on_hand', 0).order('product_name');
      if (error) throw error;
      return data ?? [];
    },
  });
  const selectedProduct = stockQuery.data?.find((item: any) => item.product_id === productId);

  const salesQuery = useQuery({
    queryKey: ['branch_sales_performance', orgId],
    enabled: Boolean(orgId && canViewBranchReports),
    queryFn: async () => {
      const { data, error } = await supabase.from('branch_sales_performance' as any).select('*').eq('organization_id', orgId).order('revenue', { ascending: false });
      if (error) throw error;
      return data ?? [];
    },
  });
  const transfersQuery = useQuery({
    queryKey: ['stock_transfers', orgId],
    enabled: Boolean(orgId && canTransfer),
    queryFn: async () => {
      const { data, error } = await supabase.from('stock_transfers' as any).select('*').eq('organization_id', orgId).order('created_at', { ascending: false }).limit(100);
      if (error) throw error;
      return data ?? [];
    },
  });

  const createBranch = useMutation({
    mutationFn: async () => {
      if (!orgId) throw new Error('Choose an organization first');
      const { error } = await supabase.from('branches' as any).insert({ organization_id: orgId, name: branchName.trim(), code: branchCode.trim().toUpperCase(), is_default: false });
      if (error) throw error;
    },
    onSuccess: async () => {
      setBranchName(''); setBranchCode('');
      showSuccess(t('Branch created.'));
      await Promise.all([queryClient.invalidateQueries({ queryKey: ['branches', orgId] }), queryClient.invalidateQueries({ queryKey: ['organization_entitlements', orgId] })]);
    },
    onError: (error) => showError(error.message || t('Could not create branch.')),
  });
  const submitTransfer = useMutation({
    mutationFn: async () => {
      if (!orgId || !source?.id || !destinationBranch || !productId) throw new Error(t('Complete the transfer details first.'));
      const { data, error } = await supabase.rpc('create_stock_transfer' as any, {
        p_org_id: orgId,
        p_source_branch_id: source.id,
        p_destination_branch_id: destinationBranch,
        p_items: [{ product_id: productId, quantity }],
        p_notes: notes || null,
      });
      if (error) throw error;
      return data;
    },
    onSuccess: async () => {
      setProductId(''); setQuantity(1); setNotes('');
      showSuccess(t('Stock transfer posted.'));
      await Promise.all([queryClient.invalidateQueries({ queryKey: ['branch_stock_balances'] }), queryClient.invalidateQueries({ queryKey: ['products_for_pos'] }), queryClient.invalidateQueries({ queryKey: ['stock_transfers'] }), queryClient.invalidateQueries({ queryKey: ['dashboard_metrics'] })]);
    },
    onError: (error) => showError(error.message || t('Stock transfer failed.')),
  });

  const branchNames = useMemo(() => new Map(branches.map((branch: any) => [branch.id, branch.name])), [branches]);
  const branchLimitReached = Boolean(branchLimit && branchLimit.limit_value != null && branchLimit.limit_value !== -1 && (branchLimit.current_usage ?? 0) >= branchLimit.limit_value);

  return <Box>
    <Typography variant="h4" fontWeight={800}>{t('Branches & Stock Transfers')}</Typography>
    <Typography color="text.secondary" sx={{ mt: 0.5, mb: 3 }}>{t('Manage locations, transfer stock between branches, and review branch sales.')}</Typography>
    {branchLimit && <Box sx={{ maxWidth: 420, mb: 2 }}><UsageLimitIndicator entitlement={branchLimit} /></Box>}

    <Paper sx={{ p: 2.5, mb: 3, border: '1px solid #e2e8f0' }}>
      <Typography variant="h6" fontWeight={700} sx={{ mb: 1.5 }}>{t('Active Branches')}</Typography>
      <TableContainer><Table size="small"><TableHead><TableRow><TableCell>{t('Branch')}</TableCell><TableCell>{t('Code')}</TableCell><TableCell>{t('Type')}</TableCell></TableRow></TableHead>
        <TableBody>{branchesQuery.isLoading ? <TableRow><TableCell colSpan={3} align="center"><CircularProgress size={24} /></TableCell></TableRow>
          : branches.map((branch: any) => <TableRow key={branch.id}><TableCell>{branch.name}</TableCell><TableCell>{branch.code}</TableCell><TableCell>{t(branch.is_default ? 'Main branch' : 'Additional branch')}</TableCell></TableRow>)}
        </TableBody></Table></TableContainer>
      {!branchLimitReached ? <Grid container spacing={1.5} sx={{ mt: 1 }}>
        <Grid item xs={12} sm={5}><TextField fullWidth size="small" label={t('Branch Name')} value={branchName} onChange={(event) => setBranchName(event.target.value)} /></Grid>
        <Grid item xs={12} sm={3}><TextField fullWidth size="small" label={t('Branch Code')} value={branchCode} onChange={(event) => setBranchCode(event.target.value)} /></Grid>
        <Grid item xs={12} sm={4}><Button fullWidth variant="contained" disabled={createBranch.isPending || !branchName.trim() || !branchCode.trim()} onClick={() => createBranch.mutate()}>{createBranch.isPending ? t('Creating…') : t('Add Branch')}</Button></Grid>
      </Grid> : <Alert severity="info" sx={{ mt: 2 }}>{t('Your branch limit has been reached.')}</Alert>}
    </Paper>

    {canTransfer && <Paper sx={{ p: 2.5, mb: 3, border: '1px solid #e2e8f0' }}>
      <Typography variant="h6" fontWeight={700} sx={{ mb: 1.5 }}>{t('Transfer Stock')}</Typography>
      {branches.length < 2 ? <Alert severity="info">{t('Add another branch before transferring stock.')}</Alert> : <Grid container spacing={1.5}>
        <Grid item xs={12} sm={6}><TextField select fullWidth size="small" label={t('From Branch')} value={source?.id ?? ''} onChange={(event) => { setSourceBranch(event.target.value); setProductId(''); }}>
          {branches.map((branch: any) => <MenuItem key={branch.id} value={branch.id}>{branch.name}</MenuItem>)}
        </TextField></Grid>
        <Grid item xs={12} sm={6}><TextField select fullWidth size="small" label={t('To Branch')} value={destinationBranch} onChange={(event) => setDestinationBranch(event.target.value)}>
          {branches.filter((branch: any) => branch.id !== source?.id).map((branch: any) => <MenuItem key={branch.id} value={branch.id}>{branch.name}</MenuItem>)}
        </TextField></Grid>
        <Grid item xs={12} sm={6}><TextField select fullWidth size="small" label={t('Product')} value={productId} onChange={(event) => setProductId(event.target.value)}>
          {(stockQuery.data ?? []).map((item: any) => <MenuItem key={item.product_id} value={item.product_id}>{item.product_name} · {item.stock_on_hand} {item.unit_code}</MenuItem>)}
        </TextField></Grid>
        <Grid item xs={12} sm={3}><TextField fullWidth size="small" type="number" label={t('Quantity')} value={quantity} onChange={(event) => setQuantity(Number(event.target.value))} inputProps={{ min: 0.01, max: selectedProduct?.stock_on_hand, step: 'any' }} /></Grid>
        <Grid item xs={12} sm={3}><Button fullWidth variant="contained" disabled={submitTransfer.isPending || !productId || !destinationBranch || quantity <= 0 || quantity > Number(selectedProduct?.stock_on_hand ?? 0)} onClick={() => submitTransfer.mutate()}>{submitTransfer.isPending ? t('Transferring…') : t('Post Transfer')}</Button></Grid>
        <Grid item xs={12}><TextField fullWidth size="small" label={t('Notes (Optional)')} value={notes} onChange={(event) => setNotes(event.target.value)} /></Grid>
      </Grid>}
      <Typography variant="subtitle2" fontWeight={700} sx={{ mt: 2 }}>{t('Recent Transfers')}</Typography>
      <TableContainer><Table size="small"><TableHead><TableRow><TableCell>{t('Transfer #')}</TableCell><TableCell>{t('From')}</TableCell><TableCell>{t('To')}</TableCell><TableCell>{t('Date')}</TableCell><TableCell>{t('Status')}</TableCell></TableRow></TableHead>
        <TableBody>{(transfersQuery.data ?? []).map((transfer: any) => <TableRow key={transfer.id}><TableCell>{transfer.transfer_number}</TableCell><TableCell>{branchNames.get(transfer.source_branch_id) ?? '—'}</TableCell><TableCell>{branchNames.get(transfer.destination_branch_id) ?? '—'}</TableCell><TableCell>{new Date(transfer.created_at).toLocaleDateString()}</TableCell><TableCell>{t(transfer.status)}</TableCell></TableRow>)}</TableBody>
      </Table></TableContainer>
    </Paper>}

    {canViewBranchReports && <Paper sx={{ p: 2.5, border: '1px solid #e2e8f0' }}>
      <Typography variant="h6" fontWeight={700} sx={{ mb: 1.5 }}>{t('Sales by Branch')}</Typography>
      <TableContainer><Table size="small"><TableHead><TableRow><TableCell>{t('Branch')}</TableCell><TableCell>{t('Invoices')}</TableCell><TableCell>{t('Revenue')}</TableCell><TableCell>{t('Cost of Goods')}</TableCell><TableCell>{t('Gross Profit')}</TableCell></TableRow></TableHead>
        <TableBody>{salesQuery.isLoading ? <TableRow><TableCell colSpan={5} align="center"><CircularProgress size={24} /></TableCell></TableRow>
          : (salesQuery.data ?? []).map((row: any) => <TableRow key={row.branch_id}><TableCell>{row.branch_name}</TableCell><TableCell>{row.invoice_count}</TableCell><TableCell>{formatCurrency(row.revenue)}</TableCell><TableCell>{formatCurrency(row.cost_of_goods)}</TableCell><TableCell>{formatCurrency(row.gross_profit)}</TableCell></TableRow>)}
        </TableBody></Table></TableContainer>
    </Paper>}
  </Box>;
};
