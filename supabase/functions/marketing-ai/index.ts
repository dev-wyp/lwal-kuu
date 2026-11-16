import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { corsHeaders, jsonResponse } from "../_shared/cors.ts";
import { requirePlatformAdmin, serviceClient } from "../_shared/supabase.ts";
import { PROMPTS } from "../_shared/prompts.ts";
import { decryptSecret, encryptSecret } from "../_shared/crypto.ts";

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const { user, admin } = await requirePlatformAdmin(req);
    const body = await req.json();
    const action = body.action as string;
    if (["ai_key_status", "save_ai_key", "test_ai_key", "remove_ai_key"].includes(action)) {
      return await handleAiKeyAction(admin, user.id, body);
    }

    const organizationId = body.organization_id as string;
    if (!organizationId) {
      return jsonResponse({ error: "Select an active marketing workspace in the ShopFlow superadmin dashboard and try again." }, 400);
    }

    const { data: workspace } = await admin
      .from("marketing_workspaces")
      .select("*")
      .eq("organization_id", organizationId)
      .single();
    if (!workspace) return jsonResponse({ error: "Marketing workspace missing" }, 404);

    const { data: settings } = await admin
      .from("marketing_settings")
      .select("*")
      .eq("workspace_id", workspace.id)
      .maybeSingle();

    let provider = resolveProvider(settings?.ai_provider);
    let model = resolveModel(provider, settings?.ai_model);
    let apiKey = await getAiKey(admin, provider);
    if (!apiKey) {
      const fallbackProvider = provider === "gemini" ? "openai" : "gemini";
      const fallbackKey = await getAiKey(admin, fallbackProvider);
      if (fallbackKey) {
        provider = fallbackProvider;
        model = resolveModel(provider, undefined);
        apiKey = fallbackKey;
      }
    }
    if (!apiKey) {
      return jsonResponse({
        setup_required: true,
        message: "Configure your own Gemini or OpenAI API key in Marketing → AI settings. Manual drafting still works.",
      });
    }

    if (action === "generate") {
      const promptName = body.platform === "tiktok" ? "tiktok" : body.platform === "facebook" ? "facebook" : "burmese_copy";
      const generated = await completeJson(provider, model, PROMPTS[promptName], JSON.stringify(body), apiKey);
      await logAi(admin, workspace.id, organizationId, user.id, "generate", promptName, provider, model, generated.usage, true);
      return jsonResponse({
        content: {
          ...generated.json,
          ai_model: model,
          generation_metadata: { provider, model, usage: generated.usage },
        },
      });
    }

    if (action === "plan") {
      const generated = await completeJson(provider, model, PROMPTS.strategy, JSON.stringify(body), apiKey);
      const ideas = Array.isArray(generated.json.ideas) ? generated.json.ideas : [];
      let created = 0;
      for (const idea of ideas) {
        const { error } = await admin.from("content_ideas").insert({
          workspace_id: workspace.id,
          organization_id: organizationId,
          topic: idea.topic,
          target_audience: idea.target_audience,
          pain_point: idea.pain_point,
          hook: idea.hook,
          content_angle: idea.content_angle,
          caption_concept: idea.caption_concept,
          cta: idea.cta,
          recommended_platform: idea.recommended_platform,
          recommended_format: idea.recommended_format,
          content_pillar: idea.content_pillar || "educational",
          suggested_publish_at: idea.suggested_publish_at,
          expected_objective: idea.expected_objective,
          generation_metadata: { provider, model, usage: generated.usage },
        });
        if (!error) created += 1;
      }
      await logAi(admin, workspace.id, organizationId, user.id, "plan", "strategy", provider, model, generated.usage, true);
      return jsonResponse({ created, ideas });
    }

    if (action === "report") {
      const reportType = body.report_type === "monthly" ? "monthly" : "weekly";
      const period = reportWindow(reportType);
      const metrics = await collectReportMetrics(admin, organizationId, workspace.id, period.start, period.end);
      const generated = await completeJson(
        provider,
        model,
        PROMPTS.weekly_analysis,
        JSON.stringify({ reportType, period, metrics }),
        apiKey,
      );
      const summary = generated.json;
      const { error } = await admin.from("marketing_reports").upsert({
        workspace_id: workspace.id,
        organization_id: organizationId,
        report_type: reportType,
        period_start: period.start,
        period_end: period.end,
        status: metrics.has_analytics ? "ready" : "insufficient_data",
        summary,
        generated_by: user.id,
      }, { onConflict: "workspace_id,report_type,period_start,period_end" });
      if (error) throw error;
      await admin.from("marketing_notifications").insert({
        workspace_id: workspace.id,
        organization_id: organizationId,
        notification_type: "weekly_report",
        title: `${reportType} marketing report ready`,
        body: "A report was generated from stored metrics only.",
        entity_type: "marketing_reports",
      });
      await logAi(admin, workspace.id, organizationId, user.id, "report", "weekly_analysis", provider, model, generated.usage, true);
      return jsonResponse({ summary, period });
    }

    if (action === "analyze_analytics") {
      const days = [7, 30, 90].includes(Number(body.days)) ? Number(body.days) : 30;
      const period = reportWindow("custom", days);
      const metrics = await collectReportMetrics(admin, organizationId, workspace.id, period.start, period.end);
      const analysis = await completeJson(
        provider,
        model,
        PROMPTS.analytics_analysis,
        JSON.stringify({ period, metrics }),
        apiKey,
      );
      await logAi(admin, workspace.id, organizationId, user.id, "analytics", "analytics_analysis", provider, model, analysis.usage, true);
      return jsonResponse({ analysis: analysis.json, period, model: `${provider}/${model}` });
    }

    if (action === "review") {
      const generated = await completeJson(provider, model, PROMPTS.quality_review, JSON.stringify(body.content || {}), apiKey);
      return jsonResponse(generated.json);
    }

    return jsonResponse({ error: "Unknown action" }, 400);
  } catch (err) {
    return jsonResponse({ error: err instanceof Error ? err.message : "AI request failed" }, 400);
  }
});

