import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { corsHeaders, jsonResponse } from "../_shared/cors.ts";
import { requirePlatformAdmin } from "../_shared/supabase.ts";
import { processJobs } from "../_shared/publish-worker.ts";

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const cronSecret = Deno.env.get("MARKETING_CRON_SECRET");
    const provided = req.headers.get("x-cron-secret");
    if (!(cronSecret && provided === cronSecret)) {
      await requirePlatformAdmin(req);
    }

    const processed = await processJobs();
    return jsonResponse({ processed });
  } catch (err) {
    return jsonResponse({ error: err instanceof Error ? err.message : "Publish worker failed" }, 400);
  }
});
