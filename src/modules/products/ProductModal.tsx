import React, { useCallback, useEffect, useState } from 'react';
import {
  Dialog,
  DialogTitle,
  DialogContent,
  DialogActions,
  Button,
  TextField,
  Grid,
  MenuItem,
  CircularProgress,
} from '@mui/material';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import * as z from 'zod';
import { supabase } from '@/lib/supabase';
import { useOrg } from '@/context/OrgContext';
import { useNotification } from '@/context/NotificationContext';
import { useQueryClient } from '@tanstack/react-query';
import { useI18n } from '@/i18n/I18nContext';
import { useEntitlements } from '@/modules/subscription/useEntitlements';
import QrCodeScannerIcon from '@mui/icons-material/QrCodeScanner';
import BarcodeScannerIcon from '@mui/icons-material/DocumentScanner';
import { CodeScannerDialog, ScanMode } from './CodeScannerDialog';

const productSchema = z.object({
  sku: z.string().min(1, 'SKU is required'),
  name: z.string().min(1, 'Product name is required'),
  barcode: z.string().optional(),
  qrCode: z.string().optional(),
  categoryId: z.string().optional(),
  unitId: z.string().min(1, 'Unit of measurement is required'),
  purchasePrice: z.coerce.number().min(0, 'Purchase price must be positive'),
  salePrice: z.coerce.number().min(0, 'Sale price must be positive'),
  lowStockThreshold: z.coerce.number().min(0, 'Threshold must be positive'),
  description: z.string().optional(),
});

type ProductFormData = z.infer<typeof productSchema>;

interface ProductModalProps {
  open: boolean;
  onClose: () => void;
  product?: any;
  categories: any[];
  units: any[];
}

