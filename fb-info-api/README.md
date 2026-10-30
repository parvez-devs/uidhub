# XEROXHUB FB Info API

A permission-aware FastAPI API for Facebook Page and consenting-user profile lookups. **There is no guaranteed, authorized API for every arbitrary personal Facebook UID**. Data availability depends on the Meta Graph API token, scopes, entity type and approvals. Usernames may be null and profile image URLs may expire.

## Live infrastructure — 30 October 2026

- Repository: https://github.com/parvez-devs/uidhub/tree/main/fb-info-api
- AWS EC2: Sydney (\`ap-southeast-2\`), Ubuntu 24.04; running service \`xeroxhub-fb-info-api.service\`.
- Install directory: \`/opt/xeroxhub-fb-info-api\`
- Origin application: \`127.0.0.1:8033\` (one Uvicorn worker, systemd-managed)
- Existing Nginx is used for the \`api.xeroxhub.site\` virtual host, separate from \`uid.xeroxhub.site\`.
- Cloudflare: proxied A record for \`api.xeroxhub.site\` -> EC2 current public IPv4.
- Public HTTPS \`/health\` returned HTTP 200 from the VPS through Cloudflare.
- **Pending:** \`FACEBOOK_ACCESS_TOKEN\` is not set; real Meta lookups are therefore disabled. Cloudflare zone SSL mode is \`Full\`, not \`Full (strict)\`; origin certificate verification requires additional work. The EC2 public IPv4 may change on stop/start if it is not an Elastic IP.

## Endpoints

- \`GET /health\` — non-sensitive status and provider configuration flags.
- \`GET /uid?uid=123456789&kind=auto\` — authorized ID lookup.
- \`GET /uid?username=somepage&kind=page\` — Page username lookup (when Meta permits).
- \`GET /uid?id=123456789&kind=user\` — app-authorized user lookup.
- \`POST /batch\` — \`{"identifiers":["id1","id2"],"kind":"user"}\`; default max 50.

All lookup endpoints require the \`X-API-Key\` header. A successful lookup contains \`requested\`, \`uid\`, \`name\`, \`username\`, \`profile_pic\`, \`source\`, \`cached\`, and \`checked_at\`. Unavailable fields are null. Invalid tokens, denied access, missing accounts and quota errors return clear 4xx/5xx errors, never invented data.

## Configuration and updates

Server-side secrets and limits live in \`/etc/xeroxhub-fb-info-api.env\` (root-owned, protected). The API key was randomly generated on the VPS; do not commit or paste it into public code. To activate lookups, configure a valid, approved Meta Graph API token for your permitted Pages or Facebook Login users in that server-side environment file, then run:

\`\`\`bash
sudo systemctl restart xeroxhub-fb-info-api.service
sudo systemctl status xeroxhub-fb-info-api.service --no-pager
curl -fsS https://api.xeroxhub.site/health
\`\`\`

Code updates: use GitHub and deploy the \`fb-info-api\` directory to \`/opt/xeroxhub-fb-info-api\`, install requirements in its Python virtualenv, then restart the service. Do not overwrite the existing XRIXUID service.

A Docker Compose and Caddy alternative is included for **new, isolated hosts**. Do not run that Compose stack on this VPS because Nginx already occupies ports 80/443.

## Throughput and validation

\`CLIENT_RPM=400\` caps HTTP calls per client API key per minute on the single service process. \`UPSTREAM_RPM=240\` paces Meta calls by default; increasing it requires appropriate Meta quota and actual performance testing. There is **no guarantee** of 300–400 new Facebook records/minute, even when the web server is faster, because Meta permission/rate limitations and missing fields dominate success. Cached records are faster; a missing account must not be guessed.

GitHub Actions CI: https://github.com/parvez-devs/uidhub/actions/workflows/fb-info-api-ci.yml . Unit tests use mocked Meta responses; they do not prove permission to retrieve real personal Facebook profiles.

Do not use private Facebook login cookies, CAPTCHA bypasses, proxy rotation or scraped data for this API. Keep the local API on loopback, store provider tokens only as protected server secrets and issue origin-validated HTTPS certificates before moving Cloudflare to Full (strict).
