export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[];

export type UserRole = 'owner' | 'admin' | 'manager' | 'staff';
export type SaleStatus = 'draft' | 'confirmed' | 'voided' | 'reversed';
export type PurchaseStatus = 'draft' | 'ordered' | 'received' | 'voided';
export type PaymentStatus = 'unpaid' | 'partial' | 'paid';
export type PaymentMethod = 'cash' | 'bank_transfer' | 'mobile_money' | 'kbz_pay' | 'wave_pay' | 'other';
export type MovementType =
  | 'opening'
  | 'purchase_in'
  | 'sales_out'
  | 'customer_return'
  | 'supplier_return'
  | 'adjustment_in'
  | 'adjustment_out'
  | 'sale_reversal';
export type SubscriptionStatus = 'trialing' | 'active' | 'past_due' | 'expired' | 'canceled';
export type BillingCycle = 'monthly' | 'yearly';

export interface Database {
  public: {
    Tables: {
      profiles: {
        Row: {
          id: string;
          full_name: string;
          phone_number: string | null;
          avatar_url: string | null;
          is_platform_admin: boolean;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          id: string;
          full_name: string;
          phone_number?: string | null;
          avatar_url?: string | null;
          is_platform_admin?: boolean;
          created_at?: string;
          updated_at?: string;
        };
        Update: {
          full_name?: string;
          phone_number?: string | null;
          avatar_url?: string | null;
          is_platform_admin?: boolean;
          updated_at?: string;
        };
      };
      organizations: {
        Row: {
          id: string;
          name: string;
          slug: string;
          tax_id: string | null;
          is_active: boolean;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          id?: string;
          name: string;
          slug: string;
          tax_id?: string | null;
          is_active?: boolean;
          created_at?: string;
          updated_at?: string;
        };
        Update: {
          name?: string;
          slug?: string;
          tax_id?: string | null;
          is_active?: boolean;
          updated_at?: string;
        };
      };
      organization_members: {
        Row: {
          id: string;
          organization_id: string;
          user_id: string;
          role: UserRole;
          is_active: boolean;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          id?: string;
          organization_id: string;
          user_id: string;
          role: UserRole;
          is_active?: boolean;
          created_at?: string;
          updated_at?: string;
        };
        Update: {
          role?: UserRole;
          is_active?: boolean;
          updated_at?: string;
        };
      };
      organization_settings: {
        Row: {
          organization_id: string;
          currency_code: string;
          currency_symbol: string;
          timezone: string;
          phone: string | null;
          email: string | null;
          address: string | null;
          invoice_footer: string | null;
          low_stock_threshold_default: number;
          costing_method: string;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          organization_id: string;
          currency_code?: string;
          currency_symbol?: string;
          timezone?: string;
          phone?: string | null;
          email?: string | null;
          address?: string | null;
          invoice_footer?: string | null;
          low_stock_threshold_default?: number;
          costing_method?: string;
          created_at?: string;
          updated_at?: string;
        };
        Update: {
          currency_code?: string;
          currency_symbol?: string;
          timezone?: string;
          phone?: string | null;
          email?: string | null;
          address?: string | null;
          invoice_footer?: string | null;
          low_stock_threshold_default?: number;
          costing_method?: string;
          updated_at?: string;
        };
      };
      audit_logs: {
        Row: {
          id: string;
          organization_id: string;
          user_id: string | null;
          action: string;
          entity_type: string;
          entity_id: string;
          payload: Json;
          ip_address: string | null;
          created_at: string;
        };
        Insert: {
          id?: string;
          organization_id: string;
          user_id?: string | null;
          action: string;
          entity_type: string;
          entity_id: string;
          payload?: Json;
          ip_address?: string | null;
          created_at?: string;
        };
      };
      product_categories: {
        Row: {
          id: string;
          organization_id: string;
          name: string;
          parent_id: string | null;
          is_active: boolean;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          id?: string;
          organization_id: string;
          name: string;
          parent_id?: string | null;
          is_active?: boolean;
          created_at?: string;
          updated_at?: string;
        };
        Update: {
          name?: string;
          parent_id?: string | null;
          is_active?: boolean;
          updated_at?: string;
        };
      };
      units: {
        Row: {
          id: string;
          organization_id: string;
          code: string;
          name: string;
          precision: number;
          is_active: boolean;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          id?: string;
          organization_id: string;
          code: string;
          name: string;
          precision?: number;
          is_active?: boolean;
          created_at?: string;
          updated_at?: string;
        };
        Update: {
          code?: string;
          name?: string;
          precision?: number;
          is_active?: boolean;
          updated_at?: string;
        };
      };
      products: {
        Row: {
          id: string;
          organization_id: string;
          sku: string;
          barcode: string | null;
          name: string;
          description: string | null;
          category_id: string | null;
          unit_id: string;
          purchase_price: number;
          sale_price: number;
          average_cost: number;
          low_stock_threshold: number;
          is_active: boolean;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          id?: string;
          organization_id: string;
          sku: string;
          barcode?: string | null;
          name: string;
          description?: string | null;
          category_id?: string | null;
          unit_id: string;
          purchase_price?: number;
          sale_price?: number;
          average_cost?: number;
          low_stock_threshold?: number;
          is_active?: boolean;
          created_at?: string;
          updated_at?: string;
        };
        Update: {
          sku?: string;
          barcode?: string | null;
          name?: string;
          description?: string | null;
          category_id?: string | null;
          unit_id?: string;
          purchase_price?: number;
          sale_price?: number;
          average_cost?: number;
          low_stock_threshold?: number;
          is_active?: boolean;
          updated_at?: string;
        };
      };
      customers: {
        Row: {
          id: string;
          organization_id: string;
          name: string;
          phone: string | null;
          email: string | null;
          address: string | null;
          credit_limit: number;
          opening_balance: number;
          is_active: boolean;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          id?: string;
          organization_id: string;
          name: string;
          phone?: string | null;
          email?: string | null;
          address?: string | null;
          credit_limit?: number;
          opening_balance?: number;
          is_active?: boolean;
          created_at?: string;
          updated_at?: string;
        };
        Update: {
          name?: string;
          phone?: string | null;
          email?: string | null;
          address?: string | null;
          credit_limit?: number;
          opening_balance?: number;
          is_active?: boolean;
          updated_at?: string;
        };
      };
      suppliers: {
        Row: {
          id: string;
          organization_id: string;
          name: string;
          contact_person: string | null;
          phone: string | null;
          email: string | null;
          address: string | null;
          opening_balance: number;
          is_active: boolean;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          id?: string;
          organization_id: string;
          name: string;
          contact_person?: string | null;
          phone?: string | null;
          email?: string | null;
          address?: string | null;
          opening_balance?: number;
          is_active?: boolean;
          created_at?: string;
          updated_at?: string;
        };
        Update: {
          name?: string;
          contact_person?: string | null;
          phone?: string | null;
          email?: string | null;
          address?: string | null;
          opening_balance?: number;
          is_active?: boolean;
          updated_at?: string;
        };
      };
      purchases: {
        Row: {
          id: string;
          organization_id: string;
          supplier_id: string;
          purchase_number: string;
          purchase_date: string;
          status: PurchaseStatus;
          subtotal: number;
          tax_amount: number;
          discount_amount: number;
          total_amount: number;
          paid_amount: number;
          notes: string | null;
          created_by: string | null;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          id?: string;
          organization_id: string;
          supplier_id: string;
          purchase_number: string;
          purchase_date?: string;
          status?: PurchaseStatus;
          subtotal?: number;
          tax_amount?: number;
          discount_amount?: number;
          total_amount?: number;
          paid_amount?: number;
          notes?: string | null;
          created_by?: string | null;
          created_at?: string;
          updated_at?: string;
        };
        Update: {
          supplier_id?: string;
          purchase_date?: string;
          status?: PurchaseStatus;
          subtotal?: number;
          tax_amount?: number;
          discount_amount?: number;
          total_amount?: number;
          paid_amount?: number;
          notes?: string | null;
          updated_at?: string;
        };
      };
      purchase_items: {
        Row: {
          id: string;
          organization_id: string;
          purchase_id: string;
          product_id: string;
          quantity: number;
          unit_cost: number;
          total_cost: number;
          received_quantity: number;
          created_at: string;
        };
        Insert: {
          id?: string;
          organization_id: string;
          purchase_id: string;
          product_id: string;
          quantity: number;
          unit_cost: number;
          total_cost: number;
          received_quantity?: number;
          created_at?: string;
        };
      };
      supplier_payments: {
        Row: {
          id: string;
          organization_id: string;
          supplier_id: string;
          purchase_id: string | null;
          payment_number: string;
          payment_date: string;
          amount: number;
          payment_method: PaymentMethod;
          reference_number: string | null;
          notes: string | null;
          created_by: string | null;
          created_at: string;
        };
        Insert: {
          id?: string;
          organization_id: string;
          supplier_id: string;
          purchase_id?: string | null;
          payment_number: string;
          payment_date?: string;
          amount: number;
          payment_method: PaymentMethod;
          reference_number?: string | null;
          notes?: string | null;
          created_by?: string | null;
          created_at?: string;
        };
      };
      sales: {
        Row: {
          id: string;
          organization_id: string;
          customer_id: string | null;
          invoice_number: string;
          sale_date: string;
          status: SaleStatus;
          subtotal: number;
          discount_amount: number;
          tax_amount: number;
          total_amount: number;
          total_cost: number;
          paid_amount: number;
          payment_status: PaymentStatus;
          due_date: string | null;
          notes: string | null;
          idempotency_key: string | null;
          voided_at: string | null;
          void_reason: string | null;
          created_by: string | null;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          id?: string;
          organization_id: string;
          customer_id?: string | null;
          invoice_number: string;
          sale_date?: string;
          status?: SaleStatus;
          subtotal?: number;
          discount_amount?: number;
          tax_amount?: number;
          total_amount?: number;
          total_cost?: number;
          paid_amount?: number;
          payment_status?: PaymentStatus;
          due_date?: string | null;
          notes?: string | null;
          idempotency_key?: string | null;
          created_by?: string | null;
          created_at?: string;
          updated_at?: string;
        };
        Update: {
          customer_id?: string | null;
          sale_date?: string;
          status?: SaleStatus;
          subtotal?: number;
          discount_amount?: number;
          tax_amount?: number;
          total_amount?: number;
          total_cost?: number;
          paid_amount?: number;
          payment_status?: PaymentStatus;
          due_date?: string | null;
          notes?: string | null;
          voided_at?: string | null;
          void_reason?: string | null;
          updated_at?: string;
        };
      };
      sale_items: {
        Row: {
          id: string;
          organization_id: string;
          sale_id: string;
          product_id: string;
          quantity: number;
          unit_price: number;
          unit_cost: number;
          discount_amount: number;
          total_amount: number;
          created_at: string;
        };
        Insert: {
          id?: string;
          organization_id: string;
          sale_id: string;
          product_id: string;
          quantity: number;
          unit_price: number;
          unit_cost?: number;
          discount_amount?: number;
          total_amount: number;
          created_at?: string;
        };
      };
      payments: {
        Row: {
          id: string;
          organization_id: string;
          customer_id: string;
          payment_number: string;
          payment_date: string;
          amount: number;
          allocated_amount: number;
          payment_method: PaymentMethod;
          reference_number: string | null;
          notes: string | null;
          status: 'posted' | 'voided';
          idempotency_key: string | null;
          created_by: string | null;
          created_at: string;
        };
        Insert: {
          id?: string;
          organization_id: string;
          customer_id: string;
          payment_number: string;
          payment_date?: string;
          amount: number;
          allocated_amount?: number;
          payment_method: PaymentMethod;
          reference_number?: string | null;
          notes?: string | null;
          status?: 'posted' | 'voided';
          idempotency_key?: string | null;
          created_by?: string | null;
          created_at?: string;
        };
      };
      payment_allocations: {
        Row: {
          id: string;
          organization_id: string;
          payment_id: string;
          sale_id: string;
          allocated_amount: number;
          created_at: string;
        };
        Insert: {
          id?: string;
          organization_id: string;
          payment_id: string;
          sale_id: string;
          allocated_amount: number;
          created_at?: string;
        };
      };
      stock_movements: {
        Row: {
          id: string;
          organization_id: string;
          product_id: string;
          movement_type: MovementType;
          quantity: number;
          unit_cost: number;
          reference_type: 'purchase' | 'sale' | 'adjustment' | 'opening';
          reference_id: string;
          notes: string | null;
          created_by: string | null;
          created_at: string;
        };
        Insert: {
          id?: string;
          organization_id: string;
          product_id: string;
          movement_type: MovementType;
          quantity: number;
          unit_cost?: number;
          reference_type: 'purchase' | 'sale' | 'adjustment' | 'opening';
          reference_id: string;
          notes?: string | null;
          created_by?: string | null;
          created_at?: string;
        };
      };
      stock_adjustments: {
        Row: {
          id: string;
          organization_id: string;
          adjustment_number: string;
          adjustment_date: string;
          product_id: string;
          reason: 'damaged' | 'expired' | 'count_correction' | 'loss' | 'other';
          quantity_delta: number;
          unit_cost: number;
          notes: string | null;
          created_by: string | null;
          created_at: string;
        };
        Insert: {
          id?: string;
          organization_id: string;
          adjustment_number: string;
          adjustment_date?: string;
          product_id: string;
          reason: 'damaged' | 'expired' | 'count_correction' | 'loss' | 'other';
          quantity_delta: number;
          unit_cost?: number;
          notes?: string | null;
          created_by?: string | null;
          created_at?: string;
        };
      };
      expense_categories: {
        Row: {
          id: string;
          organization_id: string;
          name: string;
          is_active: boolean;
          created_at: string;
        };
        Insert: {
          id?: string;
          organization_id: string;
          name: string;
          is_active?: boolean;
          created_at?: string;
        };
      };
      expenses: {
        Row: {
          id: string;
          organization_id: string;
          category_id: string;
          expense_date: string;
          amount: number;
          payment_method: PaymentMethod;
          title: string;
          notes: string | null;
          receipt_url: string | null;
          created_by: string | null;
          created_at: string;
        };
        Insert: {
          id?: string;
          organization_id: string;
          category_id: string;
          expense_date?: string;
          amount: number;
          payment_method: PaymentMethod;
          title: string;
          notes?: string | null;
          receipt_url?: string | null;
          created_by?: string | null;
          created_at?: string;
        };
      };
      plans: {
        Row: {
          id: string;
          name: string;
          monthly_price_mmk: number;
          yearly_price_mmk: number;
          trial_days: number;
          max_users: number;
          max_products: number;
          max_monthly_sales: number;
          features: Json;
          is_active: boolean;
        };
      };
      subscriptions: {
        Row: {
          id: string;
          organization_id: string;
          plan_id: string;
          status: SubscriptionStatus;
          billing_cycle: BillingCycle;
          current_period_start: string;
          current_period_end: string;
          trial_ends_at: string | null;
          cancel_at_period_end: boolean;
          created_at: string;
          updated_at: string;
        };
      };
      subscription_events: {
        Row: {
          id: string;
          subscription_id: string;
          organization_id: string;
          event_type: string;
          amount: number | null;
          payment_method: string | null;
          payment_reference: string | null;
          admin_notes: string | null;
          created_at: string;
        };
      };
      usage_limits: {
        Row: {
          id: string;
          organization_id: string;
          metric: 'user_count' | 'product_count' | 'monthly_sales_count';
          period_key: string;
          current_value: number;
          limit_value: number;
          updated_at: string;
        };
      };
    };
    Views: {
      product_stock_balances: {
        Row: {
          product_id: string;
          organization_id: string;
          sku: string;
          name: string;
          unit_id: string;
          unit_code: string;
          unit_name: string;
          sale_price: number;
          average_cost: number;
          low_stock_threshold: number;
          stock_on_hand: number;
          stock_value: number;
          is_low_stock: boolean;
        };
      };
      customer_balances_summary: {
        Row: {
          customer_id: string;
          organization_id: string;
          customer_name: string;
          phone: string | null;
          credit_limit: number;
          opening_balance: number;
          total_confirmed_sales: number;
          total_payments_received: number;
          current_balance: number;
        };
      };
      supplier_balances_summary: {
        Row: {
          supplier_id: string;
          organization_id: string;
          supplier_name: string;
          phone: string | null;
          opening_balance: number;
          total_received_purchases: number;
          total_payments_made: number;
          current_payable: number;
        };
      };
      daily_sales_performance: {
        Row: {
          organization_id: string;
          sale_date: string;
          total_invoices: number;
          total_revenue: number;
          total_cogs: number;
          gross_profit: number;
          gross_margin_percentage: number;
        };
      };
    };
  };
}

