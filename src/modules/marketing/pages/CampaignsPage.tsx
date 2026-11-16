import React, { useState } from 'react';
import {
  Alert,
  Box,
  Button,
  Card,
  CardContent,
  Grid,
  MenuItem,
  Stack,
  TextField,
  Typography,
} from '@mui/material';
import { useForm } from 'react-hook-form';
import { z } from 'zod';
import { zodResolver } from '@hookform/resolvers/zod';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/lib/supabase';
import { useNavigate } from 'react-router-dom';
import { useAuth } from '@/context/AuthContext';
import { useNotification } from '@/context/NotificationContext';
import { useMarketingWorkspace } from '../hooks/useMarketingWorkspace';
import type { ContentCampaign, ContentIdea, SocialPlatform } from '../types';
import { useI18n } from '@/i18n/I18nContext';

const campaignSchema = z.object({
  name: z.string().min(3),
  objective: z.string().min(3),
  platform: z.enum(['facebook', 'tiktok', 'both']),
  start_date: z.string().optional(),
  end_date: z.string().optional(),
  notes: z.string().optional(),
});

const plannerSchema = z.object({
  objective: z.string().min(3),
  audience: z.string().min(3),
  platform: z.enum(['facebook', 'tiktok', 'both']),
  format: z.string().min(2),
  period: z.string().min(2),
  posts: z.coerce.number().min(1).max(30),
  tone: z.string().min(2),
  cta: z.string().min(2),
});

type CampaignForm = z.infer<typeof campaignSchema>;
type PlannerForm = z.infer<typeof plannerSchema>;