type AIProvider = "openai" | "gemini";
type TokenUsage = { prompt_tokens?: number; completion_tokens?: number };

async function handleAiKeyAction(
  admin: ReturnType<typeof serviceClient>,
  userId: string,
  body: Record<string, unknown>,
) {
  const provider = body.provider === "gemini" ? "gemini" : body.provider === "openai" ? "openai" : null;
  if (!provider) return jsonResponse({ error: "Choose Gemini or OpenAI" }, 400);

  if (body.action === "ai_key_status") {
    const { data, error } = await admin.from("platform_ai_credentials")
      .select("provider").eq("provider", provider).maybeSingle();
    if (error) throw error;
    return jsonResponse({ configured: Boolean(data), provider });
  }

  if (body.action === "remove_ai_key") {
    const { error } = await admin.from("platform_ai_credentials").delete().eq("provider", provider);
    if (error) throw error;
    return jsonResponse({ configured: false, provider });
  }

  const suppliedKey = typeof body.api_key === "string" ? body.api_key.trim() : "";
  if (suppliedKey.length > 512) return jsonResponse({ error: "API key is too long" }, 400);
  const apiKey = suppliedKey || await getAiKey(admin, provider);
  if (!apiKey) return jsonResponse({ error: "Enter an API key first" }, 400);
  const model = typeof body.model === "string" && body.model.trim()
    ? body.model.trim()
    : provider === "gemini" ? "gemini-flash-latest" : "gpt-4o-mini";

  if (body.action === "test_ai_key") {
    await completeJson(provider, model, `Return only JSON: {"connected":true}.`, "Test API connection", apiKey);
    return jsonResponse({ ok: true, provider, model });
  }

  if (body.action === "save_ai_key") {
    const { error } = await admin.from("platform_ai_credentials").upsert({
      provider,
      api_key_encrypted: await encryptSecret(apiKey),
      configured_by: userId,
      updated_at: new Date().toISOString(),
    }, { onConflict: "provider" });
    if (error) throw error;
    return jsonResponse({ configured: true, provider });
  }

  return jsonResponse({ error: "Unknown AI key action" }, 400);
}

