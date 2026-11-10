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
import { PlatformAdminPage } from '@/modules/platform/PlatformAdminPage';
import { AdminLoginPage } from '@/modules/platform/AdminLoginPage';
import { AdminUsersPage } from '@/modules/platform/AdminUsersPage';

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
      { path: 'products', element: <ProductsPage /> },
      { path: 'categories', element: <CategoriesPage /> },
      { path: 'customers', element: <CustomersPage /> },
      { path: 'suppliers', element: <SuppliersPage /> },
      { path: 'sales', element: <SalesPage /> },
      { path: 'purchases', element: <PurchasesPage /> },
      { path: 'inventory', element: <InventoryPage /> },
      { path: 'payments', element: <PaymentsPage /> },
      { path: 'expenses', element: <ExpensesPage /> },
      { path: 'reports', element: <ReportsPage /> },
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
      { path: 'users', element: <AdminUsersPage /> },
    ],
  },

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
