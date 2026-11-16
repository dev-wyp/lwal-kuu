import React, { useEffect, useState } from 'react';
import {
  Alert,
  Box,
  Button,
  Chip,
  Grid,
  MenuItem,
  Paper,
  Stack,
  TextField,
  Typography,
} from '@mui/material';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { useNavigate, useSearchParams } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/lib/supabase';
import { useAuth } from '@/context/AuthContext';
import { useNotification } from '@/context/NotificationContext';
import { useMarketingWorkspace } from '../hooks/useMarketingWorkspace';
import { DEFAULT_CONTENT_PILLARS, FACEBOOK_CONTENT_TYPES, TIKTOK_CONTENT_TYPES } from '../lib/brand';
import { canEditCopy, canSubmitForReview, formatYangon } from '../lib/status';
import { mktRpc } from '../lib/db';
import { buildManualPublishBrief, buildTrialTrackingUrl, downloadTextFile } from '../lib/exportBrief';
import type { ContentAsset, ContentStatus, MarketingContent, SocialPlatform, TikTokScript } from '../types';

const schema = z.object({
  title: z.string().min(4, 'Title is required'),
  platform: z.enum(['facebook', 'tiktok']),
  content_type: z.string().min(2),
  content_pillar: z.string().min(2),
  caption: z.string().min(8, 'Caption must be at least 8 characters'),
  hook: z.string().optional(),
  cta: z.string().optional(),
  hashtags: z.string().optional(),
  image_prompt: z.string().optional(),
  production_brief: z.string().optional(),
});

type FormValues = z.infer<typeof schema>;

