import React, { useState } from 'react';
import {
  Box,
  Container,
  Typography,
  Button,
  Grid,
  Card,
  CardContent,
  Chip,
  ToggleButtonGroup,
  ToggleButton,
  List,
  ListItem,
  ListItemIcon,
  ListItemText,
} from '@mui/material';
import CheckCircleIcon from '@mui/icons-material/CheckCircle';
import { useNavigate } from 'react-router-dom';

export const PricingPage: React.FC = () => {
  const [billingCycle, setBillingCycle] = useState<'monthly' | 'yearly'>('monthly');
  const navigate = useNavigate();

  const handleCycleChange = (
    _event: React.MouseEvent<HTMLElement>,
    newCycle: 'monthly' | 'yearly' | null
  ) => {
    if (newCycle !== null) {
      setBillingCycle(newCycle);
    }
  };

  const plans = [
    {
      id: 'starter',
      name: 'Starter Plan',
      tagline: 'Ideal for small retail shops and single-location wholesale stalls.',
      monthlyPrice: '15,000',
      yearlyPrice: '150,000',
      popular: false,
      features: [
        'Up to 2 Staff Users',
        'Up to 200 Products',
        'Up to 300 Sales Invoices / mo',
        'POS & Sales Register',
        'Stock Movements Ledger',
        'Cash & Credit Invoicing',
        'Daily Sales Summary',
        'Standard Email Support',
      ],
    },
    {
      id: 'business',
      name: 'Business Plan',
      tagline: 'Best for growing wholesale shops with high volume credit sales.',
      monthlyPrice: '30,000',
      yearlyPrice: '300,000',
      popular: true,
      features: [
        'Up to 5 Staff Users',
        'Up to 1,000 Products',
        'Up to 1,500 Sales Invoices / mo',
        'Customer Credit & Ledger Statements',
        'Multi-Invoice Payment Allocations',
        'Weighted Average Costing & Gross Profit',
        'Supplier Orders & Receiving Workflow',
        'Inventory Adjustments & Low Stock Alerts',
        'Excel & PDF Report Exports',
      ],
    },
    {
      id: 'pro',
      name: 'Pro Plan',
      tagline: 'For large wholesale distributors managing multi-team operations.',
      monthlyPrice: '60,000',
      yearlyPrice: '600,000',
      popular: false,
      features: [
        'Up to 15 Staff Users',
        'Up to 5,000 Products',
        'Up to 10,000 Sales Invoices / mo',
        'All Business Plan Features Included',
        'Multiple Organization Switching',
        'Role-Based Granular Permissions',
        'Audit Log Trail & Reversals',
        'Priority Phone & Chat Support',
        'Custom Invoice Templates & Footer',
      ],
    },
  ];

  return (
    <Box sx={{ minHeight: '100vh', bgcolor: '#f8fafc', py: { xs: 6, md: 10 } }}>
      <Container maxWidth="lg">
        <Box sx={{ textAlign: 'center', mb: 6 }}>
          <Chip
            label="Simple, Predictable Pricing"
            sx={{ mb: 2, bgcolor: '#e0f2fe', color: '#0369a1', fontWeight: 600 }}
          />
          <Typography variant="h3" sx={{ fontWeight: 800, mb: 2 }}>
            Transparent Plans for Myanmar Businesses
          </Typography>
          <Typography variant="h6" color="text.secondary" sx={{ fontWeight: 400, maxWidth: 640, mx: 'auto' }}>
            All plans include a full-featured 14-day free trial. No credit card required. Cancel anytime.
          </Typography>

          {/* Monthly / Yearly Toggle */}
          <Box sx={{ mt: 4, display: 'flex', justifyContent: 'center' }}>
            <ToggleButtonGroup
              value={billingCycle}
              exclusive
              onChange={handleCycleChange}
              sx={{ bgcolor: '#ffffff', borderRadius: 3, p: 0.5, border: '1px solid #e2e8f0' }}
            >
              <ToggleButton value="monthly" sx={{ px: 3, py: 1, borderRadius: 2, fontWeight: 600 }}>
                Monthly Billing
              </ToggleButton>
              <ToggleButton value="yearly" sx={{ px: 3, py: 1, borderRadius: 2, fontWeight: 600 }}>
                Yearly Billing <Chip label="Save 16%" size="small" color="success" sx={{ ml: 1, height: 20, fontSize: 10, fontWeight: 700 }} />
              </ToggleButton>
            </ToggleButtonGroup>
          </Box>
        </Box>

        {/* Pricing Cards */}
        <Grid container spacing={4} alignItems="stretch">
          {plans.map((plan) => (
            <Grid item xs={12} md={4} key={plan.id}>
              <Card
                sx={{
                  height: '100%',
                  display: 'flex',
                  flexDirection: 'column',
                  borderRadius: 4,
                  p: 3,
                  position: 'relative',
                  border: plan.popular ? '2px solid #0284c7' : '1px solid #e2e8f0',
                  boxShadow: plan.popular ? '0 12px 30px -10px rgba(2, 132, 199, 0.2)' : 'none',
                }}
              >
                {plan.popular && (
                  <Chip
                    label="MOST POPULAR"
                    color="secondary"
                    size="small"
                    sx={{
                      position: 'absolute',
                      top: 16,
                      right: 16,
                      fontWeight: 700,
                      bgcolor: '#0284c7',
                      fontSize: 10,
                    }}
                  />
                )}

                <CardContent sx={{ flexGrow: 1, p: 0 }}>
                  <Typography variant="h5" sx={{ fontWeight: 700, mb: 1 }}>
                    {plan.name}
                  </Typography>
                  <Typography variant="body2" color="text.secondary" sx={{ minHeight: 40, mb: 3 }}>
                    {plan.tagline}
                  </Typography>

                  <Box sx={{ display: 'flex', alignItems: 'baseline', mb: 3 }}>
                    <Typography variant="h3" sx={{ fontWeight: 800 }}>
                      {billingCycle === 'yearly' ? plan.yearlyPrice : plan.monthlyPrice}
                    </Typography>
                    <Typography variant="subtitle1" color="text.secondary" sx={{ ml: 1, fontWeight: 600 }}>
                      MMK / {billingCycle === 'yearly' ? 'year' : 'month'}
                    </Typography>
                  </Box>

                  <Button
                    variant={plan.popular ? 'contained' : 'outlined'}
                    fullWidth
                    size="large"
                    onClick={() => navigate(`/register?plan=${plan.id}&cycle=${billingCycle}`)}
                    sx={{
                      py: 1.2,
                      borderRadius: 2,
                      fontWeight: 700,
                      bgcolor: plan.popular ? '#0284c7' : undefined,
                      '&:hover': { bgcolor: plan.popular ? '#0369a1' : undefined },
                      mb: 4,
                    }}
                  >
                    Start 14-Day Free Trial
                  </Button>

                  <Typography variant="subtitle2" sx={{ fontWeight: 700, mb: 1.5 }}>
                    Plan Highlights:
                  </Typography>
                  <List dense disablePadding>
                    {plan.features.map((feat, i) => (
                      <ListItem key={i} disableGutters sx={{ py: 0.6 }}>
                        <ListItemIcon sx={{ minWidth: 28 }}>
                          <CheckCircleIcon sx={{ fontSize: 18, color: '#10b981' }} />
                        </ListItemIcon>
                        <ListItemText
                          primary={feat}
                          primaryTypographyProps={{ fontSize: 13, fontWeight: 500 }}
                        />
                      </ListItem>
                    ))}
                  </List>
                </CardContent>
              </Card>
            </Grid>
          ))}
        </Grid>
      </Container>
    </Box>
  );
};
