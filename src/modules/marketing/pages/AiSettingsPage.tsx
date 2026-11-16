import React from 'react';
import {
  Alert,
  Box,
  Button,
  Chip,
  CircularProgress,
  MenuItem,
  Stack,
  TextField,
  Typography,
} from '@mui/material';
import { useForm } from 'react-hook-form';
import { z } from 'zod';
import { zodResolver } from '@hookform/resolvers/zod';
import { supabase } from '@/lib/supabase';
import { useNotification } from '@/context/NotificationContext';
import { useMarketingWorkspace } from '../hooks/useMarketingWorkspace';

const schema = z.object({
  brand_tone: z.string().min(2),
  default_cta: z.string().min(2),
  ai_provider: z.enum(['openai', 'gemini']),
  ai_model: z.string().min(2),
});

type FormValues = z.infer<typeof schema>;
type Provider = FormValues['ai_provider'];

export const AiSettingsPage: React.FC = () => {
  const { orgId, data, refetch, isOwnerOrAdmin } = useMarketingWorkspace();
  const { showError, showSuccess } = useNotification();
  const settings = data?.settings;
  const [apiKey, setApiKey] = React.useState('');
  const [keyConfigured, setKeyConfigured] = React.useState(false);
  const [busy, setBusy] = React.useState<'save' | 'test' | 'remove' | null>(null);

  const form = useForm<FormValues>({
    defaultValues: {
      brand_tone: settings?.brand_tone || 'professional_friendly',
      default_cta: settings?.default_cta || 'Start 14-day free trial',
      ai_provider: settings?.ai_provider === 'gemini' ? 'gemini' : 'openai',
      ai_model: settings?.ai_model || (settings?.ai_provider === 'gemini' ? 'gemini-flash-latest' : 'gpt-4o-mini'),
    },
    resolver: zodResolver(schema),
  });
  const provider = form.watch('ai_provider');
  const { reset } = form;

  React.useEffect(() => {
    if (!settings) return;
    reset({
      brand_tone: settings.brand_tone || 'professional_friendly',
      default_cta: settings.default_cta || 'Start 14-day free trial',
      ai_provider: settings.ai_provider === 'gemini' ? 'gemini' : 'openai',
      ai_model: settings.ai_model || (settings.ai_provider === 'gemini' ? 'gemini-flash-latest' : 'gpt-4o-mini'),
    });
  }, [settings, reset]);

  const checkKeyStatus = React.useCallback(async () => {
    const { data: result, error } = await supabase.functions.invoke('marketing-ai', {
      body: { action: 'ai_key_status', provider },
    });
    if (error) throw await readableFunctionError(error);
    setKeyConfigured(Boolean(result?.configured));
  }, [provider]);

  React.useEffect(() => {
    void checkKeyStatus().catch((error) => {
      console.error('Unable to check AI key status:', error);
    });
  }, [checkKeyStatus]);

  const saveSettings = form.handleSubmit(async (values) => {
    if (!settings || !orgId) return;
    setBusy('save');
    try {
      const { error } = await supabase
        .from('marketing_settings')
        .update({
          brand_tone: values.brand_tone,
          default_cta: values.default_cta,
          ai_provider: values.ai_provider,
          ai_model: values.ai_model,
        })
        .eq('workspace_id', settings.workspace_id);
      if (error) throw error;

      if (apiKey.trim()) {
        const { error: keyError } = await supabase.functions.invoke('marketing-ai', {
          body: { action: 'save_ai_key', provider: values.ai_provider, model: values.ai_model, api_key: apiKey.trim() },
        });
        if (keyError) throw await readableFunctionError(keyError);
        setApiKey('');
        setKeyConfigured(true);
      }

      showSuccess('AI settings saved');
      await refetch();
    } catch (error) {
      showError(error instanceof Error ? error.message : 'Unable to save AI settings');
    } finally {
      setBusy(null);
    }
  });

  const testConnection = async () => {
    setBusy('test');
    try {
      const { data: result, error } = await supabase.functions.invoke('marketing-ai', {
        body: {
          action: 'test_ai_key',
          provider,
          model: form.getValues('ai_model'),
          api_key: apiKey.trim() || undefined,
        },
      });
      if (error) throw await readableFunctionError(error);
      if (result?.error) throw new Error(result.error);
      showSuccess(`Connected to ${provider === 'gemini' ? 'Google Gemini' : 'OpenAI'}`);
    } catch (error) {
      showError(error instanceof Error ? error.message : 'AI connection test failed');
    } finally {
      setBusy(null);
    }
  };

  const removeKey = async () => {
    setBusy('remove');
    try {
      const { data: result, error } = await supabase.functions.invoke('marketing-ai', {
        body: { action: 'remove_ai_key', provider },
      });
      if (error) throw await readableFunctionError(error);
      if (result?.error) throw new Error(result.error);
      setKeyConfigured(false);
      setApiKey('');
      showSuccess('Saved provider key removed');
    } catch (error) {
      showError(error instanceof Error ? error.message : 'Unable to remove provider key');
    } finally {
      setBusy(null);
    }
  };

  return (
    <Box>
      <Typography variant="h5" sx={{ fontWeight: 700, mb: 1 }}>Your AI provider</Typography>
      <Alert severity="info" sx={{ mb: 2 }}>
        Add your own Gemini or OpenAI API key. ShopFlow sends it only to the protected Edge Function and stores it encrypted; the key is never returned to the browser. AI runs only when you request content or analysis. Posts still require manual approval.
      </Alert>
      <Stack spacing={2} maxWidth={620}>
        <TextField label="Brand tone" {...form.register('brand_tone')} disabled={!isOwnerOrAdmin || busy !== null} />
        <TextField label="Default call to action" {...form.register('default_cta')} disabled={!isOwnerOrAdmin || busy !== null} />
        <TextField
          select
          label="AI provider"
          value={provider}
          onChange={(event) => {
            const nextProvider = event.target.value as Provider;
            form.setValue('ai_provider', nextProvider, { shouldDirty: true });
            form.setValue('ai_model', nextProvider === 'gemini' ? 'gemini-flash-latest' : 'gpt-4o-mini');
            setApiKey('');
          }}
          disabled={!isOwnerOrAdmin || busy !== null}
        >
          <MenuItem value="gemini">Google Gemini</MenuItem>
          <MenuItem value="openai">OpenAI</MenuItem>
        </TextField>
        <TextField label="Model" {...form.register('ai_model')} disabled={!isOwnerOrAdmin || busy !== null} />
        <TextField
          label={`${provider === 'gemini' ? 'Gemini' : 'OpenAI'} API key`}
          type="password"
          value={apiKey}
          onChange={(event) => setApiKey(event.target.value)}
          autoComplete="new-password"
          placeholder={keyConfigured ? 'Key saved securely. Enter a new key to replace it.' : 'Paste your provider API key'}
          helperText={keyConfigured ? 'A key is saved for this provider. It cannot be viewed again.' : 'Your key is encrypted before storage.'}
          disabled={!isOwnerOrAdmin || busy !== null}
        />
        <Stack direction="row" spacing={1} alignItems="center" flexWrap="wrap">
          <Chip
            size="small"
            color={keyConfigured ? 'success' : 'default'}
            label={keyConfigured ? 'Provider key configured' : 'No saved provider key'}
          />
          {busy && <CircularProgress size={20} />}
        </Stack>
        <Stack direction={{ xs: 'column', sm: 'row' }} spacing={1}>
          <Button variant="contained" onClick={saveSettings} disabled={!isOwnerOrAdmin || busy !== null}>
            Save AI settings{apiKey.trim() ? ' and key' : ''}
          </Button>
          <Button variant="outlined" onClick={testConnection} disabled={!isOwnerOrAdmin || busy !== null}>
            Test connection
          </Button>
          {keyConfigured && (
            <Button color="error" onClick={removeKey} disabled={!isOwnerOrAdmin || busy !== null}>
              Remove saved key
            </Button>
          )}
        </Stack>
        <Typography variant="caption" color="text.secondary">
          Content generation creates drafts for review. Analytics analysis uses stored platform metrics, leads, and recorded advertising spend only. Keep the server-side MARKETING_TOKEN_SECRET stable; changing the encryption secret requires saving provider keys again.
        </Typography>
      </Stack>
    </Box>
  );
};

async function readableFunctionError(error: Error & { context?: unknown }): Promise<Error> {
  if (error.context instanceof Response) {
    try {
      const payload = await error.context.clone().json() as { error?: string };
      if (payload.error) return new Error(payload.error);
    } catch {
      // Fall back to the Functions client message when the response is not JSON.
    }
  }
  return new Error(error.message);
}
