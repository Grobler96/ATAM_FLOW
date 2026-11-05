# Security checklist (things code alone cannot fix)

## n8n
- Export every ATAM_FLOW workflow (including `Verify caller`) from n8n as JSON into `n8n/workflows/`. CI scans them for pasted secrets (`scripts/check-n8n-exports.mjs`). Never commit `*.raw.json`.
- Add a cooldown to the sync, scheduler and allocation webhooks: at the top, look up the last run in `flow_last_runs()` and answer 429 if it started less than 60 seconds ago. This protects the monthly execution quota from loops or repeated clicks.
- Test the allowed path of every action webhook with a real signed-in token for each role (admin, manager, warehouse, production), and confirm a role without permission gets 403.
- Rotate the DecoNetwork password and move it into n8n credentials (it is stored in plain text in older HTTP nodes).

## Supabase
- Public sign-ups off (done 5 Nov 2026). Review Authentication > Users regularly.
- Turn on multi-factor sign-in for admin and manager accounts, and keep the JWT expiry short.
- Audit names come from the verified token email. Keep accounts to named individuals, not shared logins.

## GitHub
- Secret scanning with push protection, Dependabot alerts, and branch protection on `main` (require the Tests checks to pass).
- The repo is public. Making it private is possible but GitHub Pages then needs a paid plan or another host (Cloudflare Pages or Netlify). Until then, never commit anything environment-specific beyond the public Supabase URL and publishable key.

## Dashboard hosting
- GitHub Pages cannot send security headers (no CSP or frame protection header). A meta CSP would block the label print window, which writes an inline print script, so it is not enabled. If headers are needed, move the static build to Cloudflare Pages or Netlify and set `Content-Security-Policy` and `frame-ancestors 'none'` there.
- Never put the service-role key in the frontend. Only the publishable key belongs there.
