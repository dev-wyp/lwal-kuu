import { createBrowserRouter, Navigate } from 'react-router-dom';
import { AppLayout } from '@/components/layout/AppLayout';
import { AuthLayout } from '@/components/layout/AuthLayout';
import { AdminLayout } from '@/components/layout/AdminLayout';
import { LandingPage } from '@/modules/public/LandingPage';
import { PricingPage } from '@/modules/public/PricingPage';
import { LoginPage } from '@/modules/auth/LoginPage';
import { RegisterPage } from '@/modules/auth/RegisterPage';
import { ForgotPasswordPage } from '@/modules/auth/ForgotPasswordPage';
import { OnboardingPage } from '@/modules/onboarding/OnboardingPage';
import { DashboardPage } from '@/modules/dashboard/DashboardPage';
import { ProductsPage } from '@/modules/products/ProductsPage';
import { CategoriesPage } from '@/modules/products/CategoriesPage';
import { CustomersPage } from '@/modules/customers/CustomersPage';
import { SuppliersPage } from '@/modules/suppliers/SuppliersPage';
import { SalesPage } from '@/modules/sales/SalesPage';
import { PurchasesPage } from '@/modules/purchases/PurchasesPage';
import { InventoryPage } from '@/modules/inventory/InventoryPage';
import { PaymentsPage } from '@/modules/payments/PaymentsPage';
import { ExpensesPage } from '@/modules/expenses/ExpensesPage';
import { ReportsPage } from '@/modules/reports/ReportsPage';
import { SettingsPage } from '@/modules/settings/SettingsPage';
import { SubscriptionPage } from '@/modules/subscription/SubscriptionPage';
import { FeatureGate } from '@/modules/subscription/FeatureGate';
import { PlatformAdminPage } from '@/modules/platform/PlatformAdminPage';
import { AdminLoginPage } from '@/modules/platform/AdminLoginPage';
import { AdminUsersPage } from '@/modules/platform/AdminUsersPage';
import { PlanManagementPage } from '@/modules/platform/PlanManagementPage';
import { MarketingLayout } from '@/modules/marketing/components/MarketingLayout';
import { OverviewPage } from '@/modules/marketing/pages/OverviewPage';
import { CalendarPage } from '@/modules/marketing/pages/CalendarPage';
import { ContentListPage } from '@/modules/marketing/pages/ContentListPage';
import { ContentNewPage } from '@/modules/marketing/pages/ContentNewPage';
import { ApprovalsPage } from '@/modules/marketing/pages/ApprovalsPage';
import { CampaignsPage } from '@/modules/marketing/pages/CampaignsPage';
import { SocialAccountsPage } from '@/modules/marketing/pages/SocialAccountsPage';
import { LeadsPage } from '@/modules/marketing/pages/LeadsPage';
import { AnalyticsPage } from '@/modules/marketing/pages/AnalyticsPage';
import { ReportsPage as MarketingReportsPage } from '@/modules/marketing/pages/ReportsPage';
import { AiSettingsPage } from '@/modules/marketing/pages/AiSettingsPage';
import { MarketingSettingsPage } from '@/modules/marketing/pages/MarketingSettingsPage';

