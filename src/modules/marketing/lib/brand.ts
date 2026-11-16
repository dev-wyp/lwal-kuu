export const SHOPFLOW_BRAND_CONTEXT = `
Lwal Kuu is a Myanmar-focused wholesale and retail shop management SaaS.

Verified product capabilities (do not invent others):
- Fast POS and sales invoicing: cash sales, credit invoices, partial deposits, sequential invoice numbers, receipts.
- Immutable stock ledger with weighted-average costing and gross margin.
- Customer credit statements, outstanding balances, and lump-sum payment allocation across invoices.
- Supplier purchasing, goods receipts, and payables tracking.
- Expenses, inventory low-stock warnings, and real-time financial reports in MMK.
- Multi-tenant isolation with owner, admin, manager, and staff roles.
- Native MMK formatting, Asia/Yangon timezone, KBZPay and WavePay payment references.
- Self-service organization setup and a 14-day free trial. No credit card required to start.

Primary conversion goal: free trial registrations.
Secondary goal: brand awareness.
Audience: wholesale shop owners, retail shop owners, general merchandise stores, distribution businesses, and small business owners in Myanmar.

Brand voice: professional, friendly, trustworthy, practical, easy-to-understand Burmese. Avoid exaggerated claims, fake testimonials, invented statistics, and unstated features.
`.trim();

export const DEFAULT_CONTENT_PILLARS = [
  { key: 'business_problems', label: 'Business Problems', weight: 35 },
  { key: 'product_demonstrations', label: 'Product Demonstrations', weight: 30 },
  { key: 'educational', label: 'Educational Content', weight: 20 },
  { key: 'promotion_conversion', label: 'Product Promotion and Conversion', weight: 15 },
] as const;

export const FACEBOOK_CONTENT_TYPES = [
  'educational_post',
  'product_feature_post',
  'promotional_post',
  'carousel_concept',
  'reels_script',
] as const;

export const TIKTOK_CONTENT_TYPES = ['short_video_script'] as const;
