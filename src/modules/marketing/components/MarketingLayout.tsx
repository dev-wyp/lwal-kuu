import React from 'react';
import { Box, Tabs, Tab, Paper, Alert, Chip, Stack, Typography, Badge, Dialog, DialogTitle, DialogContent, DialogActions, Button, MenuItem, TextField } from '@mui/material';
import { Outlet, useLocation, useNavigate } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/lib/supabase';
import { useMarketingWorkspace } from '../hooks/useMarketingWorkspace';
import { MarketingOrganizationContext } from '../hooks/useMarketingWorkspace';
import { useAuth } from '@/context/AuthContext';
import { useOrg } from '@/context/OrgContext';
import type { MarketingNotification } from '../types';

const TABS = [
  { label: 'Overview', path: '/admin/marketing' },
  { label: 'Calendar', path: '/admin/marketing/calendar' },
  { label: 'Content', path: '/admin/marketing/content' },
  { label: 'Approvals', path: '/admin/marketing/approvals' },
  { label: 'Campaigns', path: '/admin/marketing/campaigns' },
  { label: 'Social accounts', path: '/admin/marketing/social-accounts' },
  { label: 'Leads', path: '/admin/marketing/leads' },
  { label: 'Analytics', path: '/admin/marketing/analytics' },
  { label: 'Reports', path: '/admin/marketing/reports' },
  { label: 'AI settings', path: '/admin/marketing/ai-settings' },
  { label: 'Settings', path: '/admin/marketing/settings' },
];

