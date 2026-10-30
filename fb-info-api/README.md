# XEROXHUB FB Info API

A FastAPI service for permitted Facebook Page and consenting-user lookups using the official Meta Graph API.

API: `GET /uid?uid=123`, `GET /uid?username=page&kind=page`, `POST /batch`, `GET /health`. Responses include `uid`, `name`, `username` (when available), `profile_pic` (when authorized), and clear error statuses. Authentication uses an `X-API-Key` header.

Deployment target: Ubuntu EC2 VPS, Docker Compose + Caddy TLS, Cloudflare proxied A record for `api.xeroxhub.site` only after verifying the static public IP. `FACEBOOK_ACCESS_TOKEN` and `API_KEYS` must be configured as environment secrets.

Facebook does not permit universal discovery of arbitrary personal accounts through the official API. Access depends on token scopes, entity type, user consent, and Meta approval. Throughput depends on upstream quotas; `400 requests/min` at the HTTP layer is not a guarantee of 400 valid Facebook profiles.

A tested, standalone source bundle is provided in the ChatGPT conversation. Production deployment is blocked until AWS EC2/SSM permissions, verified origin IP and authorized Meta token are available.