async function getAiKey(admin: ReturnType<typeof serviceClient>, provider: AIProvider): Promise<string | null> {
  const { data, error } = await admin.from("platform_ai_credentials")
    .select("api_key_encrypted").eq("provider", provider).maybeSingle();
  if (error) throw error;
  if (data?.api_key_encrypted) return await decryptSecret(data.api_key_encrypted);
  return Deno.env.get(provider === "gemini" ? "GEMINI_API_KEY" : "OPENAI_API_KEY") || null;
}

function resolveProvider(configuredProvider: string | undefined): AIProvider {
  if (configuredProvider === "gemini") return "gemini";
  if (configuredProvider === "openai") return "openai";
  if (Deno.env.get("GEMINI_API_KEY")) return "gemini";
  if (Deno.env.get("OPENAI_API_KEY")) return "openai";
  return configuredProvider === "gemini" ? "gemini" : "openai";
}

function resolveModel(provider: AIProvider, configuredModel: string | undefined): string {
  const fallback = provider === "gemini" ? "gemini-flash-latest" : "gpt-4o-mini";
  if (!configuredModel) return fallback;
  if (provider === "gemini" && /^(gpt-|claude-)/i.test(configuredModel)) return fallback;
  if (provider === "openai" && /^gemini-/i.test(configuredModel)) return fallback;
  return configuredModel;
}

