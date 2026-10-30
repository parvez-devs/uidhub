#!/usr/bin/env python3
"""Minimal supervisor: the Telegram worker can stop/start only XRIXUID, never itself."""
import collections
import hmac
import http.server
import json
import os
import pathlib
import re
import signal
import subprocess
import threading
import time
import urllib.request

ROOT = pathlib.Path("/srv/app")
LOG = pathlib.Path("/srv/logs/xrixuid.log")
LOG.parent.mkdir(parents=True, exist_ok=True)
SECRET = os.environ.get("CONTROL_TOKEN", "")
if len(SECRET) < 24:
    raise SystemExit("CONTROL_TOKEN is required (at least 24 characters)")
LOCK = threading.RLock()
STATE = {"proc": None, "enabled": True, "last_exit": None, "error": ""}
PORT = int(os.getenv("CONTROL_PORT", "9100"))


def log(msg):
    with LOG.open("a", encoding="utf-8") as out:
        out.write(f"[control] {time.strftime('%Y-%m-%d %H:%M:%S')} {msg}\n")


def db_sync():
    try:
        with LOG.open("a", encoding="utf-8") as out:
            result = subprocess.run(
                ["pnpm", "--filter", "@workspace/db", "run", "push"],
                cwd=ROOT, stdout=out, stderr=subprocess.STDOUT, timeout=180,
                check=False,
            )
        return result.returncode == 0
    except (OSError, subprocess.TimeoutExpired) as ex:
        log(f"Database setup failed ({type(ex).__name__})")
        return False


def start_app():
    with LOCK:
        current = STATE["proc"]
        if current is not None and current.poll() is None:
            return True, "already running"
        STATE["enabled"] = True
        if not db_sync():
            STATE["error"] = "Database migration failed. Check /logs"
            return False, STATE["error"]
        env = os.environ.copy()
        env.update({"NODE_ENV": "production", "PORT": "3000",
                    "WEB_DIST": "/srv/app/artifacts/uid-web/dist/public"})
        with LOG.open("a", encoding="utf-8") as out:
            STATE["proc"] = subprocess.Popen(
                ["node", "--enable-source-maps", "artifacts/api-server/dist/index.mjs"],
                cwd=ROOT, env=env, stdout=out, stderr=subprocess.STDOUT,
                start_new_session=True,
            )
        STATE["error"] = ""
        log(f"XRIXUID started with PID {STATE['proc'].pid}")
        return True, "started"


def stop_app():
    with LOCK:
        STATE["enabled"] = False
        p = STATE["proc"]
        if p is not None and p.poll() is None:
            os.killpg(p.pid, signal.SIGTERM)
            try:
                p.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(p.pid, signal.SIGKILL)
                p.wait()
        STATE["last_exit"] = p.returncode if p else None
        STATE["proc"] = None
        log("XRIXUID stopped by remote control")
        return True, "stopped"


def monitor():
    while True:
        time.sleep(8)
        with LOCK:
            p = STATE["proc"]
            if p and p.poll() is not None:
                STATE["last_exit"] = p.returncode
                STATE["proc"] = None
                log(f"XRIXUID exited with code {p.returncode}")
                if STATE["enabled"]:
                    time.sleep(4)
                    start_app()


def read_logs():
    try:
        with LOG.open("r", encoding="utf-8", errors="replace") as stream:
            last = "".join(collections.deque(stream, maxlen=30))[-5000:]
        for env_key in ["CONTROL_TOKEN", "DATABASE_URL", "ADMIN_KEY", "POSTGRES_PASSWORD"]:
            value = os.environ.get(env_key, "")
            if value:
                last = last.replace(value, "[REDACTED]")
        return re.sub(
            r"(?i)(cookie|authorization|password|secret|access_token)\\s*[:=]\\s*[^\\s,;]+",
            r"\\1=[REDACTED]", last,
        )
    except OSError:
        return "No logs yet."


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        return

    def send(self, status, payload):
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def authorized(self):
        if self.path == "/healthz":
            return True
        expected = "Bearer " + SECRET
        return hmac.compare_digest(self.headers.get("Authorization", ""), expected)

    def do_GET(self):
        if not self.authorized():
            return self.send(403, {"error": "forbidden"})
        if self.path == "/healthz":
            return self.send(200, {"ok": True})
        if self.path == "/status":
            with LOCK:
                p = STATE["proc"]
                running = p is not None and p.poll() is None
                return self.send(200, {
                    "running": running, "enabled": STATE["enabled"],
                    "pid": p.pid if running else None,
                    "last_exit": STATE["last_exit"], "error": STATE["error"],
                })
        if self.path == "/logs":
            return self.send(200, {"logs": read_logs()})
        self.send(404, {"error": "not found"})

    def do_POST(self):
        if not self.authorized():
            return self.send(403, {"error": "forbidden"})
        if self.path == "/run":
            ok, detail = start_app()
            return self.send(200 if ok else 503, {"ok": ok, "message": detail})
        if self.path == "/stop":
            ok, detail = stop_app()
            return self.send(200 if ok else 503, {"ok": ok, "message": detail})
        self.send(404, {"error": "not found"})


if __name__ == "__main__":
    threading.Thread(target=monitor, daemon=True).start()
    threading.Thread(target=lambda: start_app(), daemon=True).start()
    print("XRIXUID cloud supervisor listening on internal port", PORT, flush=True)
    http.server.ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
