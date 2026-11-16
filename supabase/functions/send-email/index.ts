// Supabase Edge Function: send-email
// Dispatches transactional emails via Resend API (invitations, receipts, trial reminders)

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { corsHeaders } from "../_shared/cors.ts";

const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY");

interface EmailPayload {
  to: string;
  subject: string;
  html: string;
  text?: string;
  template?: "welcome" | "invoice_receipt" | "trial_expiring" | "subscription_activated";
  metadata?: Record<string, unknown>;
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const payload: EmailPayload = await req.json();

    if (!payload.to || !payload.subject) {
      return new Response(
        JSON.stringify({ error: "Missing required fields 'to' or 'subject'" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (!RESEND_API_KEY) {
      console.warn("RESEND_API_KEY not configured. Simulating email delivery in development mode.");
      return new Response(
        JSON.stringify({
          success: true,
          simulated: true,
          message: `Simulated email delivery to ${payload.to}`,
        }),
        { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${RESEND_API_KEY}`,
      },
      body: JSON.stringify({
        from: "ShopFlow Notifications <notifications@shopflow.app>",
        to: [payload.to],
        subject: payload.subject,
        html: payload.html,
      }),
    });

    const data = await res.json();
    return new Response(JSON.stringify(data), {
      status: res.status,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (error: any) {
    return new Response(
      JSON.stringify({ error: error.message || "Failed to send email" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});

