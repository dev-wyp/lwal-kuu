import React, { useState } from 'react';
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
} from '@mui/material';
import AdminPanelSettingsIcon from '@mui/icons-material/AdminPanelSettings';
import CheckCircleIcon from '@mui/icons-material/CheckCircle';
import CancelIcon from '@mui/icons-material/Cancel';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/lib/supabase';
import { useAuth } from '@/context/AuthContext';
import { useNotification } from '@/context/NotificationContext';

export const PlatformAdminPage: React.FC = () => {
  const { profile } = useAuth();
  const { showSuccess, showError } = useNotification();
  const queryClient = useQueryClient();

  const [activeTab, setActiveTab] = useState(0);
  const [reviewEvent, setReviewEvent] = useState<any>(null);
  const [adminNotes, setAdminNotes] = useState('');
  const [processing, setProcessing] = useState(false);

  const isPlatformAdmin = Boolean(profile?.is_platform_admin);

  // 1. Fetch All Organizations
  const { data: allOrgs = [], isLoading: orgsLoading } = useQuery({
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

  // 2. Fetch Pending Subscription Events
  const { data: subEvents = [], isLoading: eventsLoading } = useQuery({
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

  // 3. Fetch Platform Audit Logs
  const { data: auditLogs = [], isLoading: auditLoading } = useQuery({
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
        .limit(50);

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

  return (
    <Box>
      <Box sx={{ display: 'flex', alignItems: 'center', gap: 1.5, mb: 3 }}>
        <AdminPanelSettingsIcon sx={{ fontSize: 36, color: '#dc2626' }} />
        <div>
          <Typography variant="h4" sx={{ fontWeight: 800 }}>
            Platform Super-Admin
          </Typography>
          <Typography variant="body2" color="text.secondary">
            Cross-tenant governance, subscription approvals, and global audit logging.
          </Typography>
        </div>
      </Box>

      <Paper elevation={0} sx={{ borderRadius: 3, border: '1px solid #e2e8f0', bgcolor: '#ffffff' }}>
        <Tabs
          value={activeTab}
          onChange={(_e, v) => setActiveTab(v)}
          sx={{ px: 2, borderBottom: '1px solid #e2e8f0' }}
        >
          <Tab label="Tenant Organizations" sx={{ fontWeight: 600 }} />
          <Tab label="Subscription Payments & Approvals" sx={{ fontWeight: 600 }} />
          <Tab label="Platform Audit Logs" sx={{ fontWeight: 600 }} />
        </Tabs>

        {activeTab === 0 && (
          <TableContainer>
            <Table>
              <TableHead>
                <TableRow>
                  <TableCell>Organization Name</TableCell>
                  <TableCell>Slug</TableCell>
                  <TableCell>Created Date</TableCell>
                  <TableCell>Subscription</TableCell>
                  <TableCell>Expiry Date</TableCell>
                  <TableCell align="center">Tenant Status</TableCell>
                </TableRow>
              </TableHead>
              <TableBody>
                {orgsLoading ? (
                  <TableRow>
                    <TableCell colSpan={6} align="center" sx={{ py: 6 }}>
                      <CircularProgress size={32} />
                    </TableCell>
                  </TableRow>
                ) : allOrgs.map((org: any) => {
                  const sub = org.subscriptions?.[0] || org.subscriptions;
                  return (
                    <TableRow key={org.id} hover>
                      <TableCell sx={{ fontWeight: 600 }}>{org.name}</TableCell>
                      <TableCell>{org.slug}</TableCell>
                      <TableCell>{new Date(org.created_at).toLocaleDateString()}</TableCell>
                      <TableCell>
                        <Chip
                          label={sub?.plan_id?.toUpperCase() || 'TRIAL'}
                          size="small"
                          sx={{ height: 22, fontSize: 11, fontWeight: 700 }}
                        />
                      </TableCell>
                      <TableCell>
                        {sub?.current_period_end ? new Date(sub.current_period_end).toLocaleDateString() : '-'}
                      </TableCell>
                      <TableCell align="center">
                        <Chip
                          label={org.is_active ? 'ACTIVE' : 'SUSPENDED'}
                          size="small"
                          color={org.is_active ? 'success' : 'error'}
                          sx={{ height: 20, fontSize: 10, fontWeight: 700 }}
                        />
                      </TableCell>
                    </TableRow>
                  );
                })}
              </TableBody>
            </Table>
          </TableContainer>
        )}

        {activeTab === 1 && (
          <TableContainer>
            <Table>
              <TableHead>
                <TableRow>
                  <TableCell>Date</TableCell>
                  <TableCell>Organization</TableCell>
                  <TableCell>Event</TableCell>
                  <TableCell align="right">Amount</TableCell>
                  <TableCell>Method</TableCell>
                  <TableCell>Ref #</TableCell>
                  <TableCell align="center">Review</TableCell>
                </TableRow>
              </TableHead>
              <TableBody>
                {eventsLoading ? (
                  <TableRow>
                    <TableCell colSpan={7} align="center" sx={{ py: 6 }}>
                      <CircularProgress size={32} />
                    </TableCell>
                  </TableRow>
                ) : subEvents.map((evt: any) => (
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
                ))}
              </TableBody>
            </Table>
          </TableContainer>
        )}

        {activeTab === 2 && (
          <TableContainer>
            <Table size="small">
              <TableHead>
                <TableRow>
                  <TableCell>Timestamp</TableCell>
                  <TableCell>Organization</TableCell>
                  <TableCell>User</TableCell>
                  <TableCell>Action</TableCell>
                  <TableCell>Entity</TableCell>
                </TableRow>
              </TableHead>
              <TableBody>
                {auditLoading ? (
                  <TableRow>
                    <TableCell colSpan={5} align="center" sx={{ py: 6 }}>
                      <CircularProgress size={32} />
                    </TableCell>
                  </TableRow>
                ) : auditLogs.map((log: any) => (
                  <TableRow key={log.id} hover>
                    <TableCell>{new Date(log.created_at).toLocaleString()}</TableCell>
                    <TableCell sx={{ fontWeight: 500 }}>{log.organizations?.name}</TableCell>
                    <TableCell>{log.profiles?.full_name || 'System'}</TableCell>
                    <TableCell sx={{ fontWeight: 600, color: '#0284c7' }}>{log.action}</TableCell>
                    <TableCell>{log.entity_type} ({log.entity_id.slice(0, 8)}...)</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </TableContainer>
        )}
      </Paper>

      {/* Review Dialog */}
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
