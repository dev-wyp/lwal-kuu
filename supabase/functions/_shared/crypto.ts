async function keyMaterial(): Promise<CryptoKey> {
  const secret = Deno.env.get("MARKETING_TOKEN_SECRET") || Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "dev-only-not-for-production";
  const bytes = new Uint8Array(32);
  bytes.set(new TextEncoder().encode(secret).slice(0, 32));
  return crypto.subtle.importKey("raw", bytes, { name: "AES-GCM" }, false, ["encrypt", "decrypt"]);
}

export async function encryptSecret(value: string): Promise<string> {
  const key = await keyMaterial();
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const encrypted = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, new TextEncoder().encode(value));
  const packed = new Uint8Array(iv.length + encrypted.byteLength);
  packed.set(iv, 0);
  packed.set(new Uint8Array(encrypted), iv.length);
  return btoa(String.fromCharCode(...packed));
}

export async function decryptSecret(payload: string): Promise<string> {
  const raw = Uint8Array.from(atob(payload), (c) => c.charCodeAt(0));
  const iv = raw.slice(0, 12);
  const data = raw.slice(12);
  const key = await keyMaterial();
  const decrypted = await crypto.subtle.decrypt({ name: "AES-GCM", iv }, key, data);
  return new TextDecoder().decode(decrypted);
}
