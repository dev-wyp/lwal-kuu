import React, { useState, useMemo } from 'react';
import {
  Box,
  Typography,
  Button,
  Paper,
  Tabs,
  Tab,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
  Chip,
  Dialog,
  DialogTitle,
  DialogContent,
  DialogActions,
  TextField,
  CircularProgress,
  Alert,
  Grid,
  Card,
  CardContent,
  InputAdornment,
  MenuItem,
  Select,
  FormControl,
  InputLabel,
  IconButton,
  Tooltip,
} from '@mui/material';
import AdminPanelSettingsIcon from '@mui/icons-material/AdminPanelSettings';
import CheckCircleIcon from '@mui/icons-material/CheckCircle';
import CancelIcon from '@mui/icons-material/Cancel';
import BusinessIcon from '@mui/icons-material/Business';
import PeopleIcon from '@mui/icons-material/People';
import BlockIcon from '@mui/icons-material/Block';
import SearchIcon from '@mui/icons-material/Search';
import RefreshIcon from '@mui/icons-material/Refresh';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/lib/supabase';
import { useAuth } from '@/context/AuthContext';
import { useNotification } from '@/context/NotificationContext';
import { useLocation, useNavigate } from 'react-router-dom';

export const PlatformAdminPage: React.FC = () => {
  const { profile } = useAuth();
  const { showSuccess, showError } = useNotification();
  const queryClient = useQueryClient();
  const location = useLocation();
  const navigate = useNavigate();

  // Tab mapping with route URLs
  const tabRoutes = [
    '/platform/organizations',
    '/platform/subscriptions',
    '/platform/audit-logs',
    '/platform/usage',
  ];

  const currentTabIndex = useMemo(() => {
    const idx = tabRoutes.findIndex((r) => location.pathname.startsWith(r));
    return idx >= 0 ? idx : 0;
  }, [location.pathname]);

  const [searchQuery, setSearchQuery] = useState('');
  const [statusFilter, setStatusFilter] = useState<'all' | 'active' | 'suspended'>('all');
  const [reviewEvent, setReviewEvent] = useState<any>(null);
  const [adminNotes, setAdminNotes] = useState('');
  const [processing, setProcessing] = useState(false);

  // Status toggle confirmation dialog state
  const [statusDialogOrg, setStatusDialogOrg] = useState<{ id: string; name: string; is_active: boolean } | null>(null);

  const isPlatformAdmin = Boolean(profile?.is_platform_admin);

  // 1. Fetch Platform KPI Metrics via RPC
  const { data: metrics, isLoading: metricsLoading, refetch: refetchMetrics } = useQuery({
    queryKey: ['platform_metrics'],
    queryFn: async () => {
      const { data, error } = await supabase.rpc('admin_get_platform_metrics');
      if (error) {
        console.warn('Fallback to direct metric counting:', error);
        return null;
      }
      return data as {
        total_organizations: number;
        active_organizations: number;
        suspended_organizations: number;
        total_users: number;
        total_sales_count: number;
      };
    },
    enabled: isPlatformAdmin,
  });

  // 2. Fetch All Organizations
  const { data: allOrgs = [], isLoading: orgsLoading, refetch: refetchOrgs } = useQuery({
    queryKey: ['platform_all_orgs'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('organizations')
        .select(`
          *,
          subscriptions(
            status, plan_id, current_period_end
          )
        `)
        .order('created_at', { ascending: false });

      if (error) throw error;
      return data || [];
    },
    enabled: isPlatformAdmin,
  });

  // 3. Fetch Pending Subscription Events
  const { data: subEvents = [], isLoading: eventsLoading, refetch: refetchEvents } = useQuery({
    queryKey: ['platform_sub_events'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('subscription_events')
        .select(`
          *,
          organizations(name)
        `)
        .order('created_at', { ascending: false });

      if (error) throw error;
      return data || [];
    },
    enabled: isPlatformAdmin,
  });

  // 4. Fetch Platform Audit Logs
  const { data: auditLogs = [], isLoading: auditLoading, refetch: refetchAudit } = useQuery({
    queryKey: ['platform_audit_logs'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('audit_logs')
        .select(`
          *,
          organizations(name),
          profiles(full_name)
        `)
        .order('created_at', { ascending: false })
        .limit(100);

      if (error) throw error;
      return data || [];
    },
    enabled: isPlatformAdmin,
  });

  // Guard: platform admin only
  if (!isPlatformAdmin) {
    return (
      <Box sx={{ p: 4, textAlign: 'center' }}>
        <Alert severity="error" sx={{ maxWidth: 500, mx: 'auto', borderRadius: 2 }}>
          Access Denied. You do not have Platform Super-Admin privileges.
        </Alert>
      </Box>
    );
  }

  // Filter organizations by search text and status
  const filteredOrgs = allOrgs.filter((org: any) => {
    const matchesSearch =
      org.name?.toLowerCase().includes(searchQuery.toLowerCase()) ||
      org.slug?.toLowerCase().includes(searchQuery.toLowerCase());
    const matchesStatus =
      statusFilter === 'all'
        ? true
        : statusFilter === 'active'
        ? org.is_active
        : !org.is_active;
    return matchesSearch && matchesStatus;
  });

  const handleTabChange = (_event: React.SyntheticEvent, newIndex: number) => {
    navigate(tabRoutes[newIndex]);
  };

  const handleToggleOrgStatus = async () => {
    if (!statusDialogOrg) return;

    try {
      setProcessing(true);
      const newStatus = !statusDialogOrg.is_active;

      const { error } = await supabase.rpc('admin_toggle_organization_status', {
        p_org_id: statusDialogOrg.id,
        p_is_active: newStatus,
      });

      if (error) throw error;

      showSuccess(`Tenant "${statusDialogOrg.name}" has been ${newStatus ? 'activated' : 'suspended'}.`);
      queryClient.invalidateQueries({ queryKey: ['platform_all_orgs'] });
      queryClient.invalidateQueries({ queryKey: ['platform_metrics'] });
      queryClient.invalidateQueries({ queryKey: ['platform_audit_logs'] });
      setStatusDialogOrg(null);
    } catch (err: any) {
      showError(err.message || 'Failed to update organization status');
    } finally {
      setProcessing(false);
    }
  };

  const handleVerifyPayment = async (approve: boolean) => {
    if (!reviewEvent) return;

    try {
      setProcessing(true);
      const { error } = await supabase.rpc('verify_subscription_payment', {
        p_sub_id: reviewEvent.subscription_id,
        p_event_id: reviewEvent.id,
        p_approve: approve,
        p_admin_notes: adminNotes || null,
      });

      if (error) throw error;

      showSuccess(`Payment ${approve ? 'approved and subscription activated' : 'rejected'}`);
      queryClient.invalidateQueries({ queryKey: ['platform_all_orgs'] });
      queryClient.invalidateQueries({ queryKey: ['platform_sub_events'] });
      setReviewEvent(null);
      setAdminNotes('');
    } catch (err: any) {
      showError(err.message || 'Verification failed');
    } finally {
      setProcessing(false);
    }
  };

  const handleRefreshAll = () => {
    refetchMetrics();
    refetchOrgs();
    refetchEvents();
    refetchAudit();
  };

  // Metric values
  const totalOrgsCount = metrics?.total_organizations ?? allOrgs.length;
  const activeOrgsCount = metrics?.active_organizations ?? allOrgs.filter((o: any) => o.is_active).length;
  const suspendedOrgsCount = metrics?.suspended_organizations ?? allOrgs.filter((o: any) => !o.is_active).length;
  const totalUsersCount = metrics?.total_users ?? 0;

  return (
    <Box>
      {/* Header */}
      <Box sx={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', mb: 3 }}>
        <Box sx={{ display: 'flex', alignItems: 'center', gap: 1.5 }}>
          <AdminPanelSettingsIcon sx={{ fontSize: 40, color: '#dc2626' }} />
          <div>
            <Typography variant="h4" sx={{ fontWeight: 800 }}>
              Platform Super-Admin
            </Typography>
            <Typography variant="body2" color="text.secondary">
              Cross-tenant governance, organization controls, subscription billing, and platform audit trail.
            </Typography>
          </div>
        </Box>
        <Tooltip title="Refresh Platform Data">
          <IconButton onClick={handleRefreshAll} sx={{ border: '1px solid #e2e8f0', borderRadius: 2 }}>
            <RefreshIcon />
          </IconButton>
        </Tooltip>
      </Box>

      {/* KPI Status Cards */}
      <Grid container spacing={2} sx={{ mb: 3 }}>
        <Grid item xs={12} sm={6} md={3}>
          <Card elevation={0} sx={{ border: '1px solid #e2e8f0', borderRadius: 2.5, bgcolor: '#ffffff' }}>
            <CardContent sx={{ py: 2, '&:last-child': { pb: 2 } }}>
              <Box sx={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
                <div>
                  <Typography variant="caption" color="text.secondary" sx={{ fontWeight: 700, textTransform: 'uppercase' }}>
                    Total Tenants
                  </Typography>
                  <Typography variant="h5" sx={{ fontWeight: 800, mt: 0.5 }}>
                    {metricsLoading ? <CircularProgress size={20} /> : totalOrgsCount}
                  </Typography>
                </div>
                <BusinessIcon sx={{ color: '#0284c7', fontSize: 32 }} />
              </Box>
            </CardContent>
          </Card>
        </Grid>

        <Grid item xs={12} sm={6} md={3}>
          <Card elevation={0} sx={{ border: '1px solid #e2e8f0', borderRadius: 2.5, bgcolor: '#ffffff' }}>
            <CardContent sx={{ py: 2, '&:last-child': { pb: 2 } }}>
              <Box sx={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
                <div>
                  <Typography variant="caption" color="text.secondary" sx={{ fontWeight: 700, textTransform: 'uppercase' }}>
                    Active Tenants
                  </Typography>
                  <Typography variant="h5" sx={{ fontWeight: 800, mt: 0.5, color: '#16a34a' }}>
                    {metricsLoading ? <CircularProgress size={20} /> : activeOrgsCount}
                  </Typography>
                </div>
                <CheckCircleIcon sx={{ color: '#16a34a', fontSize: 32 }} />
              </Box>
            </CardContent>
          </Card>
        </Grid>

        <Grid item xs={12} sm={6} md={3}>
          <Card elevation={0} sx={{ border: '1px solid #e2e8f0', borderRadius: 2.5, bgcolor: '#ffffff' }}>
            <CardContent sx={{ py: 2, '&:last-child': { pb: 2 } }}>
              <Box sx={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
                <div>
                  <Typography variant="caption" color="text.secondary" sx={{ fontWeight: 700, textTransform: 'uppercase' }}>
                    Suspended Tenants
                  </Typography>
                  <Typography variant="h5" sx={{ fontWeight: 800, mt: 0.5, color: suspendedOrgsCount > 0 ? '#dc2626' : '#64748b' }}>
                    {metricsLoading ? <CircularProgress size={20} /> : suspendedOrgsCount}
                  </Typography>
                </div>
                <BlockIcon sx={{ color: suspendedOrgsCount > 0 ? '#dc2626' : '#94a3b8', fontSize: 32 }} />
              </Box>
            </CardContent>
          </Card>
        </Grid>

        <Grid item xs={12} sm={6} md={3}>
          <Card elevation={0} sx={{ border: '1px solid #e2e8f0', borderRadius: 2.5, bgcolor: '#ffffff' }}>
            <CardContent sx={{ py: 2, '&:last-child': { pb: 2 } }}>
              <Box sx={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
                <div>
                  <Typography variant="caption" color="text.secondary" sx={{ fontWeight: 700, textTransform: 'uppercase' }}>
                    Registered Users
                  </Typography>
                  <Typography variant="h5" sx={{ fontWeight: 800, mt: 0.5 }}>
                    {metricsLoading ? <CircularProgress size={20} /> : totalUsersCount}
                  </Typography>
                </div>
                <PeopleIcon sx={{ color: '#6366f1', fontSize: 32 }} />
              </Box>
            </CardContent>
          </Card>
        </Grid>
      </Grid>

      {/* Main Tabs Container */}
      <Paper elevation={0} sx={{ borderRadius: 3, border: '1px solid #e2e8f0', bgcolor: '#ffffff', overflow: 'hidden' }}>
        <Tabs
          value={currentTabIndex}
          onChange={handleTabChange}
          sx={{ px: 2, borderBottom: '1px solid #e2e8f0', bgcolor: '#f8fafc' }}
        >
          <Tab label={`Tenant Organizations (${allOrgs.length})`} sx={{ fontWeight: 600 }} />
          <Tab label={`Subscriptions & Approvals (${subEvents.length})`} sx={{ fontWeight: 600 }} />
          <Tab label="Platform Audit Logs" sx={{ fontWeight: 600 }} />
          <Tab label="Usage Analytics" sx={{ fontWeight: 600 }} />
        </Tabs>

        {/* Tab 0: Tenant Organizations */}
        {currentTabIndex === 0 && (
          <Box sx={{ p: 2.5 }}>
            {/* Search and Filters */}
            <Box sx={{ display: 'flex', gap: 2, mb: 2.5, flexWrap: 'wrap' }}>
              <TextField
                size="small"
                placeholder="Search by organization name or slug..."
                value={searchQuery}
                onChange={(e) => setSearchQuery(e.target.value)}
                sx={{ minWidth: 300, flexGrow: 1 }}
                InputProps={{
                  startAdornment: (
                    <InputAdornment position="start">
                      <SearchIcon fontSize="small" color="action" />
                    </InputAdornment>
                  ),
                }}
              />

              <FormControl size="small" sx={{ minWidth: 150 }}>
                <InputLabel>Status</InputLabel>
                <Select
                  value={statusFilter}
                  label="Status"
                  onChange={(e) => setStatusFilter(e.target.value as any)}
                >
                  <MenuItem value="all">All Statuses</MenuItem>
                  <MenuItem value="active">Active Only</MenuItem>
                  <MenuItem value="suspended">Suspended Only</MenuItem>
                </Select>
              </FormControl>
            </Box>

            <TableContainer sx={{ border: '1px solid #e2e8f0', borderRadius: 2 }}>
              <Table>
                <TableHead sx={{ bgcolor: '#f8fafc' }}>
                  <TableRow>
                    <TableCell sx={{ fontWeight: 700 }}>Organization Name</TableCell>
                    <TableCell sx={{ fontWeight: 700 }}>Slug</TableCell>
                    <TableCell sx={{ fontWeight: 700 }}>Created Date</TableCell>
                    <TableCell sx={{ fontWeight: 700 }}>Plan</TableCell>
                    <TableCell sx={{ fontWeight: 700 }}>Billing / Expiry</TableCell>
                    <TableCell align="center" sx={{ fontWeight: 700 }}>Tenant Status</TableCell>
                    <TableCell align="center" sx={{ fontWeight: 700 }}>Admin Actions</TableCell>
                  </TableRow>
                </TableHead>
                <TableBody>
                  {orgsLoading ? (
                    <TableRow>
                      <TableCell colSpan={7} align="center" sx={{ py: 6 }}>
                        <CircularProgress size={32} />
                      </TableCell>
                    </TableRow>
                  ) : filteredOrgs.length === 0 ? (
                    <TableRow>
                      <TableCell colSpan={7} align="center" sx={{ py: 6, color: 'text.secondary' }}>
                        No organizations found matching your search.
                      </TableCell>
                    </TableRow>
                  ) : (
                    filteredOrgs.map((org: any) => {
                      const sub = org.subscriptions?.[0] || org.subscriptions;
                      return (
                        <TableRow key={org.id} hover>
                          <TableCell sx={{ fontWeight: 700, color: '#0f172a' }}>{org.name}</TableCell>
                          <TableCell sx={{ color: 'text.secondary', fontFamily: 'monospace', fontSize: 13 }}>
                            {org.slug}
                          </TableCell>
                          <TableCell>{new Date(org.created_at).toLocaleDateString()}</TableCell>
                          <TableCell>
                            <Chip
                              label={sub?.plan_id?.toUpperCase() || 'STARTER'}
                              size="small"
                              sx={{ height: 22, fontSize: 11, fontWeight: 700 }}
                            />
                          </TableCell>
                          <TableCell>
                            {sub?.current_period_end ? new Date(sub.current_period_end).toLocaleDateString() : 'Trial'}
                          </TableCell>
                          <TableCell align="center">
                            <Chip
                              label={org.is_active ? 'ACTIVE' : 'SUSPENDED'}
                              size="small"
                              color={org.is_active ? 'success' : 'error'}
                              sx={{ height: 22, fontSize: 11, fontWeight: 700 }}
                            />
                          </TableCell>
                          <TableCell align="center">
                            {org.is_active ? (
                              <Button
                                size="small"
                                variant="outlined"
                                color="error"
                                startIcon={<BlockIcon fontSize="small" />}
                                onClick={() => setStatusDialogOrg({ id: org.id, name: org.name, is_active: true })}
                                sx={{ borderRadius: 1.5, fontSize: 11, py: 0.3 }}
                              >
                                Suspend
                              </Button>
                            ) : (
                              <Button
                                size="small"
                                variant="contained"
                                color="success"
                                startIcon={<CheckCircleIcon fontSize="small" />}
                                onClick={() => setStatusDialogOrg({ id: org.id, name: org.name, is_active: false })}
                                sx={{ borderRadius: 1.5, fontSize: 11, py: 0.3 }}
                              >
                                Activate
                              </Button>
                            )}
                          </TableCell>
                        </TableRow>
                      );
                    })
                  )}
                </TableBody>
              </Table>
            </TableContainer>
          </Box>
        )}

        {/* Tab 1: Subscriptions & Approvals */}
        {currentTabIndex === 1 && (
          <Box sx={{ p: 2.5 }}>
            <TableContainer sx={{ border: '1px solid #e2e8f0', borderRadius: 2 }}>
              <Table>
                <TableHead sx={{ bgcolor: '#f8fafc' }}>
                  <TableRow>
                    <TableCell sx={{ fontWeight: 700 }}>Date</TableCell>
                    <TableCell sx={{ fontWeight: 700 }}>Organization</TableCell>
                    <TableCell sx={{ fontWeight: 700 }}>Event</TableCell>
                    <TableCell align="right" sx={{ fontWeight: 700 }}>Amount</TableCell>
                    <TableCell sx={{ fontWeight: 700 }}>Method</TableCell>
                    <TableCell sx={{ fontWeight: 700 }}>Reference</TableCell>
                    <TableCell align="center" sx={{ fontWeight: 700 }}>Action</TableCell>
                  </TableRow>
                </TableHead>
                <TableBody>
                  {eventsLoading ? (
                    <TableRow>
                      <TableCell colSpan={7} align="center" sx={{ py: 6 }}>
                        <CircularProgress size={32} />
                      </TableCell>
                    </TableRow>
                  ) : subEvents.length === 0 ? (
                    <TableRow>
                      <TableCell colSpan={7} align="center" sx={{ py: 6, color: 'text.secondary' }}>
                        No pending subscription verification requests.
                      </TableCell>
                    </TableRow>
                  ) : (
                    subEvents.map((evt: any) => (
                      <TableRow key={evt.id} hover>
                        <TableCell>{new Date(evt.created_at).toLocaleString()}</TableCell>
                        <TableCell sx={{ fontWeight: 600 }}>{evt.organizations?.name}</TableCell>
                        <TableCell>
                          <Chip
                            label={evt.event_type}
                            size="small"
                            color={evt.event_type === 'payment_approved' ? 'success' : evt.event_type === 'payment_submitted' ? 'warning' : 'default'}
                            sx={{ height: 22, fontSize: 11 }}
                          />
                        </TableCell>
                        <TableCell align="right" sx={{ fontWeight: 700 }}>
                          {evt.amount ? `${Number(evt.amount).toLocaleString()} MMK` : '-'}
                        </TableCell>
                        <TableCell>{evt.payment_method || '-'}</TableCell>
                        <TableCell>{evt.payment_reference || '-'}</TableCell>
                        <TableCell align="center">
                          {evt.event_type === 'payment_submitted' && (
                            <Button
                              size="small"
                              variant="contained"
                              onClick={() => setReviewEvent(evt)}
                              sx={{ borderRadius: 2, fontSize: 11, py: 0.4 }}
                            >
                              Review & Approve
                            </Button>
                          )}
                        </TableCell>
                      </TableRow>
                    ))
                  )}
                </TableBody>
              </Table>
            </TableContainer>
          </Box>
        )}

        {/* Tab 2: Platform Audit Logs */}
        {currentTabIndex === 2 && (
          <Box sx={{ p: 2.5 }}>
            <TableContainer sx={{ border: '1px solid #e2e8f0', borderRadius: 2 }}>
              <Table size="small">
                <TableHead sx={{ bgcolor: '#f8fafc' }}>
                  <TableRow>
                    <TableCell sx={{ fontWeight: 700 }}>Timestamp</TableCell>
                    <TableCell sx={{ fontWeight: 700 }}>Organization</TableCell>
                    <TableCell sx={{ fontWeight: 700 }}>User</TableCell>
                    <TableCell sx={{ fontWeight: 700 }}>Action</TableCell>
                    <TableCell sx={{ fontWeight: 700 }}>Entity & Details</TableCell>
                  </TableRow>
                </TableHead>
                <TableBody>
                  {auditLoading ? (
                    <TableRow>
                      <TableCell colSpan={5} align="center" sx={{ py: 6 }}>
                        <CircularProgress size={32} />
                      </TableCell>
                    </TableRow>
                  ) : auditLogs.length === 0 ? (
                    <TableRow>
                      <TableCell colSpan={5} align="center" sx={{ py: 6, color: 'text.secondary' }}>
                        No audit logs recorded yet.
                      </TableCell>
                    </TableRow>
                  ) : (
                    auditLogs.map((log: any) => (
                      <TableRow key={log.id} hover>
                        <TableCell>{new Date(log.created_at).toLocaleString()}</TableCell>
                        <TableCell sx={{ fontWeight: 500 }}>{log.organizations?.name || 'Platform'}</TableCell>
                        <TableCell>{log.profiles?.full_name || 'System'}</TableCell>
                        <TableCell sx={{ fontWeight: 600, color: '#0284c7' }}>{log.action}</TableCell>
                        <TableCell>{log.entity_type} ({log.entity_id ? log.entity_id.slice(0, 8) + '...' : '-'})</TableCell>
                      </TableRow>
                    ))
                  )}
                </TableBody>
              </Table>
            </TableContainer>
          </Box>
        )}

        {/* Tab 3: Usage Analytics */}
        {currentTabIndex === 3 && (
          <Box sx={{ p: 3 }}>
            <Typography variant="h6" sx={{ fontWeight: 700, mb: 2 }}>
              Cross-Tenant Usage Analytics
            </Typography>
            <Grid container spacing={3}>
              <Grid item xs={12} md={6}>
                <Paper variant="outlined" sx={{ p: 2.5, borderRadius: 2 }}>
                  <Typography variant="subtitle2" sx={{ fontWeight: 700, mb: 1.5 }}>
                    Tenant Distribution
                  </Typography>
                  <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
                    Proportion of active versus suspended organizations on ShopFlow.
                  </Typography>
                  <Box sx={{ display: 'flex', gap: 3 }}>
                    <Box>
                      <Typography variant="h4" sx={{ fontWeight: 800, color: '#16a34a' }}>
                        {activeOrgsCount}
                      </Typography>
                      <Typography variant="caption" color="text.secondary">Active Tenants</Typography>
                    </Box>
                    <Box>
                      <Typography variant="h4" sx={{ fontWeight: 800, color: suspendedOrgsCount > 0 ? '#dc2626' : '#64748b' }}>
                        {suspendedOrgsCount}
                      </Typography>
                      <Typography variant="caption" color="text.secondary">Suspended Tenants</Typography>
                    </Box>
                    <Box>
                      <Typography variant="h4" sx={{ fontWeight: 800, color: '#0284c7' }}>
                        {totalOrgsCount > 0 ? `${Math.round((activeOrgsCount / totalOrgsCount) * 100)}%` : '100%'}
                      </Typography>
                      <Typography variant="caption" color="text.secondary">Health Ratio</Typography>
                    </Box>
                  </Box>
                </Paper>
              </Grid>

              <Grid item xs={12} md={6}>
                <Paper variant="outlined" sx={{ p: 2.5, borderRadius: 2 }}>
                  <Typography variant="subtitle2" sx={{ fontWeight: 700, mb: 1.5 }}>
                    Localization & Regional Configuration
                  </Typography>
                  <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
                    Default platform settings enforced across all tenants.
                  </Typography>
                  <Box sx={{ display: 'flex', gap: 2, flexWrap: 'wrap' }}>
                    <Chip label="Default Currency: MMK (Ks)" sx={{ fontWeight: 600 }} />
                    <Chip label="Timezone: Asia/Yangon (UTC+06:30)" sx={{ fontWeight: 600 }} />
                    <Chip label="Multi-Tenant Isolation: Row-Level Security" sx={{ fontWeight: 600 }} />
                    <Chip label="Costing: Weighted Average Cost (WAC)" sx={{ fontWeight: 600 }} />
                  </Box>
                </Paper>
              </Grid>
            </Grid>
          </Box>
        )}
      </Paper>

      {/* Suspend / Activate Confirmation Dialog */}
      <Dialog
        open={Boolean(statusDialogOrg)}
        onClose={() => setStatusDialogOrg(null)}
        maxWidth="xs"
        fullWidth
      >
        <DialogTitle sx={{ fontWeight: 700 }}>
          {statusDialogOrg?.is_active ? 'Suspend Tenant Organization?' : 'Activate Tenant Organization?'}
        </DialogTitle>
        <DialogContent dividers>
          <Typography variant="body2">
            Are you sure you want to {statusDialogOrg?.is_active ? 'suspend' : 'activate'}{' '}
            <strong>{statusDialogOrg?.name}</strong>?
          </Typography>
          {statusDialogOrg?.is_active && (
            <Alert severity="warning" sx={{ mt: 2, borderRadius: 1.5 }}>
              Members of this organization will not be able to access wholesale features or create sales while suspended.
            </Alert>
          )}
        </DialogContent>
        <DialogActions sx={{ px: 3, py: 2 }}>
          <Button onClick={() => setStatusDialogOrg(null)} disabled={processing}>
            Cancel
          </Button>
          <Button
            variant="contained"
            color={statusDialogOrg?.is_active ? 'error' : 'success'}
            onClick={handleToggleOrgStatus}
            disabled={processing}
          >
            {processing ? <CircularProgress size={20} /> : statusDialogOrg?.is_active ? 'Confirm Suspension' : 'Confirm Activation'}
          </Button>
        </DialogActions>
      </Dialog>

      {/* Payment Review Dialog */}
      <Dialog open={Boolean(reviewEvent)} onClose={() => setReviewEvent(null)} maxWidth="xs" fullWidth>
        <DialogTitle sx={{ fontWeight: 700 }}>Verify Manual Subscription Payment</DialogTitle>
        <DialogContent dividers>
          <Typography variant="body2" sx={{ mb: 1 }}>
            <strong>Organization:</strong> {reviewEvent?.organizations?.name}
          </Typography>
          <Typography variant="body2" sx={{ mb: 1 }}>
            <strong>Amount:</strong> {reviewEvent?.amount?.toLocaleString()} MMK
          </Typography>
          <Typography variant="body2" sx={{ mb: 1 }}>
            <strong>Method:</strong> {reviewEvent?.payment_method?.toUpperCase()}
          </Typography>
          <Typography variant="body2" sx={{ mb: 2 }}>
            <strong>Reference / Trx ID:</strong> {reviewEvent?.payment_reference}
          </Typography>

          <TextField
            fullWidth
            size="small"
            label="Admin Notes / Verification Memo"
            placeholder="e.g. Verified in KBZPay merchant portal"
            value={adminNotes}
            onChange={(e) => setAdminNotes(e.target.value)}
          />
        </DialogContent>
        <DialogActions sx={{ px: 3, py: 2 }}>
          <Button
            color="error"
            startIcon={<CancelIcon />}
            onClick={() => handleVerifyPayment(false)}
            disabled={processing}
          >
            Reject
          </Button>
          <Button
            variant="contained"
            color="success"
            startIcon={<CheckCircleIcon />}
            onClick={() => handleVerifyPayment(true)}
            disabled={processing}
          >
            Approve & Activate
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
};
