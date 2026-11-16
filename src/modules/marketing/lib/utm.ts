const STORAGE_KEY = 'shopflow_marketing_attribution';

export interface AttributionParams {
  utm_source: string | null;
  utm_medium: string | null;
  utm_campaign: string | null;
  utm_content: string | null;
}

export function captureAttributionFromSearch(search: string): void {
  const params = new URLSearchParams(search);
  const captured: AttributionParams = {
    utm_source: params.get('utm_source'),
    utm_medium: params.get('utm_medium'),
    utm_campaign: params.get('utm_campaign'),
    utm_content: params.get('utm_content') || params.get('content_id'),
  };
  if (!captured.utm_source && !captured.utm_campaign && !captured.utm_content) return;
  sessionStorage.setItem(STORAGE_KEY, JSON.stringify(captured));
}

export function readStoredAttribution(): AttributionParams | null {
  const raw = sessionStorage.getItem(STORAGE_KEY);
  if (!raw) return null;
  try {
    return JSON.parse(raw) as AttributionParams;
  } catch {
    return null;
  }
}

export function clearStoredAttribution(): void {
  sessionStorage.removeItem(STORAGE_KEY);
}
