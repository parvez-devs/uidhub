# XRIXUID Cloud + Telegram Controller

This is an **optional VPS deployment**, independent of the original Termux installer at `termux/xrixuid-termux.sh`. Nothing in the original installer was changed.

## Architecture

- `db`: persistent PostgreSQL database (not publicly published)
- `app`: built XRIXUID frontend + Express API together on internal port 3000; process supervisor listens on internal-only port 9100
- `bot`: standalone Python Telegram long-polling process; only the configured numeric Telegram owner can invoke fixed actions
- `web`: Caddy HTTPS reverse proxy; protects the public website with HTTP Basic authentication

Telegram commands: `/start`, `/run`, `/stop`, `/status`, `/logs`. `/stop` stops just the XRIXUID Node process; the bot, database and supervisor remain running, allowing `/run` afterwards.

The bot cannot execute arbitrary shell commands. The supervisor does **not** mount the Docker socket.

## Prepare

1. Get an Ubuntu VPS (a dedicated cloud server; this is not a Termux deployment).
2. Install Docker Engine, Docker Compose v2, Git and OpenSSL on the VPS.
3. Create a Telegram bot with @BotFather; identify your numeric Telegram user ID.
4. Point a DNS A record, for example `operator.example.com`, at the VPS public IPv4.
5. Permit inbound TCP 80/443 (and optionally UDP 443) on your VPS firewall/security group. Never publicly expose the PostgreSQL or control port.

## Install

```bash
git clone https://github.com/parvez-devs/uidhub.git
cd uidhub
bash cloud/setup.sh
```

The installer prompts for domain, Telegram bot token and numeric owner ID, generates independent random secrets, saves them in `cloud/.env` (mode 600, gitignored), generates a one-time site login password and deploys the stack.

After DNS propagates and Caddy obtains a certificate, visit `https://YOUR_DOMAIN`. Open the Telegram bot privately and send `/start`.

## Management

```bash
docker compose --env-file cloud/.env -f cloud/compose.yaml ps
docker compose --env-file cloud/.env -f cloud/compose.yaml logs --tail=100 app bot web
docker compose --env-file cloud/.env -f cloud/compose.yaml restart bot
docker compose --env-file cloud/.env -f cloud/compose.yaml down
```

Do **not** use `down -v` unless you intend to erase the hosted PostgreSQL data.

## Important warnings

- Hosting creates a **new PostgreSQL database**. Your phone's local PostgreSQL records are not automatically copied over. To migrate, export on the phone with `pg_dump`, then restore to the hosted database after backup/review.
- The app source for this optional deployment is taken from the repository's pre-existing public `xrixuid.zip` and copies only application code, not `.replit`, `.local`, `.git` or `.config`. **Existing ZIPs may already contain leaked credentials**. Rotate any Facebook sessions, JWTs, admin secrets and keys present in earlier uploads. Prefer replacing the source archive with a sanitized version and pin its checksum before production.
- Cloud deployment has not been executed or validated on a live VPS. Confirm the build, runtime logs, Telegram ownership controls and real UID fetching before relying on it.
- This VPS approach avoids relying on a phone staying awake but still depends on the VPS running and the hosting bill/credits.
