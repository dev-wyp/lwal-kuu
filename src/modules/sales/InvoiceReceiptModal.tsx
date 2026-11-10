import React from 'react';
import {
  Dialog,
  DialogTitle,
  DialogContent,
  DialogActions,
  Button,
  Box,
  Typography,
  Divider,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
} from '@mui/material';
import PrintIcon from '@mui/icons-material/Print';
import StorefrontIcon from '@mui/icons-material/Storefront';
import { useOrg } from '@/context/OrgContext';

interface InvoiceReceiptModalProps {
  open: boolean;
  onClose: () => void;
  sale: any;
}

export const InvoiceReceiptModal: React.FC<InvoiceReceiptModalProps> = ({
  open,
  onClose,
  sale,
}) => {
  const { currentOrg, settings, formatCurrency } = useOrg();

  if (!sale) return null;

  const handlePrint = () => {
    window.print();
  };

  return (
    <Dialog open={open} onClose={onClose} maxWidth="sm" fullWidth>
      <DialogTitle sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
        <Typography variant="h6" sx={{ fontWeight: 800 }}>
          Tax Invoice / Receipt
        </Typography>
        <Button startIcon={<PrintIcon />} variant="contained" size="small" onClick={handlePrint}>
          Print
        </Button>
      </DialogTitle>

      <DialogContent dividers sx={{ p: 4 }}>
        <Box sx={{ textAlign: 'center', mb: 3 }}>
          <StorefrontIcon sx={{ fontSize: 36, color: '#0284c7', mb: 0.5 }} />
          <Typography variant="h5" sx={{ fontWeight: 800 }}>
            {currentOrg?.name}
          </Typography>
          {settings?.address && (
            <Typography variant="caption" color="text.secondary" sx={{ display: 'block' }}>
              {settings.address}
            </Typography>
          )}
          {settings?.phone && (
            <Typography variant="caption" color="text.secondary" sx={{ display: 'block' }}>
              Phone: {settings.phone}
            </Typography>
          )}
        </Box>

        <Divider sx={{ my: 2 }} />

        <Box sx={{ display: 'flex', justifyContent: 'space-between', mb: 2, fontSize: 13 }}>
          <div>
            <Typography variant="body2" sx={{ fontWeight: 600 }}>
              Invoice #: {sale.invoice_number}
            </Typography>
            <Typography variant="caption" color="text.secondary">
              Date: {sale.sale_date}
            </Typography>
          </div>
          <div style={{ textAlign: 'right' }}>
            <Typography variant="body2" sx={{ fontWeight: 600 }}>
              Customer: {sale.customer_name || 'Walk-in Customer'}
            </Typography>
            <Typography variant="caption" color="text.secondary">
              Payment: {sale.payment_status?.toUpperCase()}
            </Typography>
          </div>
        </Box>

        <TableContainer sx={{ my: 2 }}>
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>Item</TableCell>
                <TableCell align="center">Qty</TableCell>
                <TableCell align="right">Price</TableCell>
                <TableCell align="right">Total</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {sale.items?.map((it: any, idx: number) => (
                <TableRow key={idx}>
                  <TableCell>{it.product_name || it.name}</TableCell>
                  <TableCell align="center">{it.quantity}</TableCell>
                  <TableCell align="right">{formatCurrency(it.unit_price)}</TableCell>
                  <TableCell align="right">{formatCurrency(it.total_amount)}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </TableContainer>

        <Box sx={{ mt: 2, display: 'flex', flexDirection: 'column', gap: 0.5, alignItems: 'flex-end' }}>
          <Box sx={{ display: 'flex', gap: 4 }}>
            <Typography variant="body2" color="text.secondary">Subtotal:</Typography>
            <Typography variant="body2" sx={{ fontWeight: 600 }}>{formatCurrency(sale.subtotal)}</Typography>
          </Box>
          {Number(sale.discount_amount) > 0 && (
            <Box sx={{ display: 'flex', gap: 4 }}>
              <Typography variant="body2" color="text.secondary">Discount:</Typography>
              <Typography variant="body2" sx={{ color: '#ef4444' }}>-{formatCurrency(sale.discount_amount)}</Typography>
            </Box>
          )}
          <Box sx={{ display: 'flex', gap: 4 }}>
            <Typography variant="h6" sx={{ fontWeight: 800 }}>Total Due:</Typography>
            <Typography variant="h6" sx={{ fontWeight: 800, color: '#0f172a' }}>{formatCurrency(sale.total_amount)}</Typography>
          </Box>
          <Box sx={{ display: 'flex', gap: 4 }}>
            <Typography variant="body2" color="text.secondary">Amount Paid:</Typography>
            <Typography variant="body2" sx={{ fontWeight: 600, color: '#10b981' }}>{formatCurrency(sale.paid_amount)}</Typography>
          </Box>
          <Box sx={{ display: 'flex', gap: 4 }}>
            <Typography variant="body2" color="text.secondary">Remaining Balance:</Typography>
            <Typography variant="body2" sx={{ fontWeight: 700, color: '#d97706' }}>
              {formatCurrency(Math.max(0, Number(sale.total_amount) - Number(sale.paid_amount)))}
            </Typography>
          </Box>
        </Box>

        {settings?.invoice_footer && (
          <Box sx={{ mt: 4, textAlign: 'center', borderTop: '1px dashed #cbd5e1', pt: 2 }}>
            <Typography variant="caption" color="text.secondary">
              {settings.invoice_footer}
            </Typography>
          </Box>
        )}
      </DialogContent>

      <DialogActions sx={{ px: 3, py: 2 }}>
        <Button onClick={onClose} variant="outlined">
          Close
        </Button>
      </DialogActions>
    </Dialog>
  );
};

