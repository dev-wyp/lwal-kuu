import React from 'react';
import {
  Alert,
  Box,
  Button,
  MenuItem,
  Stack,
  Table,
  TableContainer,
  TableBody,
  TableCell,
  TableHead,
  TableRow,
  TextField,
  Typography,
} from '@mui/material';
import { useForm } from 'react-hook-form';
import { z } from 'zod';
import { zodResolver } from '@hookform/resolvers/zod';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/lib/supabase';
import { useNotification } from '@/context/NotificationContext';
import { useMarketingWorkspace } from '../hooks/useMarketingWorkspace';
import type { LeadStatus, MarketingLead } from '../types';
import { useI18n } from '@/i18n/I18nContext';

const schema = z.object({
  full_name: z.string().min(2),
  email: z.string().email().optional().or(z.literal('')),
  phone: z.string().optional(),
  business_type: z.string().optional(),
  source_platform: z.enum(['facebook', 'tiktok', 'website', 'landing', 'manual', 'other']),
});

type FormValues = z.infer<typeof schema>;

export const LeadsPage: React.FC = () => {
  const { t } = useI18n();
  const { orgId, data: workspaceData, canManageMarketing } = useMarketingWorkspace();
  const { showError, showSuccess } = useNotification();
  const queryClient = useQueryClient();

  const { data = [], error } = useQuery({
    queryKey: ['marketing_leads', orgId],
    enabled: Boolean(orgId),
    queryFn: async () => {
      const { data: rows, error: qError } = await supabase
        .from('marketing_leads')
        .select('*')
        .eq('organization_id', orgId as string)
        .order('created_at', { ascending: false });
      if (qError) throw qError;
      return (rows || []) as MarketingLead[];
    },
  });

  const form = useForm<FormValues>({
    resolver: zodResolver(schema),
    defaultValues: { full_name: '', email: '', source_platform: 'manual' },
  });

  const createLead = form.handleSubmit(async (values) => {
    const { error: insertError } = await supabase.from('marketing_leads').insert({
      workspace_id: workspaceData?.workspace.id,
      organization_id: orgId,
      full_name: values.full_name,
      email: values.email || null,
      phone: values.phone || null,
      business_type: values.business_type || null,
      source_platform: values.source_platform,
      status: 'new',
    });
    if (insertError) {
      showError(insertError.message);
      return;
    }
    showSuccess('Lead saved');
    form.reset();
    await queryClient.invalidateQueries({ queryKey: ['marketing_leads'] });
  });

  const updateStatus = async (id: string, status: LeadStatus) => {
    const patch: Record<string, unknown> = { status };
    if (status === 'trial_registered') patch.trial_signup_at = new Date().toISOString();
    if (status === 'converted') patch.converted_at = new Date().toISOString();
    const { error: updateError } = await supabase.from('marketing_leads').update(patch).eq('id', id);
    if (updateError) showError(updateError.message);
    else await queryClient.invalidateQueries({ queryKey: ['marketing_leads'] });
  };

  return (
    <Box>
      <Typography variant="h6" sx={{ mb: 2 }}>Leads and trial registrations</Typography>
      {error && <Alert severity="error">{error instanceof Error ? error.message : 'Failed to load leads'}</Alert>}
      <Stack direction={{ xs: 'column', lg: 'row' }} spacing={2} sx={{ mb: 3 }}>
        <TextField fullWidth label={t("Name")} {...form.register('full_name')} />
        <TextField fullWidth label={t("Email")} {...form.register('email')} />
        <TextField fullWidth label="Business type" {...form.register('business_type')} />
        <TextField fullWidth select label="Source" value={form.watch('source_platform')} onChange={(e) => form.setValue('source_platform', e.target.value as FormValues['source_platform'])} sx={{ minWidth: { xs: 0, lg: 140 } }}>
          {['manual', 'website', 'landing', 'facebook', 'tiktok', 'other'].map((s) => (
            <MenuItem key={s} value={s}>{s}</MenuItem>
          ))}
        </TextField>
        <Button variant="contained" onClick={createLead} disabled={!canManageMarketing} sx={{ flexShrink: 0 }}>Add lead</Button>
      </Stack>
      {data.length === 0 && <Alert severity="info">No leads yet. Trial signups with UTM parameters appear here after onboarding.</Alert>}
      {data.length > 0 && (
        <TableContainer>
        <Table size="small" sx={{ minWidth: 640 }}>
          <TableHead>
            <TableRow>
              <TableCell>{t("Name")}</TableCell>
              <TableCell>Source</TableCell>
              <TableCell>UTM</TableCell>
              <TableCell>{t("Status")}</TableCell>
              <TableCell />
            </TableRow>
          </TableHead>
          <TableBody>
            {data.map((lead) => (
              <TableRow key={lead.id}>
                <TableCell>
                  {lead.full_name || '—'}
                  <Typography variant="caption" display="block">{lead.email}</Typography>
                </TableCell>
                <TableCell>{lead.source_platform}</TableCell>
                <TableCell>{[lead.utm_source, lead.utm_medium, lead.utm_campaign].filter(Boolean).join(' / ') || '—'}</TableCell>
                <TableCell>
                  <TextField
                    select
                    size="small"
                    value={lead.status}
                    onChange={(e) => updateStatus(lead.id, e.target.value as LeadStatus)}
                  >
                    {['new', 'contacted', 'interested', 'trial_registered', 'converted', 'not_interested'].map((s) => (
                      <MenuItem key={s} value={s}>{s}</MenuItem>
                    ))}
                  </TextField>
                </TableCell>
                <TableCell>{lead.content_id ? `content ${lead.content_id.slice(0, 8)}` : ''}</TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
        </TableContainer>
      )}
    </Box>
  );
};