export const CampaignsPage: React.FC = () => {
  const { t } = useI18n();
  const { orgId, data: workspaceData, canManageMarketing } = useMarketingWorkspace();
  const { user } = useAuth();
  const { showError, showSuccess } = useNotification();
  const queryClient = useQueryClient();
  const navigate = useNavigate();
  const [plannerMsg, setPlannerMsg] = useState<string | null>(null);

  const { data: campaigns = [] } = useQuery({
    queryKey: ['content_campaigns', orgId],
    enabled: Boolean(orgId),
    queryFn: async () => {
      const { data, error } = await supabase.from('content_campaigns').select('*').eq('organization_id', orgId as string).order('created_at', { ascending: false });
      if (error) throw error;
      return (data || []) as ContentCampaign[];
    },
  });

  const { data: ideas = [] } = useQuery({
    queryKey: ['content_ideas', orgId],
    enabled: Boolean(orgId),
    queryFn: async () => {
      const { data, error } = await supabase.from('content_ideas').select('*').eq('organization_id', orgId as string).order('created_at', { ascending: false }).limit(40);
      if (error) throw error;
      return (data || []) as ContentIdea[];
    },
  });

  const campaignForm = useForm<CampaignForm>({
    resolver: zodResolver(campaignSchema),
    defaultValues: { name: '', objective: 'Free trial registrations', platform: 'both' },
  });

  const plannerForm = useForm<PlannerForm>({
    resolver: zodResolver(plannerSchema),
    defaultValues: {
      objective: 'Free trial registrations',
      audience: 'Wholesale and retail shop owners in Myanmar',
      platform: 'both',
      format: 'facebook_post_and_tiktok_script',
      period: 'next 7 days',
      posts: 7,
      tone: 'professional_friendly',
      cta: workspaceData?.settings?.default_cta || 'Start 14-day free trial',
    },
  });

  const createCampaign = campaignForm.handleSubmit(async (values) => {
    if (!orgId || !workspaceData?.workspace) return;
    const { error } = await supabase.from('content_campaigns').insert({
      workspace_id: workspaceData.workspace.id,
      organization_id: orgId,
      name: values.name,
      objective: values.objective,
      platform: values.platform,
      start_date: values.start_date || null,
      end_date: values.end_date || null,
      notes: values.notes || null,
      created_by: user?.id,
      status: 'draft',
    });
    if (error) {
      showError(error.message);
      return;
    }
    showSuccess('Campaign created');
    campaignForm.reset();
    await queryClient.invalidateQueries({ queryKey: ['content_campaigns'] });
  });

  const convertIdea = async (idea: ContentIdea) => {
    if (!orgId || !workspaceData?.workspace || !user) return;
    const platform: SocialPlatform = idea.recommended_platform === 'tiktok' ? 'tiktok' : 'facebook';
    const { data, error } = await supabase
      .from('marketing_contents')
      .insert({
        workspace_id: workspaceData.workspace.id,
        organization_id: orgId,
        campaign_id: idea.campaign_id,
        idea_id: idea.id,
        title: idea.topic,
        platform,
        content_type: platform === 'tiktok' ? 'short_video_script' : 'educational_post',
        content_pillar: idea.content_pillar,
        caption: idea.caption_concept || idea.topic,
        hook: idea.hook,
        cta: idea.cta || workspaceData.settings?.default_cta || 'Start 14-day free trial',
        hashtags: ['#ShopFlow', '#MyanmarBusiness'],
        status: 'draft',
        created_by: user.id,
      })
      .select('id')
      .single();
    if (error || !data) {
      showError(error?.message || 'Could not create draft');
      return;
    }
    await supabase.from('content_ideas').update({ status: 'converted' }).eq('id', idea.id);
    await queryClient.invalidateQueries({ queryKey: ['content_ideas'] });
    await queryClient.invalidateQueries({ queryKey: ['marketing_contents'] });
    showSuccess('Draft created from idea. Review copy before submitting.');
    navigate(`/admin/marketing/content/new?id=${data.id}`);
  };

  const runPlanner = plannerForm.handleSubmit(async (values) => {
    setPlannerMsg(null);
    try {
      const { data, error } = await supabase.functions.invoke('marketing-ai', {
        body: {
          action: 'plan',
          organization_id: orgId,
          ...values,
        },
      });
      if (error) throw error;
      if (data?.setup_required) {
        setPlannerMsg(data.message);
        return;
      }
      showSuccess(`Planner created ${data?.created ?? 0} ideas. Expected outcomes are objectives, not guarantees.`);
      await queryClient.invalidateQueries({ queryKey: ['content_ideas'] });
    } catch (err) {
      setPlannerMsg(err instanceof Error ? err.message : 'Planner unavailable until the AI function and API key are configured.');
    }
  });

  return (
    <Box>
      <Grid container spacing={2}>
        <Grid item xs={12} md={5}>
          <Card>
            <CardContent>
              <Typography variant="h6">New campaign</Typography>
              <Stack spacing={2} sx={{ mt: 2 }}>
                <TextField label={t("Name")} {...campaignForm.register('name')} disabled={!canManageMarketing} />
                <TextField label="Objective" {...campaignForm.register('objective')} disabled={!canManageMarketing} />
                <TextField select label="Platform" value={campaignForm.watch('platform')} onChange={(e) => campaignForm.setValue('platform', e.target.value as CampaignForm['platform'])} disabled={!canManageMarketing}>
                  <MenuItem value="both">Facebook and TikTok</MenuItem>
                  <MenuItem value="facebook">Facebook</MenuItem>
                  <MenuItem value="tiktok">TikTok</MenuItem>
                </TextField>
                <Button variant="contained" onClick={createCampaign} disabled={!canManageMarketing}>Save campaign</Button>
              </Stack>
            </CardContent>
          </Card>
        </Grid>
        <Grid item xs={12} md={7}>
          <Card>
            <CardContent>
              <Typography variant="h6">AI marketing planner</Typography>
              <Typography variant="body2" color="text.secondary">
                Ideas include topic, pain point, hook, and expected objective. They never invent testimonials or statistics.
              </Typography>
              <Stack spacing={2} sx={{ mt: 2 }}>
                <TextField label="Objective" {...plannerForm.register('objective')} />
                <TextField label="Audience" {...plannerForm.register('audience')} />
                <TextField label="Format" {...plannerForm.register('format')} />
                <TextField label="Period" {...plannerForm.register('period')} />
                <TextField type="number" label="Number of posts" {...plannerForm.register('posts')} />
                <Button variant="outlined" onClick={runPlanner}>Generate weekly ideas</Button>
                {plannerMsg && <Alert severity="warning">{plannerMsg}</Alert>}
              </Stack>
            </CardContent>
          </Card>
        </Grid>
      </Grid>

      <Typography variant="h6" sx={{ mt: 3, mb: 1 }}>Campaigns</Typography>
      {campaigns.length === 0 && <Alert severity="info">No campaigns yet.</Alert>}
      <Stack spacing={1}>
        {campaigns.map((campaign) => (
          <Alert key={campaign.id} severity="success">
            {campaign.name} · {campaign.platform} · {campaign.objective}
          </Alert>
        ))}
      </Stack>

      <Typography variant="h6" sx={{ mt: 3, mb: 1 }}>Content ideas</Typography>
      {ideas.length === 0 && <Alert severity="info">No ideas generated yet.</Alert>}
      <Grid container spacing={2}>
        {ideas.map((idea) => (
          <Grid item xs={12} md={6} key={idea.id}>
            <Card>
              <CardContent>
                <Typography fontWeight={700}>{idea.topic}</Typography>
                <Typography variant="caption">{idea.recommended_platform} · {idea.content_pillar}</Typography>
                <Typography variant="body2" sx={{ mt: 1 }}>{idea.pain_point}</Typography>
                <Typography variant="body2">Hook: {idea.hook}</Typography>
                <Typography variant="body2">Expected objective: {idea.expected_objective}</Typography>
                <Button size="small" sx={{ mt: 1 }} disabled={!canManageMarketing || idea.status === 'converted'} onClick={() => convertIdea(idea)}>
                  {idea.status === 'converted' ? 'Already converted' : 'Create draft'}
                </Button>
              </CardContent>
            </Card>
          </Grid>
        ))}
      </Grid>
    </Box>
  );
};
