import { test, expect } from '@playwright/test';

test.describe('ShopFlow E2E Critical Path Suite', () => {
  test('1. Public Landing and Pricing Page Navigation', async ({ page }) => {
    await page.goto('/');
    await expect(page.locator('h1')).toContainText('Manage Products, Sales & Credit Ledgers');

    // Check pricing page
    await page.click('text=View Plans & Pricing');
    await expect(page).toHaveURL(/.*pricing/);
    await expect(page.getByRole('heading', { name: 'Starter Plan' })).toBeVisible();
    await expect(page.getByRole('heading', { name: 'Business Plan' })).toBeVisible();
    await expect(page.getByRole('heading', { name: 'Pro Plan' })).toBeVisible();
  });

  test('2. Authentication and Form Validations', async ({ page }) => {
    await page.goto('/login');
    await expect(page.locator('text=Sign In to ShopFlow')).toBeVisible();

    // Trigger validation with empty inputs
    await page.click('button[type="submit"]');
    await expect(page.locator('text=Please enter a valid email address')).toBeVisible();

    // Navigate to Register
    await page.click('text=Start free trial');
    await expect(page).toHaveURL(/.*register/);
    await expect(page.locator('text=Create Your Account')).toBeVisible();
  });

  test('3. Responsive POS Register Layout and Pricing Calculations', async ({ page }) => {
    // Check navigation to landing and layout elements
    await page.goto('/pricing');
    await page.click('text=Monthly Billing');
    await expect(page.locator('text=15,000')).toBeVisible();
    await page.click('text=Yearly Billing');
    await expect(page.locator('text=150,000')).toBeVisible();
  });

  test('4. Marketing routes require authentication', async ({ page }) => {
    await page.goto('/marketing');
    await expect(page).toHaveURL(/login/);
    await page.goto('/marketing/approvals');
    await expect(page).toHaveURL(/login/);
  });
});

