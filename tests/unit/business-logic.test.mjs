// Unit tests for ShopFlow Core Business Calculations
// Validates: Weighted Average Costing, FIFO Payment Allocation, and Ledger Math

function calculateWeightedAverageCost(
  currentStock,
  currentAvgCost,
  receivedQty,
  newUnitCost
) {
  if (currentStock + receivedQty <= 0) return newUnitCost;
  if (currentStock <= 0) return newUnitCost;
  const totalValue = (currentStock * currentAvgCost) + (receivedQty * newUnitCost);
  return totalValue / (currentStock + receivedQty);
}

function calculateGrossProfit(
  salePrice,
  unitCost,
  quantity,
  discount = 0
) {
  const revenue = (salePrice * quantity) - discount;
  const cogs = unitCost * quantity;
  const profit = revenue - cogs;
  const marginPct = revenue > 0 ? (profit / revenue) * 100 : 0;
  return { revenue, cogs, profit, marginPct: Math.round(marginPct * 100) / 100 };
}

function allocatePaymentFIFO(invoices, paymentAmount) {
  let remaining = paymentAmount;
  const allocations = [];

  for (const inv of invoices) {
    if (remaining <= 0) break;
    const toAlloc = Math.min(remaining, inv.due);
    allocations.push({ id: inv.id, allocated: toAlloc });
    remaining -= toAlloc;
  }

  return { allocations, remainingPayment: remaining };
}

function assert(condition, message) {
  if (!condition) {
    throw new Error(`Assertion Failed: ${message}`);
  }
  console.log(`[PASS] ${message}`);
}

console.log('--- Running ShopFlow Business Logic Tests ---');

// Test 1: Initial Purchase Weighted Average Cost
const cost1 = calculateWeightedAverageCost(0, 0, 10, 80000);
assert(cost1 === 80000, 'Initial purchase cost sets average cost to 80,000 MMK');

// Test 2: Second Shipment Weighted Average Cost
// 10 units @ 80,000 + 10 units @ 90,000 = 20 units @ 85,000
const cost2 = calculateWeightedAverageCost(10, 80000, 10, 90000);
assert(cost2 === 85000, 'Second purchase updates weighted average cost to 85,000 MMK');

// Test 3: Third Shipment with Unequal Quantities
// 20 units @ 85,000 (1,700,000) + 30 units @ 100,000 (3,000,000) = 50 units (4,700,000 / 50 = 94,000)
const cost3 = calculateWeightedAverageCost(20, 85000, 30, 100000);
assert(cost3 === 94000, 'Unequal quantities weighted average computes correctly (94,000 MMK)');

// Test 4: Gross Profit & Margin Calculation
// Sale: 4 units @ 95,000 MMK (Revenue: 380,000), Cost: 85,000 MMK (COGS: 340,000) -> Profit: 40,000 MMK
const profitResult = calculateGrossProfit(95000, 85000, 4);
assert(profitResult.revenue === 380000, 'Revenue is 380,000 MMK');
assert(profitResult.cogs === 340000, 'COGS is 340,000 MMK');
assert(profitResult.profit === 40000, 'Gross profit is 40,000 MMK');
assert(profitResult.marginPct === 10.53, 'Gross margin percentage is 10.53%');

// Test 5: FIFO Multi-Invoice Payment Allocation
const openInvoices = [
  { id: 'INV-001', due: 150000 },
  { id: 'INV-002', due: 200000 },
  { id: 'INV-003', due: 300000 },
];
// Customer pays 250,000: covers INV-001 in full (150,000), partially covers INV-002 (100,000), leaves 0 on INV-003
const allocResult = allocatePaymentFIFO(openInvoices, 250000);
assert(allocResult.allocations.length === 2, 'Allocates across 2 invoices');
assert(allocResult.allocations[0].id === 'INV-001' && allocResult.allocations[0].allocated === 150000, 'INV-001 is fully paid (150,000 MMK)');
assert(allocResult.allocations[1].id === 'INV-002' && allocResult.allocations[1].allocated === 100000, 'INV-002 is partially paid (100,000 MMK)');
assert(allocResult.remainingPayment === 0, 'No unallocated payment remainder');

console.log('--- All Business Logic Calculations PASSED ---');

