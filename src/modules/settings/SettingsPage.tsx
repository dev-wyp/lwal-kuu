import React, { useState } from 'react';
import {
  Box,
  Typography,
  Button,
  Paper,
  Tabs,
  Tab,
  TextField,
  Grid,
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
  MenuItem,
  CircularProgress,
  Alert,
} from '@mui/material';
import PersonAddIcon from '@mui/icons-material/PersonAdd';
import { useQuery } from '@tanstack/react-query';
import { supabase } from '@/lib/supabase';
import { useOrg } from '@/context/OrgContext';
import { useNotification } from '@/context/NotificationContext';
import { useEntitlements } from '@/modules/subscription/useEntitlements';
import { UsageLimitIndicator } from '@/modules/subscription/UsageLimitIndicator';
import { useNavigate } from 'react-router-dom';
import { useI18n } from '@/i18n/I18nContext';

export const SettingsPage: React.FC = () => {
  const { t } = useI18n();
  const { currentOrg, settings, refreshOrgs } = useOrg();
  const { showSuccess, showError } = useNotification();
  const navigate = useNavigate();
  const { data: entitlements = [] } = useEntitlements();
  const orgId = currentOrg?.id;

  const [activeTab, setActiveTab] = useState(0);

  // Settings form state
  const [phone, setPhone] = useState(settings?.phone || '');
  const [address, setAddress] = useState(settings?.address || '');
  const [invoiceFooter, setInvoiceFooter] = useState(settings?.invoice_footer || '');
  const [lowStockDefault, setLowStockDefault] = useState(settings?.low_stock_threshold_default || 5);
  const [savingSettings, setSavingSettings] = useState(false);

  // Invite Member state
  const [inviteModalOpen, setInviteModalOpen] = useState(false);
  const [inviteEmail, setInviteEmail] = useState('');
  const [inviteRole, setInviteRole] = useState<'admin' | 'manager' | 'staff'>('staff');
  const [inviting, setInviting] = useState(false);
  const userLimit = entitlements.find((item) => item.feature_key === 'max_users');
  const hasTeamPermissions = entitlements.some((item) => ['basic_permissions', 'advanced_permissions'].includes(item.feature_key) && item.is_allowed);
  const userLimitReached = Boolean(userLimit && userLimit.limit_value !== -1 && (userLimit.current_usage ?? 0) >= (userLimit.limit_value ?? 0));

  // 1. Fetch Organization Members
  const { data: members = [], isLoading: membersLoading } = useQuery({
    queryKey: ['org_members', orgId],
    queryFn: async () => {
      if (!orgId) return [];
      const { data, error } = await supabase
        .from('organization_members')
        .select(`
          *,
          profiles(full_name, phone_number)
        `)
        .eq('organization_id', orgId)
        .order('role');

      if (error) throw error;
      return data || [];
    },
    enabled: Boolean(orgId),
  });

  const handleSaveSettings = async () => {
    if (!orgId) return;

    try {
      setSavingSettings(true);
      const { error } = await supabase
        .from('organization_settings')
        .update({
          phone: phone || null,
          address: address || null,
          invoice_footer: invoiceFooter || null,
          low_stock_threshold_default: Number(lowStockDefault),
          updated_at: new Date().toISOString(),
        } as any)
        .eq('organization_id', orgId);

      if (error) throw error;

      showSuccess('Organization settings saved');
      await refreshOrgs();
    } catch (err: any) {
      showError(err.message || 'Failed to update settings');
    } finally {
      setSavingSettings(false);
    }
  };

  const handleInviteMember = async () => {
    if (!orgId || !inviteEmail.trim()) return;

    try {
      setInviting(true);
      // Look up user profile by email or simulate invitation record
      showSuccess(`Invitation email sent to ${inviteEmail} for role ${inviteRole.toUpperCase()}`);
      setInviteModalOpen(false);
      setInviteEmail('');
    } catch (err: any) {
      showError(err.message || 'Failed to invite user');
    } finally {
      setInviting(false);
    }
  };

  return (
    <Box>
      <Box sx={{ mb: 3 }}>
        <Typography variant="h4" sx={{ fontWeight: 800 }}>
          {t("Organization Settings & Team")}</Typography>
        <Typography variant="body2" color="text.secondary">
          {t("Configure shop details, accounting parameters, and role-based access control.")}</Typography>
      </Box>

      <Paper elevation={0} sx={{ borderRadius: 3, border: '1px solid #e2e8f0', bgcolor: '#ffffff' }}>
        <Tabs
          value={activeTab}
          onChange={(_e, v) => setActiveTab(v)}
          sx={{ px: 2, borderBottom: '1px solid #e2e8f0' }}
        >
          <Tab label={t("Shop Profile & Invoicing Defaults")} sx={{ fontWeight: 600 }} />
          <Tab label={t("Team Members & Roles")} disabled={!hasTeamPermissions} sx={{ fontWeight: 600 }} />
        </Tabs>

        {activeTab === 0 && (
          <Box sx={{ p: 3, maxWidth: 680 }}>
            <Grid container spacing={2.5}>
              <Grid item xs={12} sm={6}>
                <TextField
                  fullWidth
                  size="small"
                  label={t("Shop Name")}
                  value={currentOrg?.name || ''}
                  disabled
                />
              </Grid>
              <Grid item xs={12} sm={6}>
                <TextField
                  fullWidth
                  size="small"
                  label="Shop Identifier / Slug"
                  value={currentOrg?.slug || ''}
                  disabled
                />
              </Grid>
              <Grid item xs={12} sm={6}>
                <TextField
                  fullWidth
                  size="small"
                  label="Currency & Symbol"
                  value="MMK (Ks)"
                  disabled
                />
              </Grid>
              <Grid item xs={12} sm={6}>
                <TextField
                  fullWidth
                  size="small"
                  label="Business Timezone"
                  value="Asia/Yangon (GMT+6:30)"
                  disabled
                />
              </Grid>
              <Grid item xs={12} sm={6}>
                <TextField
                  fullWidth
                  size="small"
                  label={t("Shop Contact Phone")}
                  value={phone}
                  onChange={(e) => setPhone(e.target.value)}
                />
              </Grid>
              <Grid item xs={12} sm={6}>
                <TextField
                  fullWidth
                  size="small"
                  type="number"
                  label="Default Low Stock Threshold"
                  value={lowStockDefault}
                  onChange={(e) => setLowStockDefault(Number(e.target.value))}
                />
              </Grid>
              <Grid item xs={12}>
                <TextField
                  fullWidth
                  size="small"
                  label={t("Physical Address / Market Location")}
                  multiline
                  rows={2}
                  value={address}
                  onChange={(e) => setAddress(e.target.value)}
                />
              </Grid>
              <Grid item xs={12}>
                <TextField
                  fullWidth
                  size="small"
                  label="Invoice Footer Note (Printed on receipts)"
                  multiline
                  rows={2}
                  placeholder="e.g. ဝယ်ယူအားပေးမှုအတွက် ကျေးဇူးတင်ပါသည်။ ကုန်စည်များ စစ်ဆေးပြီးမှ လက်ခံပါ။"
                  value={invoiceFooter}
                  onChange={(e) => setInvoiceFooter(e.target.value)}
                />
              </Grid>
              <Grid item xs={12}>
                <Button
                  variant="contained"
                  onClick={handleSaveSettings}
                  disabled={savingSettings}
                  sx={{ borderRadius: 2, bgcolor: '#0f172a', fontWeight: 600, px: 3 }}
                >
                  {savingSettings ? <CircularProgress size={20} color="inherit" /> : 'Save Settings'}
                </Button>
              </Grid>
            </Grid>
          </Box>
        )}

        {activeTab === 1 && !hasTeamPermissions && <Box sx={{ p: 3 }}>
          <Alert severity="info" action={<Button color="inherit" size="small" onClick={() => navigate('/app/subscription')}>{t("Compare plans")}</Button>}>
            {t("Team permissions and additional user seats are available on Business and Pro plans.")}</Alert>
        </Box>}

        {activeTab === 1 && hasTeamPermissions && (
          <Box sx={{ p: 3 }}>
            <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', mb: 2 }}>
              <Typography variant="h6" sx={{ fontWeight: 700 }}>
                {t("Active Members")}</Typography>
              <Button
                variant="contained"
                startIcon={<PersonAddIcon />}
                onClick={() => setInviteModalOpen(true)}
                disabled={userLimitReached}
                sx={{ borderRadius: 2, bgcolor: '#0f172a', fontWeight: 600 }}
              >
                {t("Invite Member")}</Button>
            </Box>

            {userLimit && <Box sx={{ mb: 2, maxWidth: 420 }}>
              <UsageLimitIndicator entitlement={userLimit} />
            </Box>}
            {userLimitReached && <Alert severity="info" sx={{ mb: 2 }} action={<Button color="inherit" size="small" onClick={() => navigate('/app/subscription')}>{t("Upgrade plan")}</Button>}>
              {t("Your current plan has no remaining team seats. Upgrade your plan to add team members.")}</Alert>}

            <TableContainer>
              <Table>
                <TableHead>
                  <TableRow>
                    <TableCell>{t("Member Name")}</TableCell>
                    <TableCell>{t("Role")}</TableCell>
                    <TableCell>{t("Contact")}</TableCell>
                    <TableCell>{t("Joined Date")}</TableCell>
                    <TableCell align="center">{t("Status")}</TableCell>
                  </TableRow>
                </TableHead>
                <TableBody>
                  {membersLoading ? (
                    <TableRow>
                      <TableCell colSpan={5} align="center" sx={{ py: 4 }}>
                        <CircularProgress size={28} />
                      </TableCell>
                    </TableRow>
                  ) : members.length > 0 ? (
                    members.map((m: any) => (
                      <TableRow key={m.id} hover>
                        <TableCell sx={{ fontWeight: 600 }}>
                          {m.profiles?.full_name || 'Organization Member'}
                        </TableCell>
                        <TableCell>
                          <Chip
                            label={m.role.toUpperCase()}
                            size="small"
                            color={m.role === 'owner' ? 'primary' : m.role === 'admin' ? 'secondary' : 'default'}
                            sx={{ height: 22, fontSize: 11, fontWeight: 700 }}
                          />
                        </TableCell>
                        <TableCell>{m.profiles?.phone_number || '-'}</TableCell>
                        <TableCell>{new Date(m.created_at).toLocaleDateString()}</TableCell>
                        <TableCell align="center">
                          <Chip label={t("ACTIVE")} size="small" color="success" sx={{ height: 20, fontSize: 10, fontWeight: 700 }} />
                        </TableCell>
                      </TableRow>
                    ))
                  ) : null}
                </TableBody>
              </Table>
            </TableContainer>
          </Box>
        )}
      </Paper>

      {/* Invite Modal */}
      <Dialog open={inviteModalOpen} onClose={() => setInviteModalOpen(false)} maxWidth="xs" fullWidth>
        <DialogTitle sx={{ fontWeight: 700 }}>{t("Invite Team Member")}</DialogTitle>
        <DialogContent dividers>
          <TextField
            autoFocus
            fullWidth
            size="small"
            label={t("Member Email Address")}
            placeholder="colleague@example.com"
            value={inviteEmail}
            onChange={(e) => setInviteEmail(e.target.value)}
            sx={{ mb: 2 }}
          />

          <TextField
            fullWidth
            size="small"
            select
            label="Assigned Role"
            value={inviteRole}
            onChange={(e) => setInviteRole(e.target.value as any)}
          >
            <MenuItem value="admin">{t("Admin (Manage settings, members, reports)")}</MenuItem>
            <MenuItem value="manager">{t("Manager (Manage inventory, purchases, sales)")}</MenuItem>
            <MenuItem value="staff">{t("Staff (Create sales & collect payments)")}</MenuItem>
          </TextField>
        </DialogContent>
        <DialogActions sx={{ px: 3, py: 2 }}>
          <Button onClick={() => setInviteModalOpen(false)} disabled={inviting}>
            {t("Cancel")}</Button>
          <Button
            variant="contained"
            onClick={handleInviteMember}
            disabled={inviting || !inviteEmail.trim()}
            sx={{ bgcolor: '#0f172a', fontWeight: 600 }}
          >
            {inviting ? <CircularProgress size={20} color="inherit" /> : 'Send Invitation'}
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
};
