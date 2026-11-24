const enc = new TextEncoder();
const b64 = (bytes: Uint8Array) =>
  btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
const unb64 = (s: string) =>
  Uint8Array.from(
    atob(s.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (s.length % 4)) % 4)),
    (c) => c.charCodeAt(0),
  );
export const base64url = b64;
export const randomToken = (n = 32) => b64(crypto.getRandomValues(new Uint8Array(n)));
export async function sha256(value: string): Promise<string> {
  return b64(new Uint8Array(await crypto.subtle.digest("SHA-256", enc.encode(value))));
}
async function hmacKey(secret: string) {
  return crypto.subtle.importKey("raw", unb64(secret), { name: "HMAC", hash: "SHA-256" }, false, [
    "sign",
    "verify",
  ]);
}
export async function sign(secret: string, text: string): Promise<string> {
  return b64(
    new Uint8Array(await crypto.subtle.sign("HMAC", await hmacKey(secret), enc.encode(text))),
  );
}
export async function verify(secret: string, text: string, signature: string): Promise<boolean> {
  try {
    return crypto.subtle.verify("HMAC", await hmacKey(secret), unb64(signature), enc.encode(text));
  } catch {
    return false;
  }
}
export async function accessToken(secret: string, dev: string, exp: number): Promise<string> {
  const payload = b64(enc.encode(JSON.stringify({ dev, exp })));
  return `v1.${payload}.${await sign(secret, `v1.${payload}`)}`;
}
export async function verifyAccess(
  secret: string,
  token: string,
  now = Date.now(),
): Promise<{ dev: string; exp: number } | null> {
  const p = token.split(".");
  if (p.length !== 3 || p[0] !== "v1" || !(await verify(secret, `${p[0]}.${p[1]}`, p[2])))
    return null;
  try {
    const value = JSON.parse(new TextDecoder().decode(unb64(p[1]))) as { dev: string; exp: number };
    return value.dev && value.exp * 1000 > now ? value : null;
  } catch {
    return null;
  }
}
export type State = {
  challenge: string;
  redirect: string;
  appState: string;
  nonce: string;
  name: string;
  exp: number;
};
export async function signedState(secret: string, value: State): Promise<string> {
  const data = b64(enc.encode(JSON.stringify(value)));
  return `${data}.${await sign(secret, data)}`;
}
export async function readState(
  secret: string,
  value: string,
  now = Date.now(),
): Promise<State | null> {
  const [data, sig, ...rest] = value.split(".");
  if (!data || !sig || rest.length || !(await verify(secret, data, sig))) return null;
  try {
    const obj = JSON.parse(new TextDecoder().decode(unb64(data))) as State;
    return obj.exp > now && obj.exp <= now + 11 * 60_000 ? obj : null;
  } catch {
    return null;
  }
}

type GoogleClaims = {
  iss: string;
  aud: string;
  exp: number;
  iat: number;
  nonce: string;
  email_verified: boolean;
  sub?: string;
};
type GoogleJwk = JsonWebKey & { kid?: string };
let jwksCache: { expires: number; keys: GoogleJwk[] } | undefined;
export async function verifyGoogleIdToken(
  token: string,
  env: { GOOGLE_CLIENT_ID: string; OWNER_SUB?: string; JWKS_URL?: string },
  now = Date.now(),
  fetcher: typeof fetch = fetch,
  expectedNonce?: string,
): Promise<GoogleClaims> {
  const parts = token.split(".");
  if (parts.length !== 3) throw Error("token");
  const header = JSON.parse(new TextDecoder().decode(unb64(parts[0]))) as {
    alg: string;
    kid: string;
  };
  if (header.alg !== "RS256" || !header.kid) throw Error("signature");
  if (!jwksCache || jwksCache.expires < now) {
    const endpoint = env.JWKS_URL ?? "https://www.googleapis.com/oauth2/v3/certs",
      cache = (globalThis as unknown as { caches?: { default: Cache } }).caches?.default,
      key = new Request(endpoint);
    const cached = await cache?.match(key);
    let keys: GoogleJwk[];
    if (cached) {
      keys = ((await cached.json()) as { keys: GoogleJwk[] }).keys;
    } else {
      const response = await fetcher(endpoint);
      if (!response.ok) throw Error("jwks");
      keys = ((await response.json()) as { keys: GoogleJwk[] }).keys;
      await cache?.put(
        key,
        new Response(JSON.stringify({ keys }), {
          headers: { "cache-control": "public, max-age=3600", "content-type": "application/json" },
        }),
      );
    }
    jwksCache = { keys, expires: now + 60 * 60_000 };
  }
  const jwk = jwksCache.keys.find((k) => k.kid === header.kid);
  if (!jwk) throw Error("signature");
  const key = await crypto.subtle.importKey(
    "jwk",
    jwk,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["verify"],
  );
  if (
    !(await crypto.subtle.verify(
      "RSASSA-PKCS1-v1_5",
      key,
      unb64(parts[2]),
      enc.encode(`${parts[0]}.${parts[1]}`),
    ))
  )
    throw Error("signature");
  const c = JSON.parse(new TextDecoder().decode(unb64(parts[1]))) as GoogleClaims;
  if (!["https://accounts.google.com", "accounts.google.com"].includes(c.iss)) throw Error("iss");
  if (c.aud !== env.GOOGLE_CLIENT_ID) throw Error("aud");
  if (typeof c.exp !== "number" || !Number.isFinite(c.exp) || c.exp * 1000 <= now)
    throw Error("exp");
  if (
    typeof c.iat !== "number" ||
    !Number.isFinite(c.iat) ||
    Math.abs(c.iat * 1000 - now) > 5 * 60_000
  )
    throw Error("iat");
  if (
    typeof c.nonce !== "string" ||
    !c.nonce ||
    (expectedNonce !== undefined && c.nonce !== expectedNonce) ||
    c.email_verified !== true
  )
    throw Error(
      typeof c.nonce !== "string" ||
        !c.nonce ||
        (expectedNonce !== undefined && c.nonce !== expectedNonce)
        ? "nonce"
        : "email_verified",
    );
  if (typeof c.sub !== "string" || !c.sub) throw Error("sub");
  if (env.OWNER_SUB && c.sub !== env.OWNER_SUB) throw Error("owner");
  return c;
}
export function redirectAllowed(candidate: string, config: string): boolean {
  let url: URL;
  try {
    url = new URL(candidate);
  } catch {
    return false;
  }
  let allowed: string[];
  try {
    allowed = JSON.parse(config) as string[];
  } catch {
    return false;
  }
  return allowed.some((prefix) => {
    if (prefix === "http://127.0.0.1/")
      return (
        url.protocol === "http:" &&
        url.hostname === "127.0.0.1" &&
        !url.username &&
        !url.password &&
        url.pathname === "/cb"
      );
    try {
      const allowedUrl = new URL(prefix);
      return (
        candidate.startsWith(prefix) &&
        url.protocol === allowedUrl.protocol &&
        url.hostname === allowedUrl.hostname &&
        !url.username &&
        !url.password &&
        url.pathname.startsWith(allowedUrl.pathname)
      );
    } catch {
      return false;
    }
  });
}
