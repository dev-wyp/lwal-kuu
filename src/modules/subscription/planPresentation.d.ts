export interface PlanFeatureSelection {
  id: string;
  name: string;
  category?: string;
}

export function getPlanFeatureSection(
  currentFeatures: PlanFeatureSelection[],
  previousFeatures: PlanFeatureSelection[] | null,
): { includesPreviousPlan: boolean; features: PlanFeatureSelection[] };

export function getPlanLimitValue(
  configuredValue: number | undefined,
  legacyValue: number | null | undefined,
): number | null;

export function getYearlySavingsPercent(monthlyPrice: number, yearlyPrice: number): number | null;