export const ContentNewPage: React.FC = () => {
  const [searchParams] = useSearchParams();
  const existingId = searchParams.get('id');
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const { user } = useAuth();
  const { showSuccess, showError } = useNotification();
  const { orgId, data: workspaceData, canApproveMarketing } = useMarketingWorkspace();
  const workspace = workspaceData?.workspace;
  const [aiBusy, setAiBusy] = useState(false);
  const [aiMessage, setAiMessage] = useState<string | null>(null);
  const [aiInstructions, setAiInstructions] = useState('');
  const [script, setScript] = useState<TikTokScript | null>(null);
  const [aiModel, setAiModel] = useState<string | null>(null);
  const [generationMetadata, setGenerationMetadata] = useState<Record<string, unknown>>({});

  const { data: existing } = useQuery({
    queryKey: ['marketing_content', existingId],
    enabled: Boolean(existingId),
    queryFn: async () => {
      const { data, error } = await supabase.from('marketing_contents').select('*').eq('id', existingId as string).single();
      if (error) throw error;
      return data as MarketingContent;
    },
  });

  const { data: assets = [] } = useQuery({
    queryKey: ['content_assets', existingId],
    enabled: Boolean(existingId),
    queryFn: async () => {
      const { data, error } = await supabase.from('content_assets').select('*').eq('content_id', existingId as string);
      if (error) throw error;
      return (data || []) as ContentAsset[];
    },
  });

  const { data: assetUrls = {} } = useQuery({
    queryKey: ['content_asset_urls', existingId, assets.map((asset) => asset.id).join(',')],
    enabled: Boolean(existingId && assets.length),
    queryFn: async () => {
      const entries = await Promise.all(assets.map(async (asset) => {
        if (!asset.storage_path) return [asset.id, asset.file_url] as const;
        const { data, error } = await supabase.storage.from('marketing-assets').createSignedUrl(asset.storage_path, 3600);
        if (error) return [asset.id, null] as const;
        return [asset.id, data.signedUrl] as const;
      }));
      return Object.fromEntries(entries) as Record<string, string | null>;
    },
  });

  const form = useForm<FormValues>({
    resolver: zodResolver(schema),
    defaultValues: {
      title: '',
      platform: 'facebook',
      content_type: 'educational_post',
      content_pillar: 'business_problems',
      caption: '',
      hook: '',
      cta: workspaceData?.settings?.default_cta || 'Start 14-day free trial',
      hashtags: '#ShopFlow #MyanmarBusiness',
      image_prompt: '',
      production_brief: '',
    },
  });

  useEffect(() => {
    if (existing) {
      form.reset({
        title: existing.title,
        platform: existing.platform,
        content_type: existing.content_type,
        content_pillar: existing.content_pillar,
        caption: existing.caption,
        hook: existing.hook || '',
        cta: existing.cta || '',
        hashtags: (existing.hashtags || []).join(' '),
        image_prompt: existing.image_prompt || '',
        production_brief: existing.production_brief || '',
      });
      setScript(existing.video_script);
      setAiModel(existing.ai_model);
      setGenerationMetadata(existing.generation_metadata || {});
    }
  }, [existing, form]);

  const platform = form.watch('platform') as SocialPlatform;
  const types = platform === 'tiktok' ? TIKTOK_CONTENT_TYPES : FACEBOOK_CONTENT_TYPES;
  const status = (existing?.status || 'draft') as ContentStatus;
  const editable = !existing || canEditCopy(status);

  const persist = async (values: FormValues): Promise<string> => {
    if (!orgId || !workspace || !user) throw new Error('Workspace is not ready');
    const payload = {
      workspace_id: workspace.id,
      organization_id: orgId,
      title: values.title,
      platform: values.platform,
      content_type: values.content_type,
      content_pillar: values.content_pillar,
      caption: values.caption,
      hook: values.hook || null,
      cta: values.cta || null,
      hashtags: (values.hashtags || '').split(/[\s,]+/).filter(Boolean),
      image_prompt: values.image_prompt || null,
      production_brief: values.production_brief || null,
      video_script: script ? JSON.parse(JSON.stringify(script)) : null,
      ai_model: aiModel,
      generation_metadata: generationMetadata,
      created_by: user.id,
    };

    if (existingId) {
      const { error } = await supabase.from('marketing_contents').update(payload).eq('id', existingId);
      if (error) throw error;
      return existingId;
    }
    const { data, error } = await supabase.from('marketing_contents').insert({ ...payload, status: 'draft' }).select('id').single();
    if (error) throw error;
    return data.id;
  };

  const onSave = form.handleSubmit(async (values) => {
    try {
      const id = await persist(values);
      showSuccess('Draft saved');
      await queryClient.invalidateQueries({ queryKey: ['marketing_contents'] });
      navigate(`/admin/marketing/content/new?id=${id}`);
    } catch (err) {
      showError(err instanceof Error ? err.message : 'Save failed');
    }
  });

  const onSubmitReview = async () => {
    try {
      const values = form.getValues();
      const id = await persist(values);
      await mktRpc('submit_marketing_content_for_review', { p_content_id: id });
      showSuccess('Submitted for platform review');
      navigate('/admin/marketing/approvals');
    } catch (err) {
      showError(err instanceof Error ? err.message : 'Submit failed');
    }
  };

  const generateWithAi = async () => {
    setAiBusy(true);
    setAiMessage(null);
    try {
      const { data, error } = await supabase.functions.invoke('marketing-ai', {
        body: {
          action: 'generate',
          organization_id: orgId,
          platform: form.getValues('platform'),
          content_type: form.getValues('content_type'),
          content_pillar: form.getValues('content_pillar'),
          title: form.getValues('title'),
          additional_instructions: aiInstructions.slice(0, 1500),
        },
      });
      if (error) throw error;
      if (data?.setup_required) {
        setAiMessage(data.message || 'AI provider is not configured. You can still write copy manually.');
        return;
      }
      if (data?.content) {
        const generated = data.content as Partial<MarketingContent> & { video_script?: TikTokScript };
        form.setValue('title', generated.title || form.getValues('title'));
        form.setValue('caption', generated.caption || '');
        form.setValue('hook', generated.hook || '');
        form.setValue('cta', generated.cta || form.getValues('cta'));
        form.setValue('hashtags', (generated.hashtags || []).join(' '));
        form.setValue('image_prompt', generated.image_prompt || '');
        form.setValue('production_brief', generated.production_brief || '');
        if (generated.video_script) setScript(generated.video_script);
        setAiModel(generated.ai_model || workspaceData?.settings?.ai_model || 'gpt-4o-mini');
        setGenerationMetadata(generated.generation_metadata || {});
        showSuccess('AI draft inserted. Review before submitting.');
      }
    } catch (err) {
      setAiMessage(err instanceof Error ? err.message : 'AI generation is unavailable until the marketing-ai function and API key are configured.');
    } finally {
      setAiBusy(false);
    }
  };

  const uploadAsset = async (file: File) => {
    if (!orgId || !existingId) {
      showError('Save the draft before uploading assets');
      return;
    }
    const path = `${orgId}/${existingId}/${Date.now()}-${file.name}`;
    const { error: uploadError } = await supabase.storage.from('marketing-assets').upload(path, file, { upsert: false });
    if (uploadError) {
      showError(uploadError.message);
      return;
    }
    const { error: assetError } = await supabase.from('content_assets').insert({
      workspace_id: workspace?.id,
      organization_id: orgId,
      content_id: existingId,
      asset_type: file.type.startsWith('video') ? 'video' : 'image',
      storage_path: path,
      file_url: null,
      mime_type: file.type,
      file_size_bytes: file.size,
      created_by: user?.id,
    });
    if (assetError) {
      showError(assetError.message);
      return;
    }
    await queryClient.invalidateQueries({ queryKey: ['content_assets', existingId] });
    showSuccess('Asset uploaded');
  };

  return (
    <Box>
      <Stack direction={{ xs: 'column', md: 'row' }} justifyContent="space-between" sx={{ mb: 2 }} spacing={2}>
        <Box>
          <Typography variant="h6">{existing ? 'Edit content' : 'Create content'}</Typography>
          <Typography variant="body2" color="text.secondary">
            AI drafts stay in review until a platform superadmin approves them.
          </Typography>
        </Box>
        <Stack direction="row" spacing={1}>
          <Button variant="outlined" onClick={generateWithAi} disabled={aiBusy}>
            {aiBusy ? 'Generating…' : 'Generate with AI'}
          </Button>
          {existing && ['approved', 'scheduled', 'failed'].includes(existing.status) && (
            <Button
              variant="outlined"
              onClick={() => {
                const trackingUrl = buildTrialTrackingUrl(window.location.origin, existing);
                downloadTextFile(
                  `${existing.platform}-${existing.id.slice(0, 8)}-publish-brief.txt`,
                  buildManualPublishBrief(existing, trackingUrl)
                );
                showSuccess('Manual publishing brief downloaded');
              }}
            >
              Export brief
            </Button>
          )}
          <Button variant="outlined" onClick={onSave} disabled={!editable}>Save draft</Button>
          <Button
            variant="contained"
            onClick={onSubmitReview}
            disabled={!editable || (existing ? !canSubmitForReview(status) : false)}
          >
            Submit for review
          </Button>
        </Stack>
      </Stack>

      {aiMessage && <Alert severity="warning" sx={{ mb: 2 }}>{aiMessage}</Alert>}
      {existing && (
        <Alert severity="info" sx={{ mb: 2 }}>
          Status: {status}. Created {formatYangon(existing.created_at)}
          {existing.approved_at ? ` · Approved ${formatYangon(existing.approved_at)}` : ''}
          <Typography variant="caption" display="block" sx={{ mt: 1 }}>
            Trial tracking URL: {buildTrialTrackingUrl(window.location.origin, existing)}
          </Typography>
        </Alert>
      )}

      <TextField
        label="Tell your AI what to create"
        placeholder="Example: Write a short Burmese Facebook post for wholesale shop owners about tracking supplier purchases. Keep it practical and friendly."
        value={aiInstructions}
        onChange={(event) => setAiInstructions(event.target.value.slice(0, 1500))}
        helperText={`${aiInstructions.length}/1500 · Optional instructions for this draft`}
        fullWidth
        multiline
        minRows={2}
        disabled={aiBusy}
        sx={{ mb: 2 }}
      />

      <Paper sx={{ p: 3 }}>
        <Grid container spacing={2}>
          <Grid item xs={12} md={8}>
            <TextField label="Title" fullWidth {...form.register('title')} error={Boolean(form.formState.errors.title)} helperText={form.formState.errors.title?.message} disabled={!editable} />
          </Grid>
          <Grid item xs={12} md={4}>
            <TextField select label="Platform" fullWidth value={platform} onChange={(e) => form.setValue('platform', e.target.value as SocialPlatform)} disabled={!editable}>
              <MenuItem value="facebook">Facebook</MenuItem>
              <MenuItem value="tiktok">TikTok</MenuItem>
            </TextField>
          </Grid>
          <Grid item xs={12} md={6}>
            <TextField select label="Content type" fullWidth value={form.watch('content_type')} onChange={(e) => form.setValue('content_type', e.target.value)} disabled={!editable}>
              {types.map((type) => (
                <MenuItem key={type} value={type}>{type}</MenuItem>
              ))}
            </TextField>
          </Grid>
          <Grid item xs={12} md={6}>
            <TextField select label="Content pillar" fullWidth value={form.watch('content_pillar')} onChange={(e) => form.setValue('content_pillar', e.target.value)} disabled={!editable}>
              {DEFAULT_CONTENT_PILLARS.map((pillar) => (
                <MenuItem key={pillar.key} value={pillar.key}>{pillar.label} ({pillar.weight}%)</MenuItem>
              ))}
            </TextField>
          </Grid>
          <Grid item xs={12}>
            <TextField label="Hook" fullWidth {...form.register('hook')} disabled={!editable} />
          </Grid>
          <Grid item xs={12}>
            <TextField label="Caption (Burmese preferred)" fullWidth multiline minRows={5} {...form.register('caption')} error={Boolean(form.formState.errors.caption)} helperText={form.formState.errors.caption?.message} disabled={!editable} />
          </Grid>
          <Grid item xs={12} md={6}>
            <TextField label="CTA" fullWidth {...form.register('cta')} disabled={!editable} />
          </Grid>
          <Grid item xs={12} md={6}>
            <TextField label="Hashtags" fullWidth {...form.register('hashtags')} disabled={!editable} />
          </Grid>
          <Grid item xs={12}>
            <TextField label="Image / design prompt" fullWidth multiline minRows={3} {...form.register('image_prompt')} disabled={!editable} />
          </Grid>
          <Grid item xs={12}>
            <TextField label="Video production brief" fullWidth multiline minRows={3} {...form.register('production_brief')} disabled={!editable} />
          </Grid>
        </Grid>
      </Paper>

      {script && (
        <Paper sx={{ p: 3, mt: 2 }}>
          <Typography variant="subtitle1" fontWeight={700}>TikTok script</Typography>
          <Typography variant="body2" sx={{ mt: 1 }}>{script.opening_hook}</Typography>
          {script.scenes.map((scene) => (
            <Box key={scene.scene} sx={{ mt: 1.5 }}>
              <Chip size="small" label={`Scene ${scene.scene} · ${scene.duration_seconds}s`} />
              <Typography variant="body2">{scene.visual}</Typography>
              <Typography variant="caption">On-screen: {scene.on_screen_text}</Typography>
              <Typography variant="body2">VO: {scene.voice_over}</Typography>
            </Box>
          ))}
        </Paper>
      )}

      <Paper sx={{ p: 3, mt: 2 }}>
        <Typography variant="subtitle1" fontWeight={700} sx={{ mb: 1 }}>Assets</Typography>
        <Button component="label" variant="outlined" disabled={!existingId || !editable}>
          Upload image or video
          <input hidden type="file" accept="image/*,video/*" onChange={(e) => e.target.files && uploadAsset(e.target.files[0])} />
        </Button>
        <Stack spacing={1} sx={{ mt: 2 }}>
          {assets.map((asset) => (
            <Alert key={asset.id} severity="success">
              <Stack spacing={1}>
                <Typography variant="body2">{asset.asset_type}: {asset.storage_path || asset.file_url}</Typography>
                {assetUrls[asset.id] && asset.asset_type === 'image' && (
                  <Box component="img" src={assetUrls[asset.id] || undefined} alt="Marketing creative preview" sx={{ maxWidth: 320, maxHeight: 220, objectFit: 'contain' }} />
                )}
                {assetUrls[asset.id] && asset.asset_type === 'video' && (
                  <Box component="video" src={assetUrls[asset.id] || undefined} controls sx={{ maxWidth: 420, maxHeight: 260 }} />
                )}
                {!assetUrls[asset.id] && <Typography variant="caption">Preview unavailable</Typography>}
              </Stack>
            </Alert>
          ))}
          {assets.length === 0 && <Typography variant="body2" color="text.secondary">No assets yet. Automatic video generation is not assumed; export the script as a production brief if needed.</Typography>}
        </Stack>
      </Paper>

      {canApproveMarketing && existing && (
        <Alert severity="info" sx={{ mt: 2 }}>
          Approvals happen in the Approvals queue. This page will not publish unapproved content.
        </Alert>
      )}
    </Box>
  );
};
