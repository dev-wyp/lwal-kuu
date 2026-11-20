import React, { useEffect, useRef, useState } from 'react';
import { Alert, Button, CircularProgress, Dialog, DialogActions, DialogContent, DialogTitle, TextField, Typography } from '@mui/material';
import { useI18n } from '@/i18n/I18nContext';

export type ScanMode = 'barcode' | 'qr';

export const CodeScannerDialog: React.FC<{
  mode: ScanMode | null;
  onClose: () => void;
  onDetected: (value: string) => void;
}> = ({ mode, onClose, onDetected }) => {
  const { t } = useI18n();
  const videoRef = useRef<any>(null);
  const [error, setError] = useState('');
  const [starting, setStarting] = useState(false);
  const [manualCode, setManualCode] = useState('');

  useEffect(() => setManualCode(''), [mode]);

  useEffect(() => {
    if (!mode) return;
    let cancelled = false;
    let controls: { stop: () => void } | null = null;
    const videoElement = videoRef.current;
    const start = async () => {
      setError('');
      setStarting(true);
      if (!window.isSecureContext || !window.navigator.mediaDevices?.getUserMedia || !videoElement) {
        setError(t('Camera access requires a secure connection and browser permission. You can still enter a code or use a hardware scanner below.'));
        setStarting(false);
        return;
      }
      try {
        const [{ BrowserMultiFormatReader }, { BarcodeFormat }] = await Promise.all([
          import('@zxing/browser'),
          import('@zxing/library'),
        ]);
        const reader = new BrowserMultiFormatReader();
        reader.possibleFormats = mode === 'qr'
          ? [BarcodeFormat.QR_CODE]
          : [BarcodeFormat.CODE_128, BarcodeFormat.CODE_39, BarcodeFormat.EAN_13, BarcodeFormat.EAN_8,
            BarcodeFormat.UPC_A, BarcodeFormat.UPC_E, BarcodeFormat.ITF, BarcodeFormat.CODABAR];
        controls = await reader.decodeFromConstraints({
          video: { facingMode: { ideal: 'environment' } },
          audio: false,
        }, videoElement, (result) => {
          if (result && !cancelled) {
            controls?.stop();
            onDetected(result.getText());
          }
        });
        if (cancelled) controls.stop();
        else setStarting(false);
      } catch (scanError) {
        if (!cancelled) {
          const message = scanError instanceof Error ? scanError.message : t('Could not start the camera scanner.');
          setError(`${message} ${t('You can enter a code or use a hardware scanner below.')}`);
        }
        setStarting(false);
      }
    };
    void start();
    return () => {
      cancelled = true;
      controls?.stop();
    };
  }, [mode, onDetected, t]);

  return <Dialog open={Boolean(mode)} onClose={onClose} maxWidth="sm" fullWidth>
    <DialogTitle>{t(mode === 'qr' ? 'Scan QR Code' : 'Scan Barcode')}</DialogTitle>
    <DialogContent>
      {error && <Alert severity="warning" sx={{ mb: 2 }}>{error}</Alert>}
      {!error && <>
        <video ref={videoRef} playsInline muted style={{ width: '100%', minHeight: 240, background: '#0f172a', borderRadius: 12 }} />
        {starting && <Typography sx={{ display: 'flex', alignItems: 'center', gap: 1, mt: 1 }}><CircularProgress size={18} />{t('Starting camera…')}</Typography>}
        <Typography variant="body2" color="text.secondary" sx={{ mt: 1 }}>{t('Hold the code inside the camera frame. The camera stops after a code is detected or when you close this dialog.')}</Typography>
      </>}
      <TextField
        autoFocus
        fullWidth
        size="small"
        label={t(mode === 'qr' ? 'Enter or scan QR value' : 'Enter or scan barcode')}
        value={manualCode}
        onChange={(event) => setManualCode(event.target.value)}
        onKeyDown={(event) => {
          if (event.key === 'Enter' && manualCode.trim()) {
            event.preventDefault();
            onDetected(manualCode.trim());
            setManualCode('');
          }
        }}
        helperText={t('You can type the value or use a USB/Bluetooth scanner. Press Enter to use it.')}
        sx={{ mt: 2 }}
      />
      <Button
        fullWidth
        variant="outlined"
        disabled={!manualCode.trim()}
        onClick={() => { onDetected(manualCode.trim()); setManualCode(''); }}
        sx={{ mt: 1 }}
      >{t('Use this code')}</Button>
    </DialogContent>
    <DialogActions><Button onClick={onClose}>{t('Cancel')}</Button></DialogActions>
  </Dialog>;
};
