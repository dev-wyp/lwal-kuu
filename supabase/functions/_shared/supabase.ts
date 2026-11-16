import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

export function serviceClient(): SupabaseClient {
  const url = Deno.env.get("SUPABASE_URL") ?? "";
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  return createClient(url, key, { auth: { persistSession: false } });
}

export function userClient(authHeader: string): SupabaseClient {
  const url = Deno.env.get("SUPABASE_URL") ?? "";
  const anon = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  return createClient(url, anon, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false },
  });
}

export async function requireUser(req: Request) {
  const authHeader = req.headers.get("Authorization") ?? "";
  if (!authHeader.startsWith("Bearer ")) {
    throw new Error("Missing authorization");
  }
  const client = userClient(authHeader);
  const { data, error } = await client.auth.getUser();
  if (error || !data.user) {
    throw new Error("Invalid session");
  }
  return { user: data.user, client };
}

export async function requirePlatformAdmin(req: Request) {
  const { user } = await requireUser(req);
  const admin = serviceClient();
  const { data: profile, error } = await admin
    .from('profiles')
    .select('is_platform_admin')
    .eq('id', user.id)
    .single();

  if (error || !profile?.is_platform_admin) {
    throw new Error('Platform administrator access required');
  }

  return { user, admin };
}
