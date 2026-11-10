import React, { useState } from 'react';
import {
  Box,
  Typography,
  Button,
  Paper,
  Tabs,
  Tab,
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
import TuneIcon from '@mui/icons-material/Tune';
import WarningAmberIcon from '@mui/icons-material/WarningAmber';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/lib/supabase';
import { useOrg } from '@/context/OrgContext';
import { useNotification } from '@/context/NotificationContext';

export const InventoryPage: React.FC = () => {
  const { currentOrg, formatCurrency } = useOrg();
  const { showSuccess, showError } = useNotification();
  const queryClient = useQueryClient();
  const orgId = currentOrg?.id;

  const [currentTab, setCurrentTab] = useState(0);
  const [adjustModalOpen, setAdjustModalOpen] = useState(false);

  // Adjustment form state
  const [adjustProductId, setAdjustProductId] = useState('');
  const [adjustDelta, setAdjustDelta] = useState<number>(0);
  const [adjustReason, setAdjustReason] = useState('damaged');
  const [adjustNotes, setAdjustNotes] = useState('');
  const [adjusting, setAdjusting] = useState(false);

  // 1. Fetch Current Stock Balances
  const { data: stockBalances = [], isLoading: balancesLoading } = useQuery({
    queryKey: ['stock_balances', orgId],
    queryFn: async () => {
      if (!orgId) return [];
      const { data, error } = await supabase
        .from('product_stock_balances')
        .select('*')
        .eq('organization_id', orgId)
        .order('name');
      if (error) throw error;
      return data || [];
    },
    enabled: Boolean(orgId),
  });

  // 2. Fetch Stock Movements Ledger
  const { data: movements = [], isLoading: movementsLoading } = useQuery({
    queryKey: ['stock_movements', orgId],
    queryFn: async () => {
      if (!orgId) return [];
      const { data, error } = await supabase
        .from('stock_movements')
        .select(`
          *,
          products(sku, name, units(code))
        `)
        .eq('organization_id', orgId)
        .order('created_at', { ascending: false })
        .limit(100);
      if (error) throw error;
      return data || [];
    },
    enabled: Boolean(orgId),
  });

  const handleCreateAdjustment = async () => {
    if (!currentOrg || !adjustProductId || adjustDelta === 0) {
      showError('Please select a product and enter non-zero adjustment quantity');
      return;
    }

    try {
      setAdjusting(true);
      const { error } = await supabase.rpc('create_stock_adjustment', {
        p_org_id: currentOrg.id,
        p_product_id: adjustProductId,
        p_quantity_delta: adjustDelta,
        p_reason: adjustReason,
        p_notes: adjustNotes || null,
      });

      if (error) throw error;

      showSuccess('Stock adjustment ledger entry posted successfully');
      queryClient.invalidateQueries({ queryKey: ['stock_balances'] });
      queryClient.invalidateQueries({ queryKey: ['stock_movements'] });
      queryClient.invalidateQueries({ queryKey: ['dashboard_metrics'] });
      setAdjustModalOpen(false);
      setAdjustDelta(0);
      setAdjustNotes('');
    } catch (err: any) {
      showError(err.message || 'Failed to adjust stock');
    } finally {
      setAdjusting(false);
    }
  };

  return (
    <Box>
      <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', mb: 3 }}>
        <div>
          <Typography variant="h4" sx={{ fontWeight: 800 }}>
            Inventory Ledger & Balances
          </Typography>
          <Typography variant="body2" color="text.secondary">
            Immutable movement ledger, real-time stock on hand, and administrative adjustments.
          </Typography>
        </div>
        <Button
          variant="contained"
          startIcon={<TuneIcon />}
          onClick={() => {
            setAdjustProductId(stockBalances[0]?.product_id || '');
            setAdjustModalOpen(true);
          }}
          sx={{ borderRadius: 2, bgcolor: '#0f172a', fontWeight: 600 }}
        >
          Stock Adjustment
        </Button>
      </Box>

      <Paper elevation={0} sx={{ borderRadius: 3, border: '1px solid #e2e8f0', bgcolor: '#ffffff', mb: 3 }}>
        <Tabs
          value={currentTab}
          onChange={(_e, v) => setCurrentTab(v)}
          sx={{ px: 2, borderBottom: '1px solid #e2e8f0' }}
        >
          <Tab label="Current Stock on Hand" sx={{ fontWeight: 600 }} />
          <Tab label="Stock Movements Audit Ledger" sx={{ fontWeight: 600 }} />
        </Tabs>

        {currentTab === 0 ? (
          <TableContainer>
            <Table>
              <TableHead>
                <TableRow>
                  <TableCell>SKU</TableCell>
                  <TableCell>Product Name</TableCell>
                  <TableCell align="center">Unit</TableCell>
                  <TableCell align="right">Cost Price (Avg)</TableCell>
                  <TableCell align="right">Selling Price</TableCell>
                  <TableCell align="center">Stock on Hand</TableCell>
                  <TableCell align="right">Total Stock Value</TableCell>
                </TableRow>
              </TableHead>
              <TableBody>
                {balancesLoading ? (
                  <TableRow>
                    <TableCell colSpan={7} align="center" sx={{ py: 6 }}>
                      <CircularProgress size={32} />
                    </TableCell>
                  </TableRow>
                ) : stockBalances.length > 0 ? (
                  stockBalances.map((b: any) => (
                    <TableRow key={b.product_id} hover>
                      <TableCell sx={{ fontWeight: 600, color: '#0284c7' }}>{b.sku}</TableCell>
                      <TableCell sx={{ fontWeight: 600 }}>{b.name}</TableCell>
                      <TableCell align="center">{b.unit_name} ({b.unit_code})</TableCell>
                      <TableCell align="right">{formatCurrency(b.average_cost)}</TableCell>
                      <TableCell align="right">{formatCurrency(b.sale_price)}</TableCell>
                      <TableCell align="center">
                        <Box sx={{ display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 0.5 }}>
                          <Typography sx={{ fontWeight: 700 }}>
                            {b.stock_on_hand}
                          </Typography>
                          {b.is_low_stock && (
                            <WarningAmberIcon sx={{ color: '#ef4444', fontSize: 18 }} />
                          )}
                        </Box>
                      </TableCell>
                      <TableCell align="right" sx={{ fontWeight: 700 }}>
                        {formatCurrency(b.stock_value)}
                      </TableCell>
                    </TableRow>
                  ))
                ) : (
                  <TableRow>
                    <TableCell colSpan={7} align="center" sx={{ py: 6, color: 'text.secondary' }}>
                      No stock balances recorded.
                    </TableCell>
                  </TableRow>
                )}
              </TableBody>
            </Table>
          </TableContainer>
        ) : (
          <TableContainer>
            <Table size="small">
              <TableHead>
                <TableRow>
                  <TableCell>Date & Time</TableCell>
                  <TableCell>Product</TableCell>
                  <TableCell>Movement Type</TableCell>
                  <TableCell align="right">Quantity</TableCell>
                  <TableCell align="right">Cost at Move</TableCell>
                  <TableCell>Reference</TableCell>
                  <TableCell>Notes</TableCell>
                </TableRow>
              </TableHead>
              <TableBody>
                {movementsLoading ? (
                  <TableRow>
                    <TableCell colSpan={7} align="center" sx={{ py: 6 }}>
                      <CircularProgress size={32} />
                    </TableCell>
                  </TableRow>
                ) : movements.length > 0 ? (
                  movements.map((m: any) => {
                    const isPositive = Number(m.quantity) > 0;
                    return (
                      <TableRow key={m.id} hover>
                        <TableCell>{new Date(m.created_at).toLocaleString()}</TableCell>
                        <TableCell sx={{ fontWeight: 600 }}>
                          {m.products?.name} ({m.products?.sku})
                        </TableCell>
                        <TableCell>
                          <Chip
                            label={m.movement_type}
                            size="small"
                            color={isPositive ? 'success' : 'error'}
                            sx={{ height: 22, fontSize: 11, fontWeight: 600 }}
                          />
                        </TableCell>
                        <TableCell align="right" sx={{ fontWeight: 700, color: isPositive ? '#10b981' : '#ef4444' }}>
                          {isPositive ? `+${m.quantity}` : m.quantity} {m.products?.units?.code}
                        </TableCell>
                        <TableCell align="right">{formatCurrency(m.unit_cost)}</TableCell>
                        <TableCell>{m.reference_type}</TableCell>
                        <TableCell color="text.secondary">{m.notes || '-'}</TableCell>
                      </TableRow>
                    );
                  })
                ) : (
                  <TableRow>
                    <TableCell colSpan={7} align="center" sx={{ py: 6, color: 'text.secondary' }}>
                      No movements recorded yet.
                    </TableCell>
                  </TableRow>
                )}
              </TableBody>
            </Table>
          </TableContainer>
        )}
      </Paper>

      {/* Stock Adjustment Modal */}
      <Dialog open={adjustModalOpen} onClose={() => setAdjustModalOpen(false)} maxWidth="sm" fullWidth>
        <DialogTitle sx={{ fontWeight: 700 }}>Record Stock Adjustment</DialogTitle>
        <DialogContent dividers>
          <Grid container spacing={2}>
            <Grid item xs={12}>
              <TextField
                fullWidth
                size="small"
                select
                label="Product"
                value={adjustProductId}
                onChange={(e) => setAdjustProductId(e.target.value)}
              >
                {stockBalances.map((b: any) => (
                  <MenuItem key={b.product_id} value={b.product_id}>
                    {b.name} ({b.sku}) - Current Stock: {b.stock_on_hand}
                  </MenuItem>
                ))}
              </TextField>
            </Grid>
            <Grid item xs={12} sm={6}>
              <TextField
                fullWidth
                size="small"
                type="number"
                label="Quantity Delta (e.g. -5 or +10)"
                value={adjustDelta}
                onChange={(e) => setAdjustDelta(Number(e.target.value))}
                helperText="Use negative for damages/loss, positive for found stock"
              />
            </Grid>
            <Grid item xs={12} sm={6}>
              <TextField
                fullWidth
                size="small"
                select
                label="Adjustment Reason"
                value={adjustReason}
                onChange={(e) => setAdjustReason(e.target.value)}
              >
                <MenuItem value="damaged">Damaged / Broken</MenuItem>
                <MenuItem value="expired">Expired Goods</MenuItem>
                <MenuItem value="count_correction">Count Discrepancy</MenuItem>
                <MenuItem value="loss">Lost / Theft</MenuItem>
                <MenuItem value="other">Other Reason</MenuItem>
              </TextField>
            </Grid>
            <Grid item xs={12}>
              <TextField
                fullWidth
                size="small"
                label="Explanation Notes"
                multiline
                rows={2}
                value={adjustNotes}
                onChange={(e) => setAdjustNotes(e.target.value)}
              />
            </Grid>
          </Grid>
        </DialogContent>
        <DialogActions sx={{ px: 3, py: 2 }}>
          <Button onClick={() => setAdjustModalOpen(false)} disabled={adjusting}>
            Cancel
          </Button>
          <Button
            variant="contained"
            onClick={handleCreateAdjustment}
            disabled={adjusting || adjustDelta === 0}
            sx={{ bgcolor: '#0f172a', fontWeight: 600 }}
          >
            {adjusting ? <CircularProgress size={20} color="inherit" /> : 'Apply Adjustment'}
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
};
