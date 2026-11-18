# Plan by plan feature matrix

This is the complete plan catalogue from migration `0019_plan_feature_system.sql`. Boolean feature rows are shown explicitly for Starter, Business, and Pro. Usage caps are listed separately. `✓` means enabled; `—` means the feature is not part of that plan.

## Core, finance, inventory, organization, reports, automation, export, security, and support

| Feature | Starter | Business | Pro |
| --- | :---: | :---: | :---: |
| Product Management | ✓ | ✓ | ✓ |
| Category Management | ✓ | ✓ | ✓ |
| Customer Management | ✓ | ✓ | ✓ |
| Supplier Management | ✓ | ✓ | ✓ |
| Purchase Management | ✓ | ✓ | ✓ |
| Sales Management | ✓ | ✓ | ✓ |
| Cash Sales | ✓ | ✓ | ✓ |
| Credit Sales | — | ✓ | ✓ |
| Partial Payments | — | ✓ | ✓ |
| Customer Ledger | — | ✓ | ✓ |
| Customer Debt Tracking | — | ✓ | ✓ |
| Supplier Payables | — | ✓ | ✓ |
| Payment & Receipt Management | — | ✓ | ✓ |
| Expense Management | — | ✓ | ✓ |
| Inventory Management | ✓ | ✓ | ✓ |
| Stock Adjustment | ✓ | ✓ | ✓ |
| Stock Transfer | — | ✓ | ✓ |
| Low Stock Alerts | — | ✓ | ✓ |
| Advanced Inventory | — | — | ✓ |
| Barcode Support | — | — | ✓ |
| QR Support | — | — | ✓ |
| Multi-Branch | — | ✓ | ✓ |
| Daily Sales Report | ✓ | ✓ | ✓ |
| Basic Product Report | ✓ | ✓ | ✓ |
| Monthly & Yearly Reports | — | ✓ | ✓ |
| Customer Statement PDF | — | — | ✓ |
| Supplier Statement PDF | — | — | ✓ |
| Sales Analytics | — | — | ✓ |
| Purchase Analytics | — | — | ✓ |
| Branch Reports | — | — | ✓ |
| Profit & Loss Report | — | — | ✓ |
| Cash Flow Report | — | — | ✓ |
| Profit Estimation | — | ✓ | ✓ |
| Automated Reports | — | — | ✓ |
| Debt Reminders | — | — | ✓ |
| Manual Data Export | ✓ | ✓ | ✓ |
| Excel Export | — | ✓ | ✓ |
| Basic User Permissions | — | ✓ | ✓ |
| Advanced Permissions | — | — | ✓ |
| Audit Logs | — | — | ✓ |
| Backup & Restore | — | — | ✓ |
| Priority Support | — | — | ✓ |

## Usage limits

| Limit | Starter | Business | Pro |
| --- | ---: | ---: | ---: |
| Active users | 1 | 3 | 10 |
| Active products | 100 | 2,000 | Unlimited |
| Active customers | 100 | Unlimited | Unlimited |
| Active suppliers | 20 | Unlimited | Unlimited |
| Branches | 1 | 2 | 5 |

## Audit and implementation

- The catalogue contains 42 boolean features and 5 numeric limits. Every one is represented for each standard plan above.
- Migration `0031_complete_plan_feature_matrix.sql` adds missing plan-feature rows for all existing plans. It applies the tier definitions to Starter, Business, and Pro; missing features on custom plans default to disabled. It does not overwrite already configured rows.
- Public pricing and the signed-in subscription page now show every boolean feature as included or not included. They no longer imply that a plan inherits another plan's features based on display order.
- The public pricing page reads the active feature catalogue separately from plan assignments, so a missing assignment is still shown as not included. It displays every configured limit, falls back to the plan's legacy limit columns, and labels a limit not configured when neither source has a value.
- Runtime access still comes from `check_organization_feature` and `get_organization_entitlements`; route, UI, database trigger, and RLS enforcement remain the applicable enforcement points for each feature.
- These rows define which tier includes each feature. Implementation status is tracked separately in `docs/plan-feature-implementation-audit.md`; that audit distinguishes complete workflows from partial ones and records whether the corresponding production migration has been applied.
- After adding a new active feature to `features`, assign it in every plan through the platform Plan & Feature Management page. Unassigned features are denied by default and will not appear in the public feature list until their plan matrix row exists.
