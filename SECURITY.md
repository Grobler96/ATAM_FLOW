# Security policy

ATAM_FLOW is an internal tool. Report any suspected vulnerability or leaked credential privately to the repository owner (do not open a public issue).

## Ground rules

- Never commit secrets. Service-role keys and DecoNetwork credentials live only in n8n credentials.
- Only the Supabase publishable key may appear in the frontend. Access is enforced by row-level security.
- Every new table in the `flow` schema must have RLS enabled and explicit policies.
- Every `security definer` function must pin `search_path`, check the caller's role, and have `execute` revoked from `public`, `anon` and `authenticated` unless intended.
- n8n webhooks must verify a Supabase JWT or shared secret.
- Rotate any credential that has ever been committed or stored in plain text.