async function completeJson(provider: AIProvider, model: string, system: string, user: string, apiKey: string) {
  const res = provider === "gemini"
    ? await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:generateContent`, {
        method: "POST",
        headers: {
          "x-goog-api-key": apiKey,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          systemInstruction: { parts: [{ text: system }] },
          contents: [{ role: "user", parts: [{ text: user }] }],
          generationConfig: { temperature: 0.4, responseMimeType: "application/json" },
        }),
      })
    : await fetch("https://api.openai.com/v1/chat/completions", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${apiKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          model,
          temperature: 0.4,
          response_format: { type: "json_object" },
          messages: [
            { role: "system", content: system },
            { role: "user", content: user },
          ],
        }),
      });
  const payload: unknown = await res.json();
  const root = asRecord(payload);
  if (!res.ok) {
    const providerError = asRecord(root?.error);
    const message = typeof providerError?.message === "string"
      ? providerError.message
      : typeof providerError?.status === "string" ? providerError.status : `${provider} request failed (${res.status})`;
    throw new Error(message);
  }
  const text = provider === "gemini" ? geminiText(root) : openAiText(root);
  if (!text) throw new Error(`${provider} returned no generated content`);
  const json: unknown = JSON.parse(text);
  if (!json || typeof json !== "object" || Array.isArray(json)) {
    throw new Error(`${provider} returned invalid JSON`);
  }
  const usage = provider === "gemini" ? geminiUsage(root) : openAiUsage(root);
  return {
    json: json as Record<string, unknown>,
    usage,
  };
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;
}

function arrayValue(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

function geminiText(payload: Record<string, unknown> | null): string {
  const candidate = asRecord(arrayValue(payload?.candidates)[0]);
  const content = asRecord(candidate?.content);
  return arrayValue(content?.parts)
    .map((part) => asRecord(part)?.text)
    .filter((part): part is string => typeof part === "string")
    .join("");
}

function openAiText(payload: Record<string, unknown> | null): string {
  const choice = asRecord(arrayValue(payload?.choices)[0]);
  const message = asRecord(choice?.message);
  return typeof message?.content === "string" ? message.content : "";
}

function tokenValue(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function geminiUsage(payload: Record<string, unknown> | null): TokenUsage {
  const usage = asRecord(payload?.usageMetadata);
  return {
    prompt_tokens: tokenValue(usage?.promptTokenCount),
    completion_tokens: tokenValue(usage?.candidatesTokenCount),
  };
}

function openAiUsage(payload: Record<string, unknown> | null): TokenUsage {
  const usage = asRecord(payload?.usage);
  return {
    prompt_tokens: tokenValue(usage?.prompt_tokens),
    completion_tokens: tokenValue(usage?.completion_tokens),
  };
}

async function logAi(
  admin: ReturnType<typeof serviceClient>,
  workspaceId: string,
  orgId: string,
  actorId: string,
  purpose: string,
  promptName: string,
  provider: AIProvider,
  model: string,
  usage: TokenUsage,
  ok: boolean,
) {
  await admin.from("ai_generation_logs").insert({
    workspace_id: workspaceId,
    organization_id: orgId,
    actor_id: actorId,
    purpose,
    prompt_name: promptName,
    model: `${provider}/${model}`,
    input_tokens: usage.prompt_tokens ?? null,
    output_tokens: usage.completion_tokens ?? null,
    status: ok ? "succeeded" : "failed",
  });
}

function reportWindow(type: string, customDays?: number) {
  const end = new Date();
  const start = new Date();
  start.setDate(end.getDate() - (customDays ?? (type === "monthly" ? 30 : 7)));
  return { start: start.toISOString().slice(0, 10), end: end.toISOString().slice(0, 10) };
}

async function collectReportMetrics(
  admin: ReturnType<typeof serviceClient>,
  orgId: string,
  workspaceId: string,
  start: string,
  end: string,
) {
  const startAt = `${start}T00:00:00.000Z`;
  const endAt = `${end}T23:59:59.999Z`;
  const monthStart = `${start.slice(0, 7)}-01`;
  const monthAfterEnd = new Date(`${end.slice(0, 7)}-01T00:00:00.000Z`);
  monthAfterEnd.setUTCMonth(monthAfterEnd.getUTCMonth() + 1);
  const monthEndExclusive = monthAfterEnd.toISOString().slice(0, 10);
  const [contentsRes, leadsRes, analyticsRes, spendRes] = await Promise.all([
    admin.from("marketing_contents").select("id,title,status,content_pillar,platform,published_at")
      .eq("organization_id", orgId).eq("status", "published")
      .gte("published_at", startAt).lte("published_at", endAt),
    admin.from("marketing_leads").select("id,status,created_at")
      .eq("organization_id", orgId).gte("created_at", startAt).lte("created_at", endAt),
    admin.from("social_analytics").select("*")
      .eq("organization_id", orgId).eq("metric_source", "platform")
      .gte("metric_date", start).lte("metric_date", end),
    admin.from("ad_budget_logs").select("amount_mmk")
      .eq("workspace_id", workspaceId).eq("entry_type", "actual")
      .gte("period_month", monthStart).lt("period_month", monthEndExclusive),
  ]);
  if (contentsRes.error) throw contentsRes.error;
  if (leadsRes.error) throw leadsRes.error;
  if (analyticsRes.error) throw analyticsRes.error;
  if (spendRes.error) throw spendRes.error;
  const contents = contentsRes.data || [];
  const leads = leadsRes.data || [];
  const analytics = analyticsRes.data || [];
  return {
    has_analytics: analytics.length > 0,
    analytics_note: analytics.length === 0 ? "Platform analytics could not be retrieved for this period." : "Stored platform metrics only.",
    advertising_spend_period_note: "Ad spend is stored by month, so weekly reports show the full actual spend for overlapping calendar month(s).",
    contents,
    leads,
    analytics,
    advertising_spend_mmk: (spendRes.data || []).reduce(
      (total: number, row: { amount_mmk: number }) => total + Number(row.amount_mmk || 0),
      0,
    ),
  };
}
