import React, { useState } from 'react';
import { Alert, Box, Button, CircularProgress, MenuItem, Paper, Table, TableBody, TableCell, TableContainer, TableHead, TableRow, TextField, Typography } from '@mui/material';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/lib/supabase';
import { useNotification } from '@/context/NotificationContext';
import { useI18n } from '@/i18n/I18nContext';

export const SupportTicketsPage: React.FC = () => {
  const { t } = useI18n();
  const { showError, showSuccess } = useNotification();
  const queryClient = useQueryClient();
  const [responses, setResponses] = useState<Record<string, string>>({});
  const { data: tickets = [], isLoading, isError } = useQuery({
    queryKey: ['platform_support_tickets'],
    queryFn: async () => {
      const { data, error } = await supabase.from('support_tickets' as any)
        .select('*,organizations(name)').order('created_at', { ascending: false });
      if (error) throw error;
      return data ?? [];
    },
  });
  const statusMutation = useMutation({
    mutationFn: async ({ id, status }: { id: string; status: string }) => {
      const { error } = await supabase.from('support_tickets' as any).update({ status, updated_at: new Date().toISOString() }).eq('id', id);
      if (error) throw error;
    },
    onSuccess: async () => {
      showSuccess(t('Support request updated.'));
      await queryClient.invalidateQueries({ queryKey: ['platform_support_tickets'] });
    },
    onError: (error) => showError(error.message || t('Could not update support request.')),
  });
  const responseMutation = useMutation({
    mutationFn: async ({ id, response }: { id: string; response: string }) => {
      const { error } = await supabase.from('support_tickets' as any)
        .update({ response: response.trim(), responded_at: new Date().toISOString(), updated_at: new Date().toISOString() }).eq('id', id);
      if (error) throw error;
    },
    onSuccess: async () => {
      showSuccess(t('Support response sent.'));
      await queryClient.invalidateQueries({ queryKey: ['platform_support_tickets'] });
    },
    onError: (error) => showError(error.message || t('Could not send support response.')),
  });
  return <Box>
    <Typography variant="h4" fontWeight={800} sx={{ mb: 1 }}>{t('Priority Support Requests')}</Typography>
    <Typography color="text.secondary" sx={{ mb: 3 }}>{t('Review and update requests submitted by Pro organizations.')}</Typography>
    {isError && <Alert severity="error">{t('Support requests could not be loaded.')}</Alert>}
    <Paper sx={{ border: '1px solid #e2e8f0' }}>
      <TableContainer><Table>
        <TableHead><TableRow>
          <TableCell>{t('Organization')}</TableCell><TableCell>{t('Subject')}</TableCell><TableCell>{t('Request')}</TableCell><TableCell>{t('Submitted')}</TableCell><TableCell>{t('Status')}</TableCell>
        </TableRow></TableHead>
        <TableBody>
          {isLoading ? <TableRow><TableCell colSpan={5} align="center"><CircularProgress size={26} /></TableCell></TableRow>
            : tickets.length === 0 ? <TableRow><TableCell colSpan={5} align="center">{t('No support requests yet.')}</TableCell></TableRow>
              : tickets.map((ticket: any) => <TableRow key={ticket.id} hover>
                <TableCell>{ticket.organizations?.name ?? '—'}</TableCell>
                <TableCell>{ticket.subject}</TableCell>
                <TableCell sx={{ minWidth: 280, maxWidth: 480, whiteSpace: 'pre-wrap' }}>
                  {ticket.description}
                  {ticket.response && <Typography variant="body2" sx={{ mt: 1, p: 1, bgcolor: '#f1f5f9', borderRadius: 1 }}><strong>{t('Response')}:</strong> {ticket.response}</Typography>}
                  <TextField fullWidth multiline minRows={2} size="small" label={t('Reply to customer')} sx={{ mt: 1 }}
                    value={responses[ticket.id] ?? ticket.response ?? ''} onChange={(event) => setResponses((current) => ({ ...current, [ticket.id]: event.target.value }))} />
                  <Button size="small" sx={{ mt: 0.5 }} disabled={responseMutation.isPending || !(responses[ticket.id] ?? ticket.response ?? '').trim()}
                    onClick={() => responseMutation.mutate({ id: ticket.id, response: responses[ticket.id] ?? ticket.response ?? '' })}>{t('Send response')}</Button>
                </TableCell>
                <TableCell>{new Date(ticket.created_at).toLocaleString()}</TableCell>
                <TableCell><TextField select size="small" value={ticket.status} disabled={statusMutation.isPending} onChange={(event) => statusMutation.mutate({ id: ticket.id, status: event.target.value })}>
                  {['open','in_progress','resolved','closed'].map((status) => <MenuItem key={status} value={status}>{t(status)}</MenuItem>)}
                </TextField></TableCell>
              </TableRow>)}
        </TableBody>
      </Table></TableContainer>
    </Paper>
  </Box>;
};
