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
  Chip,
  IconButton,
  CircularProgress,
  MenuItem,
} from '@mui/material';
import AddIcon from '@mui/icons-material/Add';
import SearchIcon from '@mui/icons-material/Search';
import EditIcon from '@mui/icons-material/Edit';
import WarningAmberIcon from '@mui/icons-material/WarningAmber';
import FileDownloadIcon from '@mui/icons-material/FileDownload';
import UploadFileIcon from '@mui/icons-material/UploadFile';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/lib/supabase';
import { useOrg } from '@/context/OrgContext';
import { useNotification } from '@/context/NotificationContext';
import { ProductModal } from './ProductModal';
import { useI18n } from '@/i18n/I18nContext';

export const ProductsPage: React.FC = () => {
  const { t } = useI18n();
  const { currentOrg, formatCurrency } = useOrg();
  const { showSuccess, showError } = useNotification();
  const queryClient = useQueryClient();
  const orgId = currentOrg?.id;

  const [search, setSearch] = useState('');
  const [categoryFilter, setCategoryFilter] = useState('');
  const [modalOpen, setModalOpen] = useState(false);
  const [editingProduct, setEditingProduct] = useState<any>(null);
  const [importing, setImporting] = useState(false);

  // 1. Fetch Categories
  const { data: categories = [] } = useQuery({
    queryKey: ['categories', orgId],
    queryFn: async () => {
      if (!orgId) return [];
      const { data } = await supabase
        .from('product_categories')
        .select('*')
        .eq('organization_id', orgId)
        .order('name');
      return data || [];
    },
    enabled: Boolean(orgId),
  });

  // 2. Fetch Units
  const { data: units = [] } = useQuery({
    queryKey: ['units', orgId],
    queryFn: async () => {
      if (!orgId) return [];
      const { data } = await supabase
        .from('units')
        .select('*')
        .eq('organization_id', orgId)
        .order('name');
      return data || [];
    },
    enabled: Boolean(orgId),
  });

  // 3. Fetch Products with current stock balance
  const { data: products = [], isLoading } = useQuery({
    queryKey: ['products', orgId, search, categoryFilter],
    queryFn: async () => {
      if (!orgId) return [];

      let query = supabase
        .from('products')
        .select(`
          *,
          product_categories(name),
          units(name, code)
        `)
        .eq('organization_id', orgId)
        .eq('is_active', true)
        .order('name');

      if (categoryFilter) {
        query = query.eq('category_id', categoryFilter);
      }

      if (search) {
        query = query.or(`name.ilike.%${search}%,sku.ilike.%${search}%`);
      }

      const { data, error } = await query;
      if (error) throw error;

      // Fetch stock balances
      const { data: stockBalances } = await supabase
        .from('product_stock_balances')
        .select('product_id, stock_on_hand, is_low_stock')
        .eq('organization_id', orgId);

      const balanceMap = new Map();
      stockBalances?.forEach((b) => {
        balanceMap.set(b.product_id, b);
      });

      return (data || []).map((p) => {
        const bal = balanceMap.get(p.id);
        return {
          ...p,
          stock_on_hand: bal ? Number(bal.stock_on_hand) : 0,
          is_low_stock: bal ? Boolean(bal.is_low_stock) : false,
        };
      });
    },
    enabled: Boolean(orgId),
  });

  const handleDownloadTemplate = () => {
    const csvContent =
      'sku,name,sale_price,cost_price,low_stock_threshold\n' +
      'SKU-001,Premium Jasmine Rice 50kg,85000,75000,10\n' +
      'SKU-002,Sunflower Cooking Oil 1L,6500,5500,20\n' +
      'SKU-003,Instant Noodles Box (30pk),18000,15000,15\n';
    const blob = new Blob([csvContent], { type: 'text/csv;charset=utf-8;' });
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url;
    link.setAttribute('download', 'lwal_kuu_product_import_template.csv');
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
  };

  const handleFileUpload = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file || !orgId) return;

    try {
      setImporting(true);
      const text = await file.text();
      const lines = text.split('\n').map((l) => l.trim()).filter((l) => l.length > 0);
      if (lines.length <= 1) {
        showError('CSV file is empty or has no data rows');
        return;
      }

      const defaultUnitId = units[0]?.id;
      if (!defaultUnitId) {
        showError('Please create at least one measurement unit first');
        return;
      }

      const productsToInsert = [];
      for (let i = 1; i < lines.length; i++) {
        const parts = lines[i].split(',').map((p) => p.trim());
        if (parts.length >= 2 && parts[1]) {
          productsToInsert.push({
            organization_id: orgId,
            sku: parts[0] || `SKU-${Date.now()}-${i}`,
            name: parts[1],
            unit_id: defaultUnitId,
            sale_price: Number(parts[2]) || 0,
            average_cost: Number(parts[3]) || 0,
            cost_price: Number(parts[3]) || 0,
            low_stock_threshold: Number(parts[4]) || 5,
            is_active: true,
          });
        }
      }

      if (productsToInsert.length === 0) {
        showError('No valid product rows parsed from CSV');
        return;
      }

      const { error } = await supabase.from('products').insert(productsToInsert);
      if (error) throw error;

      showSuccess(`Successfully imported ${productsToInsert.length} products!`);
      queryClient.invalidateQueries({ queryKey: ['products'] });
    } catch (err: any) {
      showError(err.message || 'Failed to import products');
    } finally {
      setImporting(false);
      if (e.target) e.target.value = '';
    }
  };

  const handleOpenAdd = () => {
    setEditingProduct(null);
    setModalOpen(true);
  };

  const handleOpenEdit = (p: any) => {
    setEditingProduct(p);
    setModalOpen(true);
  };

  return (
    <Box>
      <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', mb: 3, flexWrap: 'wrap', gap: 2 }}>
        <div>
          <Typography variant="h4" sx={{ fontWeight: 800 }}>
            {t("Product Catalog")}</Typography>
          <Typography variant="body2" color="text.secondary">
            {t("Manage wholesale products, inventory pricing, and stock thresholds.")}</Typography>
        </div>
        <Box sx={{ display: 'flex', gap: 1.5, flexWrap: 'wrap' }}>
          <Button
            variant="outlined"
            size="small"
            startIcon={<FileDownloadIcon />}
            onClick={handleDownloadTemplate}
            sx={{ borderRadius: 2, fontWeight: 600, borderColor: '#cbd5e1', color: '#475569' }}
          >
            Template
          </Button>

          <Button
            variant="outlined"
            size="small"
            component="label"
            disabled={importing}
            startIcon={importing ? <CircularProgress size={16} /> : <UploadFileIcon />}
            sx={{ borderRadius: 2, fontWeight: 600, borderColor: '#cbd5e1', color: '#0284c7' }}
          >
            {t("Import CSV")}<input type="file" accept=".csv" hidden onChange={handleFileUpload} />
          </Button>

          <Button
            variant="contained"
            startIcon={<AddIcon />}
            onClick={handleOpenAdd}
            sx={{ borderRadius: 2, bgcolor: '#0f172a', fontWeight: 600 }}
          >
            {t("Add Product")}</Button>
        </Box>
      </Box>

      {/* Filter Bar */}
      <Paper elevation={0} sx={{ p: 2, mb: 3, borderRadius: 3, border: '1px solid #e2e8f0', bgcolor: '#ffffff' }}>
        <Box sx={{ display: 'flex', gap: 2, flexWrap: 'wrap' }}>
          <TextField
            size="small"
            placeholder={t("Search by SKU or Name...")}
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            fullWidth
            sx={{ width: { xs: '100%', sm: 'auto' }, minWidth: { xs: 0, sm: 260 }, flex: { sm: '1 1 260px' } }}
            InputProps={{
              startAdornment: (
                <InputAdornment position="start">
                  <SearchIcon fontSize="small" sx={{ color: 'text.secondary' }} />
                </InputAdornment>
              ),
            }}
          />

          <TextField
            size="small"
            select
            label={t("Category")}
            value={categoryFilter}
            onChange={(e) => setCategoryFilter(e.target.value)}
            fullWidth
            sx={{ width: { xs: '100%', sm: 'auto' }, minWidth: { xs: 0, sm: 180 }, flex: { sm: '0 1 220px' } }}
          >
            <MenuItem value="">{t("All Categories")}</MenuItem>
            {categories.map((c) => (
              <MenuItem key={c.id} value={c.id}>
                {c.name}
              </MenuItem>
            ))}
          </TextField>
        </Box>
      </Paper>

      {/* Products Table */}
      <Paper elevation={0} sx={{ borderRadius: 3, border: '1px solid #e2e8f0', bgcolor: '#ffffff', overflow: 'hidden' }}>
        <TableContainer>
          <Table>
            <TableHead>
              <TableRow>
                <TableCell>{t("SKU")}</TableCell>
                <TableCell>{t("Product Name")}</TableCell>
                <TableCell>{t("Category")}</TableCell>
                <TableCell>{t("Unit")}</TableCell>
                <TableCell align="right">{t("Cost Price")}</TableCell>
                <TableCell align="right">{t("Sale Price")}</TableCell>
                <TableCell align="center">{t("Stock on Hand")}</TableCell>
                <TableCell align="center">Actions</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {isLoading ? (
                <TableRow>
                  <TableCell colSpan={8} align="center" sx={{ py: 6 }}>
                    <CircularProgress size={32} />
                  </TableCell>
                </TableRow>
              ) : products.length > 0 ? (
                products.map((p) => (
                  <TableRow key={p.id} hover>
                    <TableCell sx={{ fontWeight: 600, color: '#0284c7' }}>{p.sku}</TableCell>
                    <TableCell sx={{ fontWeight: 600 }}>{p.name}</TableCell>
                    <TableCell>
                      {p.product_categories ? (
                        <Chip label={p.product_categories.name} size="small" sx={{ height: 22, fontSize: 11 }} />
                      ) : (
                        '-'
                      )}
                    </TableCell>
                    <TableCell>{p.units?.name || '-'}</TableCell>
                    <TableCell align="right">{formatCurrency(p.average_cost || p.purchase_price)}</TableCell>
                    <TableCell align="right" sx={{ fontWeight: 700 }}>
                      {formatCurrency(p.sale_price)}
                    </TableCell>
                    <TableCell align="center">
                      <Box sx={{ display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 0.5 }}>
                        <Typography sx={{ fontWeight: 700 }}>
                          {p.stock_on_hand} {p.units?.code}
                        </Typography>
                        {p.is_low_stock && (
                          <WarningAmberIcon sx={{ color: '#ef4444', fontSize: 18 }} titleAccess="Low Stock Alert" />
                        )}
                      </Box>
                    </TableCell>
                    <TableCell align="center">
                      <IconButton size="small" onClick={() => handleOpenEdit(p)}>
                        <EditIcon fontSize="small" />
                      </IconButton>
                    </TableCell>
                  </TableRow>
                ))
              ) : (
                <TableRow>
                  <TableCell colSpan={8} align="center" sx={{ py: 6, color: 'text.secondary' }}>
                    No products found. Click &quot;Add Product&quot; to build your catalog.
                  </TableCell>
                </TableRow>
              )}
            </TableBody>
          </Table>
        </TableContainer>
      </Paper>

      <ProductModal
        open={modalOpen}
        onClose={() => setModalOpen(false)}
        product={editingProduct}
        categories={categories}
        units={units}
      />
    </Box>
  );
};

