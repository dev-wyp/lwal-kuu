import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { corsHeaders, jsonResponse } from "../_shared/cors.ts";
import { requirePlatformAdmin, serviceClient } from "../_shared/supabase.ts";
import { encryptSecret } from "../_shared/crypto.ts";

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  const url = new URL(req.url);
  if (req.method === "GET" && (url.searchParams.get("code") || url.searchParams.get("error"))) {
    return handleCallback(url);
  }

  try {
    const { user, admin } = await requirePlatformAdmin(req);
    const body = await req.json();
    const action = body.action as string;

    if (action === "connect") {
      const provider = body.provider as string;
      const orgId = body.organization_id as string;
      if (!orgId || !["facebook", "tiktok"].includes(provider)) {
        return jsonResponse({ error: "A valid organization and provider are required" }, 400);
      }
      const { data: workspace } = await admin
        .from("marketing_workspaces")
        .select("id")
        .eq("organization_id", orgId)
        .single();
      if (!workspace) return jsonResponse({ error: "Workspace missing" }, 404);

      const setup = setupInstructions(provider);
      if (setup) return jsonResponse(setup);

      const nonce = crypto.randomUUID();
      const redirectTo = body.redirect_to === "/admin/marketing/social-accounts"
        ? body.redirect_to
        : "/admin/marketing/social-accounts";
      const { error } = await admin.from("marketing_oauth_states").insert({
        state_nonce: nonce,
        provider,
        workspace_id: workspace.id,
        organization_id: orgId,
        user_id: user.id,
        redirect_to: redirectTo,
      });
      if (error) throw error;

      return jsonResponse({ auth_url: buildAuthUrl(provider, nonce) });
    }

    if (action === "disconnect") {
      const accountId = body.account_id as string;
      if (!accountId) return jsonResponse({ error: "account_id is required" }, 400);
      const { data: account } = await admin.from("social_accounts")
        .select("id, organization_id")
        .eq("id", accountId)
        .maybeSingle();
      if (!account) return jsonResponse({ error: "Social account not found" }, 404);
      const { error: secretError } = await admin.from("social_account_secrets").delete().eq("social_account_id", accountId);
      if (secretError) throw secretError;
      const { error: accountError } = await admin.from("social_accounts").update({
        connection_status: "disconnected",
        last_error: null,
        external_account_id: null,
        granted_permissions: [],
      }).eq("id", accountId);
      if (accountError) throw accountError;
      return jsonResponse({ ok: true });
    }

    return jsonResponse({ error: "Unknown action" }, 400);
  } catch (err) {
    return jsonResponse({ error: err instanceof Error ? err.message : "OAuth failed" }, 400);
  }
});

function setupInstructions(provider: string) {
  if (provider === "facebook" && (!Deno.env.get("META_APP_ID") || !Deno.env.get("META_APP_SECRET") || !Deno.env.get("META_OAUTH_REDIRECT_URL"))) {
    return {
      setup_required: true,
      message:
        "Configure META_APP_ID, META_APP_SECRET, and META_OAUTH_REDIRECT_URL on the marketing-oauth function. Until Meta App Review grants pages_manage_posts, export approved captions from the Approvals preview and post manually.",
      setup_instructions:
        "1. Create a Meta app with Facebook Login. 2. Add pages_show_list, pages_read_engagement, pages_manage_posts. 3. Set the redirect URL to this function. 4. Store secrets in Supabase Edge Function secrets. Tokens are never stored in the browser.",
    };
  }
  if (provider === "tiktok" && (!Deno.env.get("TIKTOK_CLIENT_KEY") || !Deno.env.get("TIKTOK_CLIENT_SECRET") || !Deno.env.get("TIKTOK_OAUTH_REDIRECT_URL"))) {
    return {
      setup_required: true,
      message:
        "Configure TIKTOK_CLIENT_KEY, TIKTOK_CLIENT_SECRET, and TIKTOK_OAUTH_REDIRECT_URL. Until Content Posting API access is granted, download the video production brief and publish manually.",
      setup_instructions:
        "1. Create a TikTok developer app. 2. Request video.publish and video.list scopes. 3. Point the redirect URI at this function. 4. Store secrets server-side only.",
    };
  }
  return null;
}

function buildAuthUrl(provider: string, state: string): string {
  if (provider === "facebook") {
    const u = new URL("https://www.facebook.com/v21.0/dialog/oauth");
    u.searchParams.set("client_id", Deno.env.get("META_APP_ID") || "");
    u.searchParams.set("redirect_uri", Deno.env.get("META_OAUTH_REDIRECT_URL") || "");
    u.searchParams.set("state", state);
    u.searchParams.set("scope", "pages_show_list,pages_read_engagement,pages_manage_posts,pages_read_user_content");
    return u.toString();
  }
  const u = new URL("https://www.tiktok.com/v2/auth/authorize/");
  u.searchParams.set("client_key", Deno.env.get("TIKTOK_CLIENT_KEY") || "");
  u.searchParams.set("redirect_uri", Deno.env.get("TIKTOK_OAUTH_REDIRECT_URL") || "");
  u.searchParams.set("state", state);
  u.searchParams.set("response_type", "code");
  u.searchParams.set("scope", "user.info.basic,video.publish,video.list");
  return u.toString();
}

