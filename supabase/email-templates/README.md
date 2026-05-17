# Supabase email templates

Branded HTML for the auth emails Supabase sends on the player app's behalf
(`signInWithOtp`, `signUp`, etc.). Supabase doesn't pull these from the
repo - you have to paste them into the dashboard manually.

## How to deploy

1. Open https://supabase.com/dashboard/project/vaqevyigkgfbjivwofgr/auth/templates
2. Pick the "Magic Link" template
3. Set **Subject heading**: `Your sign-in link for sweats.poker`
4. Paste the contents of [`magic-link.html`](./magic-link.html) into the
   **Message (HTML)** field
5. Click **Save**

The template uses Supabase's standard token `{{ .ConfirmationURL }}` -
do not edit that line.

## Where the email comes from

Default: Supabase's built-in SMTP. Free tier is rate-limited (~3/hour per
user) and the From address is `noreply@mail.app.supabase.io`. For
production, configure a custom SMTP provider (Resend / Postmark) in the
same dashboard under **Authentication → SMTP Settings** with
`from: noreply@sweats.poker` so the From line matches the brand.

## Visual reference

Dark surface (#0a0a0a bg / #141414 card), brand-red logomark, brand-green
CTA pill ("Sign in →"). Mirrors the live login page treatment. Inlined
styles only - works in clients that strip `<style>` blocks (Gmail, Outlook).
