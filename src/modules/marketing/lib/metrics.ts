export type MetricSource = 'platform' | 'estimated' | 'unavailable';

export interface MetricValue {
  value: number | null;
  source: MetricSource;
  label?: string;
}

export function safeDivide(numerator: number, denominator: number): number | null {
  if (!Number.isFinite(numerator) || !Number.isFinite(denominator) || denominator === 0) {
    return null;
  }
  return numerator / denominator;
}

export function engagementRate(engagements: number, reach: number): number | null {
  const ratio = safeDivide(engagements, reach);
  if (ratio === null) return null;
  return ratio * 100;
}

export function costPerLead(advertisingSpend: number, attributedLeads: number): number | null {
  return safeDivide(advertisingSpend, attributedLeads);
}

export function costPerTrial(advertisingSpend: number, attributedTrials: number): number | null {
  return safeDivide(advertisingSpend, attributedTrials);
}

export function conversionRate(converted: number, total: number): number | null {
  const ratio = safeDivide(converted, total);
  if (ratio === null) return null;
  return ratio * 100;
}

export function budgetUtilization(spent: number, limit: number): number | null {
  const ratio = safeDivide(spent, limit);
  if (ratio === null) return null;
  return ratio * 100;
}

export function remainingBudget(limit: number, spent: number): number {
  return Math.max(0, limit - spent);
}

export function wouldExceedBudget(limit: number, spent: number, additional: number): boolean {
  return spent + additional > limit;
}

export function formatPercent(value: number | null, digits = 1): string {
  if (value === null || Number.isNaN(value)) return 'Unavailable';
  return `${value.toFixed(digits)}%`;
}

export function formatMetricNumber(value: number | null): string {
  if (value === null || Number.isNaN(value)) return '—';
  return value.toLocaleString();
}

export function metricSourceLabel(source: MetricSource): string {
  if (source === 'platform') return 'Platform data';
  if (source === 'estimated') return 'Estimated';
  return 'Unavailable';
}

export function combineMetricSource(sources: MetricSource[]): MetricSource {
  if (sources.length === 0) return 'unavailable';
  if (sources.every((s) => s === 'platform')) return 'platform';
  if (sources.every((s) => s === 'unavailable')) return 'unavailable';
  return 'estimated';
}
