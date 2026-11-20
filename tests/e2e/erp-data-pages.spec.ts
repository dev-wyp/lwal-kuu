import { expect, test } from '@playwright/test';

const userId = '11111111-1111-4111-8111-111111111111';
const orgId = '22222222-2222-4222-8222-222222222222';

const user = {
  id: userId,
  aud: 'authenticated',
  role: 'authenticated',
  email: 'browser-test@example.invalid',
  app_metadata: { provider: 'email', providers: ['email'] },
  user_metadata: {},
  created_at: '2026-01-01T00:00:00.000Z',
  updated_at: '2026-01-01T00:00:00.000Z',
};

const organization = {
  id: orgId,
  name: 'Browser Test Shop',
  slug: 'browser-test-shop',
  tax_id: null,
  is_active: true,
};

const entitlements = [
  'product_management', 'purchase_management', 'payment_receipt_mgmt', 'customer_ledger',
  'customer_debt_tracking', 'supplier_payables', 'customer_management', 'supplier_management',
].map((feature_key) => ({
  feature_key,
  feature_name: feature_key,
  feature_type: 'boolean',
  category: 'test',
  is_allowed: true,
  reason: 'browser test fixture',
  current_usage: 0,
  limit_value: null,
  remaining_usage: null,
  subscription_status: 'active',
}));

const fixtures: Record<string, unknown[]> = {
  profiles: [{ id: userId, full_name: 'Browser Tester', is_platform_admin: false }],
  organization_members: [{ id: 'member-1', organization_id: orgId, user_id: userId, role: 'owner', is_active: true }],
  organizations: [organization],
  organization_settings: [{ organization_id: orgId, currency_code: 'MMK', currency_symbol: 'Ks', timezone: 'Asia/Rangoon' }],
  product_categories: [],
  units: [{ id: 'unit-1', name: 'Bag', code: 'bag', organization_id: orgId }],
  products: [{
    id: 'product-1', organization_id: orgId, name: 'Test Rice', sku: 'RICE-001', barcode: '1234567890',
    qr_code: 'rice-test-qr', sale_price: 1000, purchase_price: 800, average_cost: 800,
    low_stock_threshold: 5, is_active: true, product_categories: null, units: { name: 'Bag', code: 'bag' },
  }],
  product_stock_balances: [{ product_id: 'product-1', organization_id: orgId, stock_on_hand: 12, stock_value: 9600, is_low_stock: false }],
  sales: [{
    id: 'sale-1', organization_id: orgId, invoice_number: 'INV-BROWSER-1', sale_date: '2026-11-20',
    status: 'confirmed', total_amount: 12000, total_cost: 9000, paid_amount: 12000, payment_status: 'paid',
    customers: { name: 'Test Customer' },
  }],
  branches: [{ id: 'branch-1', organization_id: orgId, name: 'Main Branch', is_default: true, is_active: true }],
  suppliers: [{ id: 'supplier-1', organization_id: orgId, name: 'Test Supplier', is_active: true }],
  purchases: [{
    id: 'purchase-1', organization_id: orgId, supplier_id: 'supplier-1', purchase_number: 'PO-BROWSER-1',
    purchase_date: '2026-11-20', status: 'ordered', total_amount: 8000, paid_amount: 0,
    suppliers: { name: 'Test Supplier' },
  }],
  customer_balances_summary: [{
    customer_id: 'customer-1', organization_id: orgId, customer_name: 'Test Customer', current_balance: 5000,
  }],
  payments: [{
    id: 'payment-1', organization_id: orgId, customer_id: 'customer-1', payment_number: 'PAY-BROWSER-1',
    payment_date: '2026-11-20', payment_method: 'cash', amount: 1000, allocated_amount: 1000,
    reference_number: null, status: 'posted', customers: { name: 'Test Customer' },
  }],
  supplier_balances_summary: [{ supplier_id: 'supplier-1', organization_id: orgId, current_payable: 8000 }],
};

test('authenticated ERP data pages render successful API responses', async ({ page }) => {
  let failStockRequest = false;
  await page.addInitScript(({ testUser, testOrgId }) => {
    const now = Math.floor(Date.now() / 1000);
    const base64 = (value: unknown) => btoa(JSON.stringify(value)).replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
    const accessToken = `header.${base64({ sub: testUser.id, role: 'authenticated', exp: now + 3600 })}.signature`;
    localStorage.setItem('sb-lfajonwbfweflkymuvmx-auth-token', JSON.stringify({
      access_token: accessToken,
      refresh_token: 'browser-test-refresh-token',
      token_type: 'bearer',
      expires_in: 3600,
      expires_at: now + 3600,
      user: testUser,
    }));
    localStorage.setItem('shopflow_active_org_id', testOrgId);
  }, { testUser: user, testOrgId: orgId });

  await page.route('**/auth/v1/**', async (route) => {
    const path = new URL(route.request().url()).pathname;
    if (path.endsWith('/user')) return route.fulfill({ json: user });
    return route.fulfill({ json: { user, access_token: 'browser-test-token', refresh_token: 'browser-test-refresh-token', expires_in: 3600, token_type: 'bearer' } });
  });

  await page.route('**/rest/v1/**', async (route) => {
    const url = new URL(route.request().url());
    const resource = url.pathname.split('/').pop() ?? '';
    if (url.pathname.endsWith('/rpc/get_organization_entitlements')) return route.fulfill({ json: entitlements });
    if (resource === 'plans') return route.fulfill({ json: [] });
    const select = url.searchParams.get('select') ?? '';
    const ambiguousRelationship =
      (resource === 'sales' && select.includes('customers(')) ||
      (resource === 'sales' && select.includes('sale_items(')) ||
      (resource === 'products' && select.includes('units(')) ||
      (resource === 'purchases' && select.includes('suppliers(')) ||
      (resource === 'payments' && select.includes('customers('));
    if (ambiguousRelationship) {
      return route.fulfill({
        status: 400,
        contentType: 'application/json',
        body: JSON.stringify({ code: 'PGRST201', message: 'Ambiguous relationship; specify a foreign key hint.' }),
      });
    }
    if (resource === 'product_stock_balances' && failStockRequest) {
      return route.fulfill({ status: 403, contentType: 'application/json', body: JSON.stringify({ message: 'permission denied' }) });
    }
    return route.fulfill({ json: fixtures[resource] ?? [] });
  });

  const cases = [
    { path: '/app/products', heading: 'Product Catalog', data: 'Test Rice' },
    { path: '/app/dashboard', heading: 'Business Overview', data: 'INV-BROWSER-1' },
    { path: '/app/purchases', heading: 'Purchase Orders & Receiving', data: 'PO-BROWSER-1' },
    { path: '/app/payments', heading: 'Customer Payments & Allocations', data: 'PAY-BROWSER-1' },
  ];

  for (const item of cases) {
    await page.goto(item.path);
    await expect(page.getByRole('heading', { name: item.heading })).toBeVisible();
    await expect(page.getByText(item.data, { exact: false }).first()).toBeVisible();
    await expect(page.getByText(/could not be loaded/i)).toHaveCount(0);
  }

  failStockRequest = true;
  await page.reload();
  await page.goto('/app/dashboard');
  await expect(page.getByRole('heading', { name: 'Business Overview' })).toBeVisible();
  await expect(page.getByText('12,000 Ks').first()).toBeVisible();
  await expect(page.getByRole('alert')).toContainText('stock balances');
  await expect(page.getByText('INV-BROWSER-1')).toBeVisible();
});
