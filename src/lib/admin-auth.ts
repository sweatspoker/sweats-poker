import { timingSafeEqual } from "node:crypto";

// Shared LEDGER_ADMIN_TOKEN check + Card 4 failure-audit helper.
// Used by admin HTTP routes from Card 5 onward.

export function constantTimeEqual(a: string, b: string): boolean {
  const ba = Buffer.from(a, "utf8");
  const bb = Buffer.from(b, "utf8");
  if (ba.length !== bb.length) return false;
  return timingSafeEqual(ba, bb);
}

export type AdminAuthResult =
  | { ok: true }
  | { ok: false; status: 401 | 500; error: string };

export function checkAdminToken(headerValue: string | null): AdminAuthResult {
  const expected = process.env.LEDGER_ADMIN_TOKEN;
  if (!expected) {
    return { ok: false, status: 500, error: "LEDGER_ADMIN_TOKEN not configured" };
  }
  if (!headerValue || !constantTimeEqual(headerValue, expected)) {
    return { ok: false, status: 401, error: "unauthorized" };
  }
  return { ok: true };
}
