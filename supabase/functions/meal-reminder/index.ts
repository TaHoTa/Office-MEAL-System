// Office Meal Tracker: sends the 8:30 "have you voted?" notification.
// Called by the database (see 2_reminder.sql). Needs no database access itself.
//
// Function secrets to set in Supabase (Edge Functions > Secrets):
//   CRON_SECRET        long random text, same value as in 2_reminder.sql
//   VAPID_PUBLIC_KEY   from setup-keys.html
//   VAPID_PRIVATE_KEY  from setup-keys.html (the JSON line)
//   VAPID_SUBJECT      mailto:your-email@example.com
// Turn OFF "Verify JWT" for this function; the CRON_SECRET header protects it.

const b64url = (data: ArrayBuffer | Uint8Array | string): string => {
  const bytes = typeof data === "string"
    ? new TextEncoder().encode(data)
    : data instanceof Uint8Array ? data : new Uint8Array(data);
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
};

let signingKey: CryptoKey | null = null;
async function getKey(): Promise<CryptoKey> {
  if (signingKey) return signingKey;
  const jwk = JSON.parse(Deno.env.get("VAPID_PRIVATE_KEY") ?? "{}");
  signingKey = await crypto.subtle.importKey(
    "jwk", jwk, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"],
  );
  return signingKey;
}

// VAPID (RFC 8292): a short-lived signed token proving who is sending the push.
async function vapidHeader(endpoint: string): Promise<string> {
  const head = b64url(JSON.stringify({ typ: "JWT", alg: "ES256" }));
  const claims = b64url(JSON.stringify({
    aud: new URL(endpoint).origin,
    exp: Math.floor(Date.now() / 1000) + 6 * 3600,
    sub: Deno.env.get("VAPID_SUBJECT") ?? "mailto:admin@example.com",
  }));
  const sig = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" }, await getKey(),
    new TextEncoder().encode(`${head}.${claims}`),
  );
  return `vapid t=${head}.${claims}.${b64url(sig)}, k=${Deno.env.get("VAPID_PUBLIC_KEY")}`;
}

Deno.serve(async (req) => {
  const secret = Deno.env.get("CRON_SECRET");
  if (!secret || req.headers.get("x-cron-secret") !== secret) {
    return new Response("Forbidden", { status: 403 });
  }
  let endpoints: string[] = [];
  try {
    const body = await req.json();
    endpoints = (body.endpoints ?? []).filter(
      (e: unknown) => typeof e === "string" && e.startsWith("https://"),
    );
  } catch (_) {
    return new Response("Bad request", { status: 400 });
  }

  // The push carries no message body: the app's service worker shows the
  // reminder text itself. TTL 3 h, so a phone that wakes after 11:30 gets nothing.
  const results = await Promise.all(endpoints.map(async (endpoint) => {
    try {
      const res = await fetch(endpoint, {
        method: "POST",
        headers: {
          Authorization: await vapidHeader(endpoint),
          TTL: "10800",
          Urgency: "high",
        },
      });
      return res.status;
    } catch (_) {
      return 0;
    }
  }));

  const ok = results.filter((s) => s >= 200 && s < 300).length;
  return new Response(
    JSON.stringify({ asked: endpoints.length, delivered: ok, statuses: results }),
    { headers: { "Content-Type": "application/json" } },
  );
});
