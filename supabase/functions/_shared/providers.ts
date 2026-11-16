export interface ProviderAdapter {
  name: string;
  publish(input: PublishInput): Promise<PublishResult>;
  insights(input: InsightsInput): Promise<InsightsResult>;
}

export interface PublishInput {
  accessToken: string;
  pageId?: string | null;
  caption: string;
  mediaUrl?: string | null;
  contentType: string;
}

export interface PublishResult {
  ok: boolean;
  providerPostId?: string;
  error?: string;
  retryable: boolean;
}

export interface InsightsInput {
  accessToken: string;
  pageId?: string | null;
  since: string;
  until: string;
}

export interface InsightsResult {
  ok: boolean;
  rows: Array<Record<string, unknown>>;
  error?: string;
}

export const facebookAdapter: ProviderAdapter = {
  name: "facebook",
  async publish(input) {
    if (!input.pageId) {
      return { ok: false, retryable: false, error: "Facebook Page ID is missing. Reconnect the Page." };
    }
    const url = new URL(`https://graph.facebook.com/v21.0/${input.pageId}/feed`);
    const res = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        message: input.caption,
        access_token: input.accessToken,
      }),
    });
    const body = await res.json();
    if (!res.ok) {
      const code = body?.error?.code;
      const retryable = res.status >= 500 || code === 1 || code === 2 || code === 4;
      return {
        ok: false,
        retryable,
        error: body?.error?.message || `Facebook publish failed (${res.status})`,
      };
    }
    return { ok: true, providerPostId: body.id, retryable: false };
  },
  async insights(input) {
    if (!input.pageId) {
      return { ok: false, rows: [], error: "Facebook Page ID is missing" };
    }
    const url = new URL(`https://graph.facebook.com/v21.0/${input.pageId}/insights`);
    url.searchParams.set("metric", "page_impressions,page_reach");
    url.searchParams.set("period", "day");
    url.searchParams.set("since", String(Math.floor(new Date(`${input.since}T00:00:00Z`).getTime() / 1000)));
    url.searchParams.set("until", String(Math.floor(new Date(`${input.until}T23:59:59Z`).getTime() / 1000)));
    url.searchParams.set("access_token", input.accessToken);
    const res = await fetch(url);
    const body = await res.json();
    if (!res.ok) {
      return { ok: false, rows: [], error: body?.error?.message || "Facebook insights unavailable" };
    }
    return { ok: true, rows: body.data ?? [] };
  },
};

export const tiktokAdapter: ProviderAdapter = {
  name: "tiktok",
  async publish(input) {
    if (!input.mediaUrl) {
      return {
        ok: false,
        retryable: false,
        error: "TikTok publishing requires an uploaded video. Use the production brief for manual posting.",
      };
    }
    const res = await fetch("https://open.tiktokapis.com/v2/post/publish/video/init/", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${input.accessToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        post_info: {
          title: input.caption.slice(0, 150),
          privacy_level: "PUBLIC_TO_EVERYONE",
        },
        source_info: {
          source: "PULL_FROM_URL",
          video_url: input.mediaUrl,
        },
      }),
    });
    const body = await res.json();
    if (!res.ok || body?.error?.code) {
      return {
        ok: false,
        retryable: res.status >= 500,
        error: body?.error?.message || `TikTok publish failed (${res.status})`,
      };
    }
    return { ok: true, providerPostId: body?.data?.publish_id, retryable: false };
  },
  async insights(_input) {
    return {
      ok: false,
      rows: [],
      error: "TikTok analytics sync is unavailable until the account's video list and insights permissions are verified.",
    };
  },
};

export function adapterFor(provider: string): ProviderAdapter | null {
  if (provider === "facebook") return facebookAdapter;
  if (provider === "tiktok") return tiktokAdapter;
  return null;
}