export const MarketingLayout: React.FC = () => {
  const location = useLocation();
  const navigate = useNavigate();
  const { profile } = useAuth();
  const { currentOrg } = useOrg();
  const queryClient = useQueryClient();
  const [alertsOpen, setAlertsOpen] = React.useState(false);
  const [savedOrgId, setSavedOrgId] = React.useState(() => localStorage.getItem('shopflow_marketing_org_id') || '');

  const { data: availableOrganizations = [], isLoading: organizationsLoading, error: organizationsError } = useQuery({
    queryKey: ['platform_marketing_organizations'],
    enabled: Boolean(profile?.is_platform_admin),
    queryFn: async () => {
      const { data: rows, error: orgError } = await supabase
        .from('organizations')
        .select('id, name, is_active')
        .eq('is_active', true)
        .order('name');
      if (orgError) throw orgError;
      return rows || [];
    },
  });

  const selectedOrgId = availableOrganizations.some((org) => org.id === savedOrgId)
    ? savedOrgId
    : currentOrg?.id && availableOrganizations.some((org) => org.id === currentOrg.id)
      ? currentOrg.id
      : availableOrganizations[0]?.id ?? null;

  React.useEffect(() => {
    if (selectedOrgId && selectedOrgId !== savedOrgId) {
      setSavedOrgId(selectedOrgId);
      localStorage.setItem('shopflow_marketing_org_id', selectedOrgId);
    }
  }, [selectedOrgId, savedOrgId]);

  const { orgId, data, isLoading, error } = useMarketingWorkspace(selectedOrgId);

  const current = TABS.find((tab) =>
    tab.path === '/admin/marketing'
      ? location.pathname === '/admin/marketing'
      : location.pathname.startsWith(tab.path)
  ) ?? TABS[0];

  const { data: notifications = [] } = useQuery({
    queryKey: ['marketing_notifications', orgId],
    enabled: Boolean(orgId),
    queryFn: async () => {
      const { data: rows, error: notifError } = await supabase
        .from('marketing_notifications')
        .select('*')
        .eq('organization_id', orgId as string)
        .eq('is_read', false)
        .order('created_at', { ascending: false })
        .limit(8);
      if (notifError) throw notifError;
      return (rows || []) as MarketingNotification[];
    },
  });

  const pendingApprovals = notifications.filter((n) => n.notification_type === 'pending_approval').length;

  return (
    <Box>
      <Stack direction={{ xs: 'column', md: 'row' }} justifyContent="space-between" alignItems={{ md: 'center' }} spacing={1} sx={{ mb: 2 }}>
        <Box>
          <Typography variant="h4" sx={{ fontWeight: 700 }}>
            Marketing
          </Typography>
          <Typography variant="body2" color="text.secondary">
            Review AI drafts, approve publishing, and track Myanmar Facebook & TikTok results.
          </Typography>
        </Box>
        <Stack direction="row" spacing={1} flexWrap="wrap">
          <TextField
            select
            size="small"
            label="Marketing workspace"
            value={selectedOrgId || ''}
            onChange={(event) => {
              const value = event.target.value;
              setSavedOrgId(value);
              localStorage.setItem('shopflow_marketing_org_id', value);
              void queryClient.invalidateQueries({ queryKey: ['marketing_workspace'] });
            }}
            disabled={organizationsLoading || availableOrganizations.length === 0}
            sx={{ minWidth: 220, bgcolor: 'white', borderRadius: 1 }}
          >
            {availableOrganizations.map((org) => (
              <MenuItem key={org.id} value={org.id}>{org.name}</MenuItem>
            ))}
          </TextField>
          <Chip size="small" label="Manual approval required" color="warning" />
          <Chip size="small" label={data?.workspace.timezone ?? 'Asia/Yangon'} />
          <Badge badgeContent={notifications.length} color="error">
            <Chip size="small" label="Alerts" variant="outlined" onClick={() => setAlertsOpen(true)} />
          </Badge>
        </Stack>
      </Stack>

      {error && (
        <Alert severity="error" sx={{ mb: 2 }}>
          {error instanceof Error ? error.message : 'Unable to load the marketing workspace'}
        </Alert>
      )}
      {organizationsError && (
        <Alert severity="error" sx={{ mb: 2 }}>
          {organizationsError instanceof Error ? organizationsError.message : 'Unable to load platform marketing workspaces'}
        </Alert>
      )}
      {!organizationsLoading && availableOrganizations.length === 0 && (
        <Alert severity="warning" sx={{ mb: 2 }}>
          No active organization is available as a marketing workspace. Create or activate an organization first.
        </Alert>
      )}

      <Paper sx={{ mb: 3 }}>
        <Tabs
          value={current.path}
          onChange={(_e, value: string) => navigate(value)}
          variant="scrollable"
          scrollButtons="auto"
        >
          {TABS.map((tab) => (
            <Tab
              key={tab.path}
              value={tab.path}
              label={
                tab.path === '/admin/marketing/approvals' && pendingApprovals > 0
                  ? `${tab.label} (${pendingApprovals})`
                  : tab.label
              }
            />
          ))}
        </Tabs>
      </Paper>

      {organizationsLoading || isLoading ? (
        <Alert severity="info">Loading marketing workspace…</Alert>
      ) : !orgId ? (
        <Alert severity="warning">Select an active marketing workspace to continue.</Alert>
      ) : (
        <MarketingOrganizationContext.Provider value={orgId}>
          <Outlet />
        </MarketingOrganizationContext.Provider>
      )}

      <Dialog open={alertsOpen} onClose={() => setAlertsOpen(false)} fullWidth maxWidth="sm">
        <DialogTitle>Marketing alerts</DialogTitle>
        <DialogContent>
          {notifications.length === 0 && (
            <Typography variant="body2" color="text.secondary">No unread alerts.</Typography>
          )}
          <Stack spacing={1} sx={{ mt: 1 }}>
            {notifications.map((item) => (
              <Alert
                key={item.id}
                severity={item.notification_type.includes('fail') || item.notification_type.includes('expired') ? 'error' : 'info'}
              >
                <Typography fontWeight={600}>{item.title}</Typography>
                <Typography variant="body2">{item.body}</Typography>
              </Alert>
            ))}
          </Stack>
        </DialogContent>
        <DialogActions>
          <Button
            onClick={async () => {
              if (!orgId) return;
              await supabase
                .from('marketing_notifications')
                .update({ is_read: true })
                .eq('organization_id', orgId)
                .eq('is_read', false);
              await queryClient.invalidateQueries({ queryKey: ['marketing_notifications'] });
              setAlertsOpen(false);
            }}
          >
            Mark as read
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
};
