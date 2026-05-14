import { NextResponse } from "next/server";

export const runtime = "nodejs";

// Supabase wiring deferred — at this point in build we surface the
// infra heads-up (Supabase project creation under Tommy's account).
// Until creds land in env, this endpoint just validates + logs to stdout
// so the form ships behaviorally complete.
export async function POST(req: Request) {
  let body: { email?: string };
  try {
    body = await req.json();
  } catch {
    return NextResponse.json({ error: "Invalid JSON." }, { status: 400 });
  }
  const email = (body.email || "").trim().toLowerCase();
  if (!email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    return NextResponse.json(
      { error: "Enter a valid email." },
      { status: 400 },
    );
  }

  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;

  if (url && key) {
    const res = await fetch(`${url}/rest/v1/waitlist`, {
      method: "POST",
      headers: {
        apikey: key,
        Authorization: `Bearer ${key}`,
        "content-type": "application/json",
        Prefer: "resolution=merge-duplicates",
      },
      body: JSON.stringify({ email }),
    });
    if (!res.ok) {
      const text = await res.text();
      return NextResponse.json(
        { error: "Could not save your email." , detail: text.slice(0, 200) },
        { status: 500 },
      );
    }
    return NextResponse.json({ ok: true });
  }

  // Dev fallback when Supabase env not yet configured.
  console.log("[waitlist] capture (no Supabase configured):", email);
  return NextResponse.json({ ok: true, mode: "stub" });
}