async function handleCallback(url: URL) {
  const site = Deno.env.get("SITE_URL") || "http://localhost:3000";
  const error = url.searchParams.get("error");
  if (error) {
    return Response.redirect(`${site}/admin/marketing/social-accounts?oauth_error=${encodeURIComponent(error)}`);
  }
  const code = url.searchParams.get("code") || "";
  const state = url.searchParams.get("state") || "";
  const admin = serviceClient();
  const { data: row } = await admin
    .from("marketing_oauth_states")
    .select("*")
    .eq("state_nonce", state)
    .is("used_at", null)
    .gt("expires_at", new Date().toISOString())
    .maybeSingle();
  if (!row) {
    return Response.redirect(`${site}/admin/marketing/social-accounts?oauth_error=invalid_state`);
  }
  const { data: claimed } = await admin.from("marketing_oauth_states")
    .update({ used_at: new Date().toISOString() })
    .eq("id", row.id)
    .is("used_at", null)
    .gt("expires_at", new Date().toISOString())
    .select("id")
    .maybeSingle();
  if (!claimed) {
    return Response.redirect(`${site}/admin/marketing/social-accounts?oauth_error=invalid_state`);
  }

  try {
    if (row.provider === "facebook") {
      await exchangeFacebook(admin, row, code);
    } else {
      await exchangeTikTok(admin, row, code);
    }
    return Response.redirect(`${site}${row.redirect_to}?connected=${row.provider}`);
  } catch (err) {
    const message = err instanceof Error ? err.message : "oauth_failed";
    return Response.redirect(`${site}/admin/marketing/social-accounts?oauth_error=${encodeURIComponent(message)}`);
  }
}

async function exchangeFacebook(admin: ReturnType<typeof serviceClient>, row: Record<string, string>, code: string) {
  const tokenUrl = new URL("https://graph.facebook.com/v21.0/oauth/access_token");
  tokenUrl.searchParams.set("client_id", Deno.env.get("META_APP_ID") || "");
  tokenUrl.searchParams.set("client_secret", Deno.env.get("META_APP_SECRET") || "");
  tokenUrl.searchParams.set("redirect_uri", Deno.env.get("META_OAUTH_REDIRECT_URL") || "");
  tokenUrl.searchParams.set("code", code);
  const tokenRes = await fetch(tokenUrl);
  const tokenJson = await tokenRes.json();
  if (!tokenRes.ok) throw new Error(tokenJson?.error?.message || "Facebook token exchange failed");

  const pagesRes = await fetch(`https://graph.facebook.com/v21.0/me/accounts?access_token=${tokenJson.access_token}`);
  const pagesJson = await pagesRes.json();
  const page = pagesJson.data?.[0];
  if (!page) {
    await admin.from("social_accounts").update({
      connection_status: "missing_permissions",
      last_error: "No Facebook Page was returned. Grant pages_show_list.",
      missing_permissions: ["pages_show_list"],
    }).eq("workspace_id", row.workspace_id).eq("provider", "facebook");
    throw new Error("No Facebook Page available");
  }

  const { data: account } = await admin.from("social_accounts").select("id").eq("workspace_id", row.workspace_id).eq("provider", "facebook").maybeSingle();
  if (!account?.id) throw new Error("Facebook social account row missing");
  const { error: accountError } = await admin.from("social_accounts").update({
    display_name: page.name,
    external_account_id: page.id,
    page_id: page.id,
    connection_status: "connected",
    granted_permissions: ["pages_manage_posts"],
    missing_permissions: [],
    last_error: null,
    last_synced_at: new Date().toISOString(),
  }).eq("id", account.id);
  if (accountError) throw accountError;
  await admin.from("social_account_secrets").upsert({
    social_account_id: account.id,
    access_token_encrypted: await encryptSecret(page.access_token),
    token_type: "page",
    scopes: "pages_manage_posts",
  });
}

async function exchangeTikTok(admin: ReturnType<typeof serviceClient>, row: Record<string, string>, code: string) {
  const res = await fetch("https://open.tiktokapis.com/v2/oauth/token/", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_key: Deno.env.get("TIKTOK_CLIENT_KEY") || "",
      client_secret: Deno.env.get("TIKTOK_CLIENT_SECRET") || "",
      code,
      grant_type: "authorization_code",
      redirect_uri: Deno.env.get("TIKTOK_OAUTH_REDIRECT_URL") || "",
    }),
  });
  const json = await res.json();
  if (!res.ok || json.error) throw new Error(json.error_description || json.error || "TikTok token exchange failed");
  const { data: account } = await admin.from("social_accounts").select("id").eq("workspace_id", row.workspace_id).eq("provider", "tiktok").maybeSingle();
  if (!account?.id) throw new Error("TikTok social account row missing");
  await admin.from("social_accounts").update({
    connection_status: "connected",
    granted_permissions: (json.scope || "").split(","),
    missing_permissions: [],
    last_error: null,
    last_synced_at: new Date().toISOString(),
    token_expires_at: json.expires_in ? new Date(Date.now() + json.expires_in * 1000).toISOString() : null,
  }).eq("id", account.id);
  await admin.from("social_account_secrets").upsert({
    social_account_id: account.id,
    access_token_encrypted: await encryptSecret(json.access_token),
    refresh_token_encrypted: json.refresh_token ? await encryptSecret(json.refresh_token) : null,
    token_type: "user",
    scopes: json.scope,
  });
}
