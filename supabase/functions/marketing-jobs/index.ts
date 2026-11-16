import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { corsHeaders, jsonResponse } from "../_shared/cors.ts";
import { serviceClient } from "../_shared/supabase.ts";
import { processJobs } from "../_shared/publish-worker.ts";
import { decryptSecret } from "../_shared/crypto.ts";
import { adapterFor } from "../_shared/providers.ts";

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const cronSecret = Deno.env.get("MARKETING_CRON_SECRET");
    const provided = req.headers.get("x-cron-secret");
    if (!cronSecret || provided !== cronSecret) {
      return jsonResponse({ error: "Unauthorized cron request" }, 401);
    }

    const admin = serviceClient();
    const body = req.method === "POST" ? await req.json().catch(() => ({})) : {};
    const job = body.job as string | undefined;

    const results: Record<string, unknown> = {};
    if (!job || job === "publish") results.publish = await processJobs();
    if (!job || job === "expired") {
      const { data, error } = await admin.rpc("cron_detect_expired_social_connections");
      if (error) throw error;
      results.expired = data;
    }
    if (!job || job === "upcoming") {
      const { data, error } = await admin.rpc("cron_notify_upcoming_scheduled_posts");
      if (error) throw error;
      results.upcoming = data;
    }
    if (!job || job === "analytics") results.analytics = await syncAnalytics(admin);

    return jsonResponse({ ok: true, results });
  } catch (err) {
    return jsonResponse({ error: err instanceof Error ? err.message : "Marketing job failed" }, 500);
  }
});

async function syncAnalytics(admin: ReturnType<typeof serviceClient>) {
  const { data: accounts } = await admin.from("social_accounts").select("*").eq("connection_status", "connected");
  const synced: Array<Record<string, unknown>> = [];
  for (const account of accounts || []) {
    const adapter = adapterFor(account.provider);
    if (!adapter) continue;
    if (account.provider === "tiktok") {
      synced.push({ account: account.id, ok: false, error: "TikTok analytics sync is unavailable until video query and insight permissions are verified." });
      continue;
    }
    const { data: secret } = await admin
      .from("social_account_secrets")
      .select("access_token_encrypted")
      .eq("social_account_id", account.id)
      .maybeSingle();
    if (!secret?.access_token_encrypted) {
      synced.push({ account: account.id, ok: false, error: "token missing" });
      continue;
    }
    const token = await decryptSecret(secret.access_token_encrypted);
    const until = yangonDate(new Date().toISOString());
    const sinceDate = new Date(`${until}T12:00:00.000Z`);
    sinceDate.setUTCDate(sinceDate.getUTCDate() - 7);
    const since = sinceDate.toISOString().slice(0, 10);
    const insights = await adapter.insights({ accessToken: token, pageId: account.page_id, since, until });
    if (!insights.ok) {
      synced.push({ account: account.id, ok: false, error: insights.error });
      continue;
    }
    const metricValues = (name: string) => {
      const row = insights.rows.find((item) => item.name === name);
      if (!row || !Array.isArray(row.values)) return new Map<string, number>();
      return new Map(row.values.flatMap((item) => {
        if (!item || typeof item !== "object") return [];
        const valueRow = item as Record<string, unknown>;
        const value = typeof valueRow.value === "number" ? valueRow.value : null;
        const date = typeof valueRow.end_time === "string" ? yangonDate(valueRow.end_time) : until;
        return value === null ? [] : [[date, value] as const];
      }));
    };
    const impressions = metricValues("page_impressions");
    const reach = metricValues("page_reach");
    const metricDates = new Set([...impressions.keys(), ...reach.keys()]);
    if (!metricDates.size) {
      synced.push({ account: account.id, ok: false, error: "Facebook returned no supported daily impression or reach values." });
      continue;
    }

    for (const metricDate of metricDates) {
      const patch = {
        impressions: impressions.get(metricDate) ?? null,
        reach: reach.get(metricDate) ?? null,
        metric_source: "platform",
        source_note: "Daily Page metrics synced from Meta API",
      };
      const { data: existing } = await admin.from("social_analytics")
        .select("id")
        .eq("workspace_id", account.workspace_id)
        .eq("platform", "facebook")
        .eq("metric_date", metricDate)
        .is("content_id", null)
        .maybeSingle();
      const result = existing?.id
        ? await admin.from("social_analytics").update(patch).eq("id", existing.id)
        : await admin.from("social_analytics").insert({
            ...patch,
            workspace_id: account.workspace_id,
            organization_id: account.organization_id,
            social_account_id: account.id,
            platform: "facebook",
            metric_date: metricDate,
          });
      if (result.error) {
        synced.push({ account: account.id, date: metricDate, ok: false, error: result.error.message });
      }
    }
    synced.push({ account: account.id, ok: true, days: metricDates.size });
  }
  return synced;
}

function yangonDate(value: string): string {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: "Asia/Yangon",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(new Date(value));
  const values = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  return `${values.year}-${values.month}-${values.day}`;
}