export const ProductModal: React.FC<ProductModalProps> = ({
  open,
  onClose,
  product,
  categories,
  units,
}) => {
  const { t } = useI18n();
  const { currentOrg } = useOrg();
  const { data: entitlements = [] } = useEntitlements();
  const { showSuccess, showError } = useNotification();
  const queryClient = useQueryClient();

  const isEdit = Boolean(product);
  const canUseBarcode = entitlements.some((item) => item.feature_key === 'barcode_support' && item.is_allowed);
  const canUseQr = entitlements.some((item) => item.feature_key === 'qr_support' && item.is_allowed);
  const [scanMode, setScanMode] = useState<ScanMode | null>(null);

  const {
    register,
    handleSubmit,
    reset,
    setValue,
    formState: { errors, isSubmitting },
  } = useForm<ProductFormData>({
    resolver: zodResolver(productSchema),
    defaultValues: {
      sku: '',
      name: '',
      barcode: '',
      qrCode: '',
      categoryId: '',
      unitId: units[0]?.id || '',
      purchasePrice: 0,
      salePrice: 0,
      lowStockThreshold: 5,
      description: '',
    },
  });

  useEffect(() => {
    if (product) {
      reset({
        sku: product.sku,
        name: product.name,
        barcode: product.barcode || '',
        qrCode: product.qr_code || '',
        categoryId: product.category_id || '',
        unitId: product.unit_id,
        purchasePrice: Number(product.purchase_price),
        salePrice: Number(product.sale_price),
        lowStockThreshold: Number(product.low_stock_threshold),
        description: product.description || '',
      });
    } else {
      reset({
        sku: `SKU-${Math.floor(1000 + Math.random() * 9000)}`,
        name: '',
        barcode: '',
        qrCode: '',
        categoryId: '',
        unitId: units[0]?.id || '',
        purchasePrice: 0,
        salePrice: 0,
        lowStockThreshold: 5,
        description: '',
      });
    }
  }, [product, units, reset, open]);

  const onSubmit = async (data: ProductFormData) => {
    if (!currentOrg) return;

    try {
      if (isEdit) {
        const { error } = await supabase
          .from('products')
          .update({
            sku: data.sku,
            name: data.name,
            barcode: data.barcode || null,
            qr_code: data.qrCode || null,
            category_id: data.categoryId || null,
            unit_id: data.unitId,
            purchase_price: data.purchasePrice,
            sale_price: data.salePrice,
            low_stock_threshold: data.lowStockThreshold,
            description: data.description || null,
            updated_at: new Date().toISOString(),
          } as any)
          .eq('id', product.id)
          .eq('organization_id', currentOrg.id);

        if (error) throw error;
        showSuccess('Product updated successfully');
      } else {
        const { error } = await supabase.from('products').insert({
          organization_id: currentOrg.id,
          sku: data.sku,
          name: data.name,
          barcode: data.barcode || null,
          qr_code: data.qrCode || null,
          category_id: data.categoryId || null,
          unit_id: data.unitId,
          purchase_price: data.purchasePrice,
          sale_price: data.salePrice,
          average_cost: data.purchasePrice, // Initialize average cost to purchase price
          low_stock_threshold: data.lowStockThreshold,
          description: data.description || null,
        } as any);

        if (error) throw error;
        showSuccess('Product created successfully');
      }

      queryClient.invalidateQueries({ queryKey: ['products'] });
      queryClient.invalidateQueries({ queryKey: ['product_stock_balances'] });
      queryClient.invalidateQueries({ queryKey: ['stock_balances'] });
      queryClient.invalidateQueries({ queryKey: ['branch_stock_balances'] });
      queryClient.invalidateQueries({ queryKey: ['products_for_pos'] });
      queryClient.invalidateQueries({ queryKey: ['dashboard_metrics'] });
      onClose();
    } catch (err: any) {
      showError(err.message || 'Failed to save product');
    }
  };

  const handleCodeDetected = useCallback((value: string) => {
    setValue(scanMode === 'qr' ? 'qrCode' : 'barcode', value, { shouldDirty: true, shouldValidate: true });
    setScanMode(null);
  }, [scanMode, setValue]);

  return (
    <Dialog open={open} onClose={onClose} maxWidth="sm" fullWidth>
      <DialogTitle sx={{ fontWeight: 700 }}>
        {isEdit ? 'Edit Product' : 'Add New Product'}
      </DialogTitle>
      <form onSubmit={handleSubmit(onSubmit)}>
        <DialogContent dividers>
          <Grid container spacing={2}>
            <Grid item xs={12} sm={6}>
              <TextField
                fullWidth
                size="small"
                label={t("SKU Code")}
                {...register('sku')}
                error={Boolean(errors.sku)}
                helperText={errors.sku?.message}
              />
            </Grid>
            {canUseBarcode && <>
              <Grid item xs={12} sm={6}>
                <TextField fullWidth size="small" label={t('Barcode / GTIN (Optional)')} {...register('barcode')} />
              </Grid>
              <Grid item xs={12} sm={6} sx={{ display: 'flex', gap: 1, alignItems: 'center' }}>
                <Button size="small" variant="outlined" startIcon={<BarcodeScannerIcon />} onClick={() => setScanMode('barcode')}>{t('Scan Barcode')}</Button>
              </Grid>
            </>}
            {canUseQr && <>
              <Grid item xs={12} sm={6}><TextField fullWidth size="small" label={t('QR Code Value (Optional)')} {...register('qrCode')} /></Grid>
              <Grid item xs={12} sm={6} sx={{ display: 'flex', gap: 1, alignItems: 'center' }}>
                <Button size="small" variant="outlined" startIcon={<QrCodeScannerIcon />} onClick={() => setScanMode('qr')}>{t('Scan QR')}</Button>
              </Grid>
            </>}
            <Grid item xs={12}>
              <TextField
                fullWidth
                size="small"
                label={t("Product Name")}
                {...register('name')}
                error={Boolean(errors.name)}
                helperText={errors.name?.message}
              />
            </Grid>
            <Grid item xs={12} sm={6}>
              <TextField
                fullWidth
                size="small"
                select
                label={t("Category")}
                defaultValue=""
                {...register('categoryId')}
              >
                <MenuItem value="">-- None --</MenuItem>
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
                select
                label={t("Unit of Measurement")}
                defaultValue={units[0]?.id || ''}
                {...register('unitId')}
                error={Boolean(errors.unitId)}
                helperText={errors.unitId?.message}
              >
                {units.map((u) => (
                  <MenuItem key={u.id} value={u.id}>
                    {u.name} ({u.code})
                  </MenuItem>
                ))}
              </TextField>
            </Grid>
            <Grid item xs={12} sm={6}>
              <TextField
                fullWidth
                size="small"
                type="number"
                label={t("Purchase Price (MMK)")}
                {...register('purchasePrice')}
                error={Boolean(errors.purchasePrice)}
                helperText={errors.purchasePrice?.message}
              />
            </Grid>
            <Grid item xs={12} sm={6}>
              <TextField
                fullWidth
                size="small"
                type="number"
                label={t("Selling Price (MMK)")}
                {...register('salePrice')}
                error={Boolean(errors.salePrice)}
                helperText={errors.salePrice?.message}
              />
            </Grid>
            <Grid item xs={12} sm={6}>
              <TextField
                fullWidth
                size="small"
                type="number"
                label={t("Low Stock Alert Threshold")}
                {...register('lowStockThreshold')}
                error={Boolean(errors.lowStockThreshold)}
                helperText={errors.lowStockThreshold?.message}
              />
            </Grid>
            <Grid item xs={12}>
              <TextField
                fullWidth
                size="small"
                multiline
                rows={2}
                label={t("Description / Notes")}
                {...register('description')}
              />
            </Grid>
          </Grid>
        </DialogContent>
        <DialogActions sx={{ px: 3, py: 2 }}>
          <Button onClick={onClose} disabled={isSubmitting}>
            {t("Cancel")}</Button>
          <Button
            type="submit"
            variant="contained"
            disabled={isSubmitting}
            sx={{ bgcolor: '#0f172a', fontWeight: 600, borderRadius: 2 }}
          >
            {isSubmitting ? <CircularProgress size={20} color="inherit" /> : 'Save Product'}
          </Button>
        </DialogActions>
      </form>
      <CodeScannerDialog mode={scanMode} onClose={() => setScanMode(null)} onDetected={handleCodeDetected} />
    </Dialog>
  );
};

