import { test, expect } from '@playwright/test';

test.describe('Lwal Kuu E2E Critical Path Suite', () => {
  test('1. Public Landing and Pricing Page Navigation', async ({ page }) => {
    await page.goto('/');
    await expect(page.locator('h1')).toContainText('Manage Products, Sales & Credit Ledgers');

    // Check pricing page
    await page.click('text=View Plans & Pricing');
    await expect(page).toHaveURL(/.*pricing/);
    await expect(page.getByRole('heading', { name: 'Starter', exact: true })).toBeVisible();
    await expect(page.getByRole('heading', { name: 'Business', exact: true })).toBeVisible();
    await expect(page.getByRole('heading', { name: 'Pro', exact: true })).toBeVisible();
  });

  test('2. Authentication and Form Validations', async ({ page }) => {
    await page.goto('/login');
    await expect(page.locator('text=Sign In to Lwal Kuu')).toBeVisible();

    // Trigger validation with empty inputs
    await page.click('button[type="submit"]');
    await expect(page.locator('text=Please enter a valid email address')).toBeVisible();

    // Navigate to Register
    await page.click('text=Start free trial');
    await expect(page).toHaveURL(/.*register/);
    await expect(page.locator('text=Create Your Account')).toBeVisible();
  });

  test('3. Public Pricing Billing Cycle Calculations', async ({ page }) => {
    await page.goto('/pricing');
    await page.getByRole('button', { name: 'Monthly', exact: true }).click();
    await expect(page.locator('text=15,000')).toBeVisible();
    await page.getByRole('button', { name: 'Yearly', exact: true }).click();
    await expect(page.locator('text=150,000')).toBeVisible();
  });

  test('4. Marketing routes require authentication', async ({ page }) => {
    await page.goto('/marketing');
    await expect(page).toHaveURL(/login/);
    await page.goto('/marketing/approvals');
    await expect(page).toHaveURL(/login/);
  });

  test('5. Public pages fit phone, tablet, and desktop widths', async ({ page }) => {
    for (const viewport of [
      { width: 320, height: 740 },
      { width: 390, height: 844 },
      { width: 768, height: 1024 },
      { width: 1440, height: 900 },
    ]) {
      await page.setViewportSize(viewport);
      for (const route of ['/', '/pricing', '/login']) {
        await page.goto(route);
        await expect(page.locator('body')).toBeVisible();
        const widths = await page.evaluate(() => ({
          viewport: document.documentElement.clientWidth,
          document: document.documentElement.scrollWidth,
          body: document.body.scrollWidth,
        }));
        expect(widths.document, `${route} overflows at ${viewport.width}px`).toBeLessThanOrEqual(widths.viewport + 1);
        expect(widths.body, `${route} body overflows at ${viewport.width}px`).toBeLessThanOrEqual(widths.viewport + 1);
      }
    }
  });
});

