import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { corsHeaders } from "../_shared/cors.ts";
import { requirePlatformAdmin } from "../_shared/supabase.ts";

const escapeHtml = (value: unknown) => String(value ?? "").replace(/[&<>"']/g, (char) => ({
  "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
}[char] ?? char));

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  try {
    const { admin } = await requirePlatformAdmin(req);
    const apiKey = Deno.env.get("RESEND_API_KEY");
    if (!apiKey) return new Response(JSON.stringify({ error: "RESEND_API_KEY is not configured." }), {
      status: 503, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });

    const { data: pending, error } = await admin.from("notification_outbox")
      .select("id, organization_id, notification_type, recipient_email, subject, payload, retry_count, status")
      .in("status", ["pending", "failed"]).lte("scheduled_at", new Date().toISOString())
      .order("scheduled_at", { ascending: true }).limit(50);
    if (error) throw error;

    let sent = 0;
    let failed = 0;
    for (const item of pending ?? []) {
      const { data: claimed, error: claimError } = await admin.from("notification_outbox")
        .update({ status: "processing", last_error: null }).eq("id", item.id).eq("status", item.status)
        .select("id").maybeSingle();
      if (claimError) throw claimError;
      if (!claimed) continue;

      const details = Object.entries(item.payload ?? {}).map(([key, value]) =>
        `<tr><th style="text-align:left;padding:6px;border-bottom:1px solid #e2e8f0">${escapeHtml(key.replaceAll("_", " "))}</th><td style="padding:6px;border-bottom:1px solid #e2e8f0">${escapeHtml(value)}</td></tr>`
      ).join("");
      try {
        const response = await fetch("https://api.resend.com/emails", {
          method: "POST",
          headers: { "Content-Type": "application/json", Authorization: `Bearer ${apiKey}` },
          body: JSON.stringify({
            from: "Lwal Kuu Notifications <notifications@shopflow.app>",
            to: [item.recipient_email], subject: item.subject,
            html: `<main style="font-family:Arial,sans-serif;color:#0f172a"><h2>${escapeHtml(item.subject)}</h2><table style="border-collapse:collapse">${details}</table><p style="color:#64748b">Lwal Kuu</p></main>`,
          }),
        });
        const responseBody = await response.text();
        if (!response.ok) throw new Error(`Email provider returned ${response.status}: ${responseBody.slice(0, 500)}`);
        const { error: updateError } = await admin.from("notification_outbox").update({ status: "sent", sent_at: new Date().toISOString(), last_error: null }).eq("id", item.id);
        if (updateError) throw updateError;
        sent += 1;
      } catch (sendError) {
        const message = sendError instanceof Error ? sendError.message : "Email delivery failed";
        await admin.from("notification_outbox").update({ status: "failed", retry_count: item.retry_count + 1, last_error: message }).eq("id", item.id);
        failed += 1;
      }
    }
    return new Response(JSON.stringify({ sent, failed, examined: pending?.length ?? 0 }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : "Notification dispatch failed";
    const status = message.includes("administrator") ? 403 : 500;
    return new Response(JSON.stringify({ error: message }), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });
  }
});
