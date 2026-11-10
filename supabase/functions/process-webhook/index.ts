// Supabase Edge Function: process-webhook
// Securely handles external payment provider webhooks (e.g. 2C2P, KBZPay merchant callbacks)

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") || "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
const WEBHOOK_SECRET = Deno.env.get("PAYMENT_WEBHOOK_SECRET") || "";

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  try {
    const signature = req.headers.get("x-webhook-signature");
    if (WEBHOOK_SECRET && signature !== WEBHOOK_SECRET) {
      return new Response(JSON.stringify({ error: "Invalid signature" }), {
        status: 401,
        headers: { "Content-Type": "application/json" },
      });
    }

    const payload = await req.json();
    const { event_type, subscription_id, transaction_ref, status, amount } = payload;

    if (event_type === "payment_success" && subscription_id) {
      // Find subscription
      const { data: sub, error: subErr } = await supabase
        .from("subscriptions")
        .select("*")
        .eq("id", subscription_id)
        .single();

      if (subErr || !sub) {
        return new Response(JSON.stringify({ error: "Subscription not found" }), { status: 404 });
      }

      // Automatically update subscription to active for duration
      const durationDays = sub.billing_cycle === "yearly" ? 365 : 30;
      const newEnd = new Date();
      newEnd.setDate(newEnd.getDate() + durationDays);

      await supabase
        .from("subscriptions")
        .update({
          status: "active",
          current_period_start: new Date().toISOString(),
          current_period_end: newEnd.toISOString(),
          updated_at: new Date().toISOString(),
        })
        .eq("id", subscription_id);

      await supabase.from("subscription_events").insert({
        subscription_id,
        organization_id: sub.organization_id,
        event_type: "payment_approved",
        amount,
        payment_method: "gateway_webhook",
        payment_reference: transaction_ref,
        admin_notes: `Auto-verified via payment gateway callback (${status})`,
      });

      return new Response(JSON.stringify({ success: true, status: "active" }), {
        headers: { "Content-Type": "application/json" },
      });
    }

    return new Response(JSON.stringify({ received: true }), {
      headers: { "Content-Type": "application/json" },
    });
  } catch (err: any) {
    return new Response(JSON.stringify({ error: err.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});

