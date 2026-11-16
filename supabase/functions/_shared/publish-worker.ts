import { serviceClient } from "./supabase.ts";
import { decryptSecret } from "./crypto.ts";
import { adapterFor } from "./providers.ts";

export async function processJobs() {
  const admin = serviceClient();
  const { data: jobs, error } = await admin.rpc("claim_due_publishing_jobs", { p_limit: 10, p_worker: "marketing-publish" });
  if (error) throw error;
  const claimed = jobs || [];
  const results: Array<Record<string, unknown>> = [];

  for (const job of claimed) {
    const { data: content } = await admin.from("marketing_contents").select("*").eq("id", job.content_id).single();
    if (
      !content ||
      !["approved", "scheduled", "failed"].includes(content.status) ||
      !content.approved_at ||
      !content.approved_by
    ) {
      await admin.rpc("complete_publishing_job", {
        p_job_id: job.id,
        p_success: false,
        p_error: "Unapproved content cannot be published",
        p_retryable: false,
      });
      results.push({ id: job.id, ok: false, reason: "unapproved" });
      continue;
    }

    const { data: account } = await admin
      .from("social_accounts")
      .select("*")
      .eq("workspace_id", content.workspace_id)
      .eq("provider", content.platform)
      .maybeSingle();

    if (!account || account.connection_status !== "connected") {
      await admin.rpc("complete_publishing_job", {
        p_job_id: job.id,
        p_success: false,
        p_error: "Social account is not connected. Export the caption and production brief and publish manually.",
        p_retryable: false,
      });
      results.push({ id: job.id, ok: false, reason: "disconnected" });
      continue;
    }

    const { data: secret } = await admin
      .from("social_account_secrets")
      .select("access_token_encrypted")
      .eq("social_account_id", account.id)
      .maybeSingle();
    if (!secret?.access_token_encrypted) {
      await admin.rpc("complete_publishing_job", {
        p_job_id: job.id,
        p_success: false,
        p_error: "Access token is missing. Reconnect the account.",
        p_retryable: false,
      });
      results.push({ id: job.id, ok: false, reason: "no_token" });
      continue;
    }

    const adapter = adapterFor(content.platform);
    if (!adapter) {
      await admin.rpc("complete_publishing_job", {
        p_job_id: job.id,
        p_success: false,
        p_error: "No provider adapter for this platform",
        p_retryable: false,
      });
      continue;
    }

    const { data: assets } = await admin.from("content_assets")
      .select("file_url, storage_path, asset_type")
      .eq("content_id", content.id);
    const asset = (assets || []).find((item: { asset_type: string }) =>
      content.platform === "tiktok" ? item.asset_type === "video" : item.asset_type === "image"
    );
    let media = asset?.file_url || null;
    if (asset?.storage_path) {
      const { data: signed, error: signedError } = await admin.storage
        .from("marketing-assets")
        .createSignedUrl(asset.storage_path, 60 * 60);
      if (signedError || !signed?.signedUrl) {
        await admin.rpc("complete_publishing_job", {
          p_job_id: job.id,
          p_success: false,
          p_error: "Could not create a temporary media link. Export the production brief and publish manually.",
          p_retryable: false,
        });
        results.push({ id: job.id, ok: false, reason: "media_unavailable" });
        continue;
      }
      media = signed.signedUrl;
    }
    const token = await decryptSecret(secret.access_token_encrypted);
    const published = await adapter.publish({
      accessToken: token,
      pageId: account.page_id,
      caption: `${content.caption}\n\n${(content.hashtags || []).join(" ")}`.trim(),
      mediaUrl: media,
      contentType: content.content_type,
    });

    await admin.rpc("complete_publishing_job", {
      p_job_id: job.id,
      p_success: published.ok,
      p_provider_post_id: published.providerPostId || null,
      p_error: published.error || null,
      p_retryable: published.retryable,
    });
    results.push({ id: job.id, ok: published.ok, error: published.error });
  }

  return results;
}
