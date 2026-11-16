import React from 'react';
import {
  Box,
  Container,
  Typography,
  Button,
  Grid,
  Card,
  CardContent,
  Chip,
  Stack,
  AppBar,
  Toolbar,
} from '@mui/material';
import StorefrontIcon from '@mui/icons-material/Storefront';
import CheckCircleIcon from '@mui/icons-material/CheckCircle';
import ReceiptLongIcon from '@mui/icons-material/ReceiptLong';
import WarehouseIcon from '@mui/icons-material/Warehouse';
import AssessmentIcon from '@mui/icons-material/Assessment';
import SecurityIcon from '@mui/icons-material/Security';
import CurrencyExchangeIcon from '@mui/icons-material/CurrencyExchange';
import { useNavigate } from 'react-router-dom';
import { useAuth } from '@/context/AuthContext';
import { captureAttributionFromSearch } from '@/modules/marketing/lib/utm';
import { LanguageSwitcher } from '@/i18n/LanguageSwitcher';
import { useI18n } from '@/i18n/I18nContext';

export const LandingPage: React.FC = () => {
  const navigate = useNavigate();
  const { user } = useAuth();
  const { t } = useI18n();

  React.useEffect(() => {
    captureAttributionFromSearch(window.location.search);
  }, []);

  return (
    <Box sx={{ minHeight: '100vh', bgcolor: '#ffffff', color: '#0f172a' }}>
      {/* Navbar */}
      <AppBar position="sticky" sx={{ bgcolor: 'rgba(255,255,255,0.95)', backdropFilter: 'blur(8px)', boxShadow: 'none', borderBottom: '1px solid #e2e8f0' }}>
        <Container maxWidth="lg">
          <Toolbar disableGutters sx={{ justifyContent: 'space-between', height: 72 }}>
            <Box sx={{ display: 'flex', alignItems: 'center', gap: 1.5, cursor: 'pointer' }} onClick={() => navigate('/')}>
              <StorefrontIcon sx={{ color: '#0284c7', fontSize: 32 }} />
              <Typography variant="h5" sx={{ fontWeight: 800, color: '#0f172a', letterSpacing: '-0.02em' }}>
                Lwal Kuu
              </Typography>
            </Box>

            <Stack direction="row" spacing={2} alignItems="center">
              <LanguageSwitcher compact />
              <Button color="inherit" onClick={() => navigate('/pricing')} sx={{ fontWeight: 600 }}>
                {t('Pricing')}
              </Button>
              {user ? (
                <Button variant="contained" onClick={() => navigate('/app/dashboard')} sx={{ borderRadius: 2 }}>
                  {t('Go to Dashboard')}
                </Button>
              ) : (
                <>
                  <Button color="inherit" onClick={() => navigate('/login')} sx={{ fontWeight: 600 }}>
                    {t('Sign In')}
                  </Button>
                  <Button
                    variant="contained"
                    onClick={() => navigate('/register')}
                    sx={{ borderRadius: 2, bgcolor: '#0284c7', '&:hover': { bgcolor: '#0369a1' } }}
                  >
                    {t('Start Free Trial')}
                  </Button>
                </>
              )}
            </Stack>
          </Toolbar>
        </Container>
      </AppBar>

      {/* Hero Section */}
      <Box sx={{ py: { xs: 8, md: 12 }, textAlign: 'center', bgcolor: '#f8fafc', borderBottom: '1px solid #e2e8f0' }}>
        <Container maxWidth="md">
          <Chip
            label={t('Designed for Myanmar Wholesale & Retail Businesses')}
            color="secondary"
            sx={{ mb: 3, fontWeight: 600, px: 1, bgcolor: '#e0f2fe', color: '#0369a1' }}
          />
          <Typography
            variant="h2"
            component="h1"
            sx={{ fontWeight: 800, fontSize: { xs: '2.4rem', md: '3.6rem' }, lineHeight: 1.15, mb: 3 }}
          >
            {t("Manage Products, Sales & Credit Ledgers with Zero Friction.")}</Typography>
          <Typography variant="h6" color="text.secondary" sx={{ fontWeight: 400, mb: 4, lineHeight: 1.6 }}>
            Lwal Kuu is a modern multi-tenant cloud SaaS for wholesale distributors and retail shop owners.
            Complete with inventory ledgers, credit tracking, cash/partial payments, and daily business analytics in MMK.
          </Typography>

          <Stack direction={{ xs: 'column', sm: 'row' }} spacing={2} justifyContent="center">
            <Button
              variant="contained"
              size="large"
              onClick={() => navigate('/register')}
              sx={{ px: 4, py: 1.5, fontSize: '1.05rem', borderRadius: 2, bgcolor: '#0f172a' }}
            >
              {t("Start 14-Day Free Trial")}</Button>
            <Button
              variant="outlined"
              size="large"
              onClick={() => navigate('/pricing')}
              sx={{ px: 4, py: 1.5, fontSize: '1.05rem', borderRadius: 2, borderColor: '#cbd5e1' }}
            >
              {t("View Plans & Pricing")}</Button>
          </Stack>

          <Typography variant="caption" color="text.secondary" sx={{ display: 'block', mt: 2 }}>
            No credit card required &bull; Self-service setup in under 2 minutes
          </Typography>
        </Container>
      </Box>

      {/* Core Features */}
      <Container maxWidth="lg" sx={{ py: { xs: 8, md: 12 } }}>
        <Box sx={{ textAlign: 'center', mb: 8 }}>
          <Typography variant="overline" sx={{ fontWeight: 700, color: '#0284c7', letterSpacing: '0.1em' }}>
            {t("BUILT FOR SCALE")}</Typography>
          <Typography variant="h4" sx={{ fontWeight: 800, mt: 1 }}>
            {t("Everything Your Wholesale Shop Needs to Run Profitably")}</Typography>
        </Box>

        <Grid container spacing={4}>
          {[
            {
              icon: <ReceiptLongIcon sx={{ fontSize: 36, color: '#0284c7' }} />,
              title: 'Fast POS & Sales Invoicing',
              desc: 'Confirm cash sales, credit invoices, and partial upfront deposits. Automatic invoice number sequencing and receipt printing.',
            },
            {
              icon: <WarehouseIcon sx={{ fontSize: 36, color: '#10b981' }} />,
              title: 'Immutable Stock Ledger',
              desc: 'Inventory tracked by an append-only stock movement ledger. Weighted average costing automatically computes true gross margins.',
            },
            {
              icon: <CurrencyExchangeIcon sx={{ fontSize: 36, color: '#f59e0b' }} />,
              title: 'Customer Credit & Statement',
              desc: 'Track outstanding balances dynamically. Receive lump-sum payments and allocate across multiple open credit invoices.',
            },
            {
              icon: <AssessmentIcon sx={{ fontSize: 36, color: '#6366f1' }} />,
              title: 'Real-Time Financial Reports',
              desc: 'Daily sales, monthly revenue, COGS, gross profits, low-stock warnings, and customer receivable statements with Excel/PDF export.',
            },
            {
              icon: <SecurityIcon sx={{ fontSize: 36, color: '#ec4899' }} />,
              title: 'Enterprise Multi-Tenancy',
              desc: 'Strict tenant data isolation guaranteed by PostgreSQL Row Level Security (RLS). Role-based access for Owners, Managers, and Staff.',
            },
            {
              icon: <CheckCircleIcon sx={{ fontSize: 36, color: '#14b8a6' }} />,
              title: 'Myanmar Kyat & Timezone',
              desc: 'Native MMK denomination formatting, Asia/Yangon business timezones, and local payment references (KBZPay, WavePay).',
            },
          ].map((feature, idx) => (
            <Grid item xs={12} sm={6} md={4} key={idx}>
              <Card sx={{ height: '100%', p: 2, borderRadius: 3, border: '1px solid #e2e8f0', transition: 'all 0.2s', '&:hover': { transform: 'translateY(-4px)', boxShadow: '0 12px 24px -10px rgba(0,0,0,0.1)' } }}>
                <CardContent>
                  <Box sx={{ mb: 2 }}>{feature.icon}</Box>
                  <Typography variant="h6" sx={{ fontWeight: 700, mb: 1.5 }}>
                    {feature.title}
                  </Typography>
                  <Typography variant="body2" color="text.secondary" sx={{ lineHeight: 1.6 }}>
                    {feature.desc}
                  </Typography>
                </CardContent>
              </Card>
            </Grid>
          ))}
        </Grid>
      </Container>
    </Box>
  );
};

