import React, { useState } from 'react';
import { Alert, Box, Button, CircularProgress, Grid, Paper, TextField, Typography } from '@mui/material';
import SupportAgentIcon from '@mui/icons-material/SupportAgent';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/lib/supabase';
import { useOrg } from '@/context/OrgContext';
import { useAuth } from '@/context/AuthContext';
import { useNotification } from '@/context/NotificationContext';
import { useI18n } from '@/i18n/I18nContext';

export const SupportPage: React.FC = () => {
  const { t } = useI18n();
  const { currentOrg } = useOrg();
  const { user } = useAuth();
  const { showSuccess, showError } = useNotification();
  const queryClient = useQueryClient();
  const [subject, setSubject] = useState('');
  const [description, setDescription] = useState('');
  const [saving, setSaving] = useState(false);
  const orgId = currentOrg?.id;

  const { data: tickets = [], isLoading, isError } = useQuery({
    queryKey: ['support_tickets', orgId],
    enabled: Boolean(orgId),
    queryFn: async () => {
      const { data, error } = await supabase.from('support_tickets' as any).select('*')
        .eq('organization_id', orgId).order('created_at', { ascending: false });
      if (error) throw error;
      return data ?? [];
    },
  });

  const submit = async (event: React.FormEvent) => {
    event.preventDefault();
    if (!orgId || !user?.id || !subject.trim() || !description.trim()) return;
    setSaving(true);
    try {
      const { error } = await supabase.from('support_tickets' as any).insert({
        organization_id: orgId,
        created_by: user.id,
        subject: subject.trim(),
        description: description.trim(),
        priority: 'priority',
      });
      if (error) throw error;
      setSubject('');
      setDescription('');
      showSuccess(t('Priority support request submitted.'));
      await queryClient.invalidateQueries({ queryKey: ['support_tickets', orgId] });
    } catch (error: any) {
      showError(error.message || t('Could not submit support request.'));
    } finally {
      setSaving(false);
    }
  };

  return <Box>
    <Box sx={{ display: 'flex', alignItems: 'center', gap: 1, mb: 1 }}>
      <SupportAgentIcon color="primary" />
      <Typography variant="h4" fontWeight={800}>{t('Priority Support')}</Typography>
    </Box>
    <Typography color="text.secondary" sx={{ mb: 3 }}>{t('Submit a support request and follow its status.')}</Typography>
    <Paper component="form" onSubmit={submit} sx={{ p: 3, mb: 3, border: '1px solid #e2e8f0' }}>
      <Grid container spacing={2}>
        <Grid item xs={12}><TextField fullWidth required label={t('Subject')} value={subject} onChange={(event) => setSubject(event.target.value)} inputProps={{ maxLength: 180 }} /></Grid>
        <Grid item xs={12}><TextField fullWidth required multiline minRows={5} label={t('How can we help?')} value={description} onChange={(event) => setDescription(event.target.value)} inputProps={{ maxLength: 10000 }} /></Grid>
        <Grid item xs={12}><Button type="submit" variant="contained" disabled={saving || !subject.trim() || !description.trim()}>{saving ? <CircularProgress size={20} /> : t('Submit priority request')}</Button></Grid>
      </Grid>
    </Paper>
    {isError && <Alert severity="error" sx={{ mb: 2 }}>{t('Support requests could not be loaded.')}</Alert>}
    <Typography variant="h6" fontWeight={700} sx={{ mb: 1.5 }}>{t('Your requests')}</Typography>
    {isLoading ? <CircularProgress /> : tickets.length === 0 ? <Typography color="text.secondary">{t('No support requests yet.')}</Typography> : <Grid container spacing={2}>
      {tickets.map((ticket: any) => <Grid item xs={12} key={ticket.id}>
        <Paper sx={{ p: 2.5, border: '1px solid #e2e8f0' }}>
          <Box sx={{ display: 'flex', justifyContent: 'space-between', gap: 2, flexWrap: 'wrap' }}>
            <Typography fontWeight={700}>{ticket.subject}</Typography>
            <Typography variant="body2" color="text.secondary">{t(ticket.status)} · {new Date(ticket.created_at).toLocaleString()}</Typography>
          </Box>
          <Typography sx={{ mt: 1, whiteSpace: 'pre-wrap' }}>{ticket.description}</Typography>
          {ticket.response && <Alert severity="info" sx={{ mt: 1.5 }}><Typography variant="subtitle2">{t('Support response')} · {ticket.responded_at ? new Date(ticket.responded_at).toLocaleString() : ''}</Typography><Typography sx={{ whiteSpace: 'pre-wrap' }}>{ticket.response}</Typography></Alert>}
        </Paper>
      </Grid>)}
    </Grid>}
  </Box>;
};
