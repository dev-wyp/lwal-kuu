import assert from 'node:assert/strict';
import {
  getPlanFeatureSection,
  getPlanLimitValue,
  getYearlySavingsPercent,
} from '../../src/modules/subscription/planPresentation.js';

const starterFeatures = [
  { id: 'cash', name: 'Cash Sales', category: 'finance' },
  { id: 'products', name: 'Product Management', category: 'core' },
];
const businessFeatures = [
  ...starterFeatures,
  { id: 'credit', name: 'Credit Sales', category: 'finance' },
];

const businessSection = getPlanFeatureSection(businessFeatures, starterFeatures);
assert.equal(businessSection.includesPreviousPlan, true);
assert.deepEqual(businessSection.features.map(({ id }) => id), ['credit']);

const customSection = getPlanFeatureSection(
  [{ id: 'analytics', name: 'Analytics', category: 'reports' }],
  starterFeatures,
);
assert.equal(customSection.includesPreviousPlan, false);
assert.deepEqual(customSection.features.map(({ id }) => id), ['analytics']);

const orderedSection = getPlanFeatureSection([
  { id: 'z', name: 'Zulu', category: 'reports' },
  { id: 'a', name: 'Alpha', category: 'core' },
], null);
assert.deepEqual(orderedSection.features.map(({ id }) => id), ['a', 'z']);

assert.equal(getPlanLimitValue(100, 50), 100);
assert.equal(getPlanLimitValue(undefined, 50), 50);
assert.equal(getPlanLimitValue(undefined, undefined), null);
assert.equal(getYearlySavingsPercent(15000, 150000), 17);
assert.equal(getYearlySavingsPercent(100, 1200), null);
assert.equal(getYearlySavingsPercent(0, 500), null);
assert.equal(getYearlySavingsPercent(Number.NaN, 100), null);
