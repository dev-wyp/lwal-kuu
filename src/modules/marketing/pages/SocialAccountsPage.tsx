import React, { useState } from 'react';
import { Alert, Box, Button, Card, CardContent, Chip, Stack, Typography } from '@mui/material';
import { useSearchParams } from 'react-router-dom';
import { supabase } from '@/lib/supabase';
import { useMarketingWorkspace } from '../hooks/useMarketingWorkspace';
import { useNotification } from '@/context/NotificationContext';
import type { SocialAccount } from '../types';

export const SocialAccountsPage: React.FC = () => {
  const { data, refetch, canManageMarketing, orgId } = useMarketingWorkspace();
  const { showError, showSuccess } = useNotification();
  const [searchParams] = useSearchParams();
  const [setup, setSetup] = useState<string | null>(null);
  const accounts = data?.accounts ?? [];
  const oauthError = searchParams.get('oauth_error');
  const connected = searchParams.get('connected');

  const connect = async (provider: 'facebook' | 'tiktok') => {
    setSetup(null);
    try {
      const { data: payload, error } = await supabase.functions.invoke('marketing-oauth', {
        body: { action: 'connect', provider, organization_id: orgId, redirect_to: '/admin/marketing/social-accounts' },
      });
      if (error) throw error;
      if (payload?.auth_url) {
        window.location.href = payload.auth_url as string;
        return;
      }
      setSetup(payload?.setup_instructions || payload?.message || 'OAuth credentials are not configured.');
    } catch (err) {
      showError(err instanceof Error ? err.message : 'Unable to start OAuth');
    }
  };

  const disconnect = async (account: SocialAccount) => {
    try {
      const { error } = await supabase.functions.invoke('marketing-oauth', {
        body: { action: 'disconnect', account_id: account.id },
      });
      if (error) throw error;
      showSuccess('Disconnected. Tokens are removed server-side.');
      await refetch();
    } catch (err) {
      showError(err instanceof Error ? err.message : 'Disconnect failed');
    }
  };

  return (
    <Box>
      <Alert severity="info" sx={{ mb: 2 }}>
        Access tokens are stored only in server-side secret tables. Connection status below is metadata, not a publish grant.
        If Meta or TikTok API access is not approved yet, use manual export from the approvals preview.
      </Alert>
      {setup && <Alert severity="warning" sx={{ mb: 2 }}>{setup}</Alert>}
      {oauthError && <Alert severity="error" sx={{ mb: 2 }}>OAuth failed: {oauthError}</Alert>}
      {connected && <Alert severity="success" sx={{ mb: 2 }}>{connected} connected. Publishing still requires approved content.</Alert>}
      <Stack spacing={2}>
        {accounts.map((account) => (
          <Card key={account.id}>
            <CardContent>
              <Stack direction={{ xs: 'column', md: 'row' }} justifyContent="space-between" spacing={2}>
                <Box>
                  <Typography variant="h6">{account.display_name || account.provider}</Typography>
                  <Chip size="small" label={account.connection_status} color={account.connection_status === 'connected' ? 'success' : 'warning'} sx={{ mr: 1 }} />
                  <Typography variant="body2" color="text.secondary" sx={{ mt: 1 }}>
                    {account.setup_notes}
                  </Typography>
                  {account.missing_permissions.length > 0 && (
                    <Typography variant="caption" color="error">
                      Missing permissions: {account.missing_permissions.join(', ')}
                    </Typography>
                  )}
                  {account.last_error && <Alert severity="error" sx={{ mt: 1 }}>{account.last_error}</Alert>}
                </Box>
                <Stack spacing={1}>
                  {(account.provider === 'facebook' || account.provider === 'tiktok') && (
                    <Button variant="contained" disabled={!canManageMarketing} onClick={() => connect(account.provider as 'facebook' | 'tiktok')}>
                      Connect {account.provider}
                    </Button>
                  )}
                  <Button disabled={!canManageMarketing || account.connection_status === 'disconnected'} onClick={() => disconnect(account)}>
                    Disconnect
                  </Button>
                </Stack>
              </Stack>
            </CardContent>
          </Card>
        ))}
      </Stack>
    </Box>
  );
};
