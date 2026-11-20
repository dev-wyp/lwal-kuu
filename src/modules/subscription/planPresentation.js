/**
 * @param {{ id: string, name: string, category?: string }[]} currentFeatures
 * @param {{ id: string, name: string, category?: string }[] | null} previousFeatures
 */
export const getPlanFeatureSection = (currentFeatures, previousFeatures) => {
  const currentIds = new Set(currentFeatures.map((feature) => feature.id));
  const previousIds = new Set((previousFeatures ?? []).map((feature) => feature.id));
  const includesPreviousPlan = previousIds.size > 0
    && [...previousIds].every((featureId) => currentIds.has(featureId));
  const sortedFeatures = [...currentFeatures].sort((left, right) =>
    (left.category ?? '').localeCompare(right.category ?? '') || left.name.localeCompare(right.name));

  return {
    includesPreviousPlan,
    features: includesPreviousPlan
      ? sortedFeatures.filter((feature) => !previousIds.has(feature.id))
      : sortedFeatures,
  };
};

/** @param {number | undefined} configuredValue @param {number | null | undefined} legacyValue */
export const getPlanLimitValue = (configuredValue, legacyValue) => configuredValue ?? legacyValue ?? null;

/** @param {number} monthlyPrice @param {number} yearlyPrice */
export const getYearlySavingsPercent = (monthlyPrice, yearlyPrice) => {
  const annualMonthlyPrice = monthlyPrice * 12;
  if (!Number.isFinite(annualMonthlyPrice) || !Number.isFinite(yearlyPrice) || annualMonthlyPrice <= 0) return null;
  const savings = Math.round((1 - yearlyPrice / annualMonthlyPrice) * 100);
  return savings > 0 ? savings : null;
};