export const router = createBrowserRouter([
  // Public Landing & Pricing
  {
    path: '/',
    element: <LandingPage />,
  },
  {
    path: '/pricing',
    element: <PricingPage />,
  },

  // 1. Tenant Shop Auth Routes
  {
    element: <AuthLayout />,
    children: [
      { path: '/login', element: <LoginPage /> },
      { path: '/register', element: <RegisterPage /> },
      { path: '/forgot-password', element: <ForgotPasswordPage /> },
    ],
  },

  // 2. Dedicated Platform Super-Admin Login
  {
    path: '/admin/login',
    element: <AdminLoginPage />,
  },
  {
    path: '/platform/login',
    element: <Navigate to="/admin/login" replace />,
  },

  // Self-Service Onboarding Wizard for Shop Owners
  {
    path: '/onboarding',
    element: <OnboardingPage />,
  },

  // 3. Protected Tenant SaaS Application (Wholesale Shop Operations)
  {
    path: '/app',
    element: <AppLayout />,
    children: [
      { index: true, element: <Navigate to="/app/dashboard" replace /> },
      { path: 'dashboard', element: <DashboardPage /> },
      { path: 'products', element: <FeatureGate feature="product_management"><ProductsPage /></FeatureGate> },
      { path: 'categories', element: <FeatureGate feature="category_management"><CategoriesPage /></FeatureGate> },
      { path: 'customers', element: <FeatureGate feature="customer_management"><CustomersPage /></FeatureGate> },
      { path: 'suppliers', element: <FeatureGate feature="supplier_management"><SuppliersPage /></FeatureGate> },
      { path: 'sales', element: <FeatureGate feature="sales_management"><SalesPage /></FeatureGate> },
      { path: 'purchases', element: <FeatureGate feature="purchase_management"><PurchasesPage /></FeatureGate> },
      { path: 'inventory', element: <FeatureGate feature="inventory_management"><InventoryPage /></FeatureGate> },
      { path: 'payments', element: <FeatureGate feature="payment_receipt_mgmt"><PaymentsPage /></FeatureGate> },
      { path: 'expenses', element: <FeatureGate feature="expense_management"><ExpensesPage /></FeatureGate> },
      { path: 'reports', element: <FeatureGate feature="daily_sales_report"><ReportsPage /></FeatureGate> },
      { path: 'settings', element: <SettingsPage /> },
      { path: 'subscription', element: <SubscriptionPage /> },
    ],
  },

  // 4. Dedicated Platform Super-Admin Portal (Managing all shops & organizations)
  {
    path: '/admin',
    element: <AdminLayout />,
    children: [
      { index: true, element: <Navigate to="/admin/organizations" replace /> },
      { path: 'organizations', element: <PlatformAdminPage /> },
      { path: 'subscriptions', element: <PlatformAdminPage /> },
      { path: 'audit-logs', element: <PlatformAdminPage /> },
      { path: 'analytics', element: <PlatformAdminPage /> },
      { path: 'automations', element: <PlatformAdminPage /> },
      { path: 'users', element: <AdminUsersPage /> },
      { path: 'plans', element: <PlanManagementPage /> },
      {
        path: 'marketing',
        element: <MarketingLayout />,
        children: [
          { index: true, element: <OverviewPage /> },
          { path: 'calendar', element: <CalendarPage /> },
          { path: 'content', element: <ContentListPage /> },
          { path: 'content/new', element: <ContentNewPage /> },
          { path: 'approvals', element: <ApprovalsPage /> },
          { path: 'campaigns', element: <CampaignsPage /> },
          { path: 'social-accounts', element: <SocialAccountsPage /> },
          { path: 'leads', element: <LeadsPage /> },
          { path: 'analytics', element: <AnalyticsPage /> },
          { path: 'reports', element: <MarketingReportsPage /> },
          { path: 'ai-settings', element: <AiSettingsPage /> },
          { path: 'settings', element: <MarketingSettingsPage /> },
        ],
      },
    ],
  },

  // Legacy marketing links now resolve inside the protected platform console.
  { path: '/marketing/*', element: <Navigate to="/admin/marketing" replace /> },

  // Backwards Compatibility for /platform routes
  {
    path: '/platform',
    element: <Navigate to="/admin/organizations" replace />,
  },
  {
    path: '/platform/organizations',
    element: <Navigate to="/admin/organizations" replace />,
  },
  {
    path: '/platform/subscriptions',
    element: <Navigate to="/admin/subscriptions" replace />,
  },
  {
    path: '/platform/audit-logs',
    element: <Navigate to="/admin/audit-logs" replace />,
  },
  {
    path: '/platform/usage',
    element: <Navigate to="/admin/analytics" replace />,
  },

  // Catch-all
  {
    path: '*',
    element: <Navigate to="/" replace />,
  },
]);
