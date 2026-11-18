import React, { useEffect, useRef, useState } from 'react';
import { Alert, Button, CircularProgress, Dialog, DialogActions, DialogContent, DialogTitle, Typography } from '@mui/material';
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

  useEffect(() => {
    if (!mode) return;
    let cancelled = false;
    let stream: any = null;
    const videoElement = videoRef.current;
    const start = async () => {
      setError('');
      setStarting(true);
      const Detector = (window as any).BarcodeDetector;
      if (!Detector || !window.navigator.mediaDevices?.getUserMedia || !videoElement) {
        setError(t('Camera code scanning is not supported in this browser. Use a hardware scanner or enter the code manually.'));
        setStarting(false);
        return;
      }
      try {
        const supported: string[] = await Detector.getSupportedFormats();
        const requested = mode === 'qr'
          ? ['qr_code']
          : ['code_128', 'code_39', 'ean_13', 'ean_8', 'upc_a', 'upc_e', 'itf', 'codabar'];
        const formats = requested.filter((format) => supported.includes(format));
        if (formats.length === 0) throw new Error(t('This browser cannot scan the selected code type.'));
        const detector = new Detector({ formats });
        stream = await window.navigator.mediaDevices.getUserMedia({ video: { facingMode: { ideal: 'environment' } }, audio: false });
        if (cancelled) {
          stream.getTracks().forEach((track: any) => track.stop());
          return;
        }
        videoElement.srcObject = stream;
        await videoElement.play();
        setStarting(false);
        while (!cancelled) {
          const codes = await detector.detect(videoElement);
          const value = codes.find((code: { rawValue?: string }) => code.rawValue)?.rawValue;
          if (value) {
            onDetected(value);
            return;
          }
          await new Promise((resolve) => setTimeout(resolve, 180));
        }
      } catch (scanError) {
        if (!cancelled) setError(scanError instanceof Error ? scanError.message : t('Could not start the camera scanner.'));
        setStarting(false);
      }
    };
    void start();
    return () => {
      cancelled = true;
      stream?.getTracks().forEach((track: any) => track.stop());
      videoElement.srcObject = null;
    };
  }, [mode, onDetected, t]);

  return <Dialog open={Boolean(mode)} onClose={onClose} maxWidth="sm" fullWidth>
    <DialogTitle>{t(mode === 'qr' ? 'Scan QR Code' : 'Scan Barcode')}</DialogTitle>
    <DialogContent>
      {error ? <Alert severity="warning">{error}</Alert> : <>
        <video ref={videoRef} playsInline muted style={{ width: '100%', minHeight: 240, background: '#0f172a', borderRadius: 12 }} />
        {starting && <Typography sx={{ display: 'flex', alignItems: 'center', gap: 1, mt: 1 }}><CircularProgress size={18} />{t('Starting camera…')}</Typography>}
        <Typography variant="body2" color="text.secondary" sx={{ mt: 1 }}>{t('Hold the code inside the camera frame. The camera stops after a code is detected or when you close this dialog.')}</Typography>
      </>}
    </DialogContent>
    <DialogActions><Button onClick={onClose}>{t('Cancel')}</Button></DialogActions>
  </Dialog>;
};
