#!/usr/bin/env python3
"""Owner-only Telegram remote control for local XRIXUID Termux sessions.

No Telegram libraries required: uses the official Bot API over HTTPS.
Only four fixed operations are permitted. No arbitrary remote shell.
"""
from __future__ import annotations

import concurrent.futures
import fcntl
import http.client
import json
import logging
import os
from pathlib import Path
import re
import subprocess
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

HOME = Path.home()
CONFIG = HOME / ".xrixuid-tg.env"
OFFSET_FILE = HOME / ".xrixuid-tg.offset"
LOCK_FILE = HOME / ".xrixuid-tg.lock"
LAUNCHER = HOME / "xrixuid-termux.sh"
API_LOG = HOME / "xrixuid-api.log"
WEB_LOG = HOME / "xrixuid-web.log"

logging.basicConfig(level=logging.INFO, format="%(asctime)s [TG] %(message)s")
logger = logging.getLogger("xrixuid-tg")


def get_config() -> tuple[str, int]:
    if not CONFIG.is_file():
        raise RuntimeError(f"Configuration is missing: {CONFIG}")
    settings = {}
    for line in CONFIG.read_text(encoding="utf-8").splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            k, v = line.split("=", 1)
            settings[k.strip()] = v.strip()
    token = settings.get("TG_BOT_TOKEN", "")
    user = settings.get("TG_OWNER_ID", "")
    if not re.fullmatch(r"[0-9]{5,}:[A-Za-z0-9_-]{20,}", token):
        raise ValueError("Invalid bot token in local config")
    if not user.isdigit() or int(user) <= 0:
        raise ValueError("Invalid numeric Telegram owner ID")
    return token, int(user)


TOKEN, OWNER_ID = get_config()
API_BASE = f"https://api.telegram.org/bot{TOKEN}/"
BUTTONS = json.dumps({
    "inline_keyboard": [
        [{"text": "▶ Run", "callback_data": "run"},
         {"text": "⏹ Stop", "callback_data": "stop"}],
        [{"text": "📊 Status", "callback_data": "status"},
         {"text": "📜 Logs", "callback_data": "logs"}],
    ]
}, ensure_ascii=False)
POOL = concurrent.futures.ThreadPoolExecutor(max_workers=1)
BUSY = False


def api(method: str, **kwargs):
    payload = urlencode(kwargs).encode("utf-8")
    req = Request(API_BASE + method, data=payload, method="POST")
    with urlopen(req, timeout=42) as response:
        result = json.loads(response.read())
    if not result.get("ok"):
        raise RuntimeError(f"Telegram Bot API rejected {method}")
    return result["result"]


def message(chat: int, text: str, menu: bool = False) -> None:
    args = {"chat_id": str(chat), "text": text[:3900], "disable_web_page_preview": "true"}
    if menu:
        args["reply_markup"] = BUTTONS
    try:
        api("sendMessage", **args)
    except Exception as err:
        logger.error("Could not deliver reply: %s", type(err).__name__)


def subprocess_text(argv: list[str], timeout: int = 12) -> tuple[int, str]:
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, check=False)
        return p.returncode, (p.stdout + "\n" + p.stderr).strip()
    except subprocess.TimeoutExpired:
        return 124, "Operation timed out."
    except OSError as err:
        return 127, f"Cannot launch command ({type(err).__name__})."


def session_running(name: str) -> bool:
    return subprocess.run(
        ["tmux", "has-session", "-t", name],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        timeout=3, check=False,
    ).returncode == 0


def http_status(port: int) -> str:
    try:
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
        conn.request("GET", "/")
        response = conn.getresponse()
        code = response.status
        conn.close()
        return f"HTTP {code}"
    except (OSError, TimeoutError):
        return "not responding"


def status_report() -> str:
    db_code, db_response = subprocess_text(
        ["pg_isready", "-h", "127.0.0.1", "-p", "5432"], 4
    )
    return (
        "📊 XRIXUID Termux status\n\n"
        f"PostgreSQL: {'✅ ready' if db_code == 0 else '❌ offline'}\n"
        f"API session: {'✅ running' if session_running('xrixuid-api') else '❌ stopped'}\n"
        f"API port 8080: {http_status(8080)}\n"
        f"Web session: {'✅ running' if session_running('xrixuid-web') else '❌ stopped'}\n"
        f"Web port 3000: {http_status(3000)}\n\n"
        "Dashboard: http://127.0.0.1:3000\n"
        "(This address opens only on the phone hosting XRIXUID.)"
    )


def sanitize(text: str) -> str:
    text = text.replace(TOKEN, "[BOT_TOKEN_REDACTED]")
    # Remove likely credentials from accidental application log dumps.
    text = re.sub(
        r"(?i)(authorization|cookie|set-cookie|password|api[_-]?key|admin[_-]?key|"
        r"access[_-]?token|refresh[_-]?token|jwt|secret)\s*[:=]\s*"
        r"(?:\"[^\"]*\"|'[^']*'|[^\s,}\]]+)",
        r"\1=[REDACTED]", text,
    )
    return text


def tail_logs() -> str:
    sections = []
    for title, path in [("API", API_LOG), ("Web", WEB_LOG)]:
        if not path.is_file():
            sections.append(f"[{title}] No log file yet.")
            continue
        _, content = subprocess_text(["tail", "-n", "20", str(path)], 5)
        sections.append(f"[{title}]\n{sanitize(content)[-1550:]}")
    return "📜 XRIXUID latest logs\n\n" + "\n\n".join(sections)


def run_action(chat: int, action: str) -> None:
    global BUSY
    try:
        if not LAUNCHER.is_file():
            message(chat, "❌ Launcher missing. Install XRIXUID first.")
            return
        cmd = "start" if action == "run" else "stop"
        rc, output = subprocess_text(["bash", str(LAUNCHER), cmd], 240)
        if rc == 0:
            message(chat, f"{'✅ Started' if action == 'run' else '⏹ Stopped'} XRIXUID.\n\n{status_report()}", menu=True)
        else:
            message(chat, f"❌ {action} failed (exit {rc}).\n\n{sanitize(output)[-2000:]}")
    except Exception as err:
        logger.error("Local action failed: %s", type(err).__name__)
        message(chat, f"❌ Local action failed: {type(err).__name__}")
    finally:
        BUSY = False


def execute(chat: int, action: str) -> None:
    global BUSY
    if action in ("start", "help"):
        message(chat, "🤖 XRIXUID controller\n\n/run — start API + frontend\n/stop — stop both\n/status — check services\n/logs — show recent logs\n\nOnly the configured owner can use this bot.", menu=True)
    elif action == "status":
        message(chat, status_report(), menu=True)
    elif action == "logs":
        message(chat, tail_logs(), menu=True)
    elif action in ("run", "stop"):
        if BUSY:
            message(chat, "⏳ Another start/stop operation is already in progress.")
            return
        BUSY = True
        message(chat, "⏳ Executing " + action + "…")
        POOL.submit(run_action, chat, action)
    else:
        message(chat, "Unknown command. Use /start to view controls.", menu=True)


def load_offset() -> int:
    try:
        return max(0, int(OFFSET_FILE.read_text().strip()))
    except (OSError, ValueError):
        return 0


def save_offset(offset: int) -> None:
    tmp = OFFSET_FILE.with_suffix(".tmp")
    tmp.write_text(str(offset) + "\n", encoding="ascii")
    os.replace(tmp, OFFSET_FILE)


def handle_update(update: dict) -> None:
    callback = update.get("callback_query")
    if callback:
        uid = callback.get("from", {}).get("id")
        chat = callback.get("message", {}).get("chat", {})
        if uid != OWNER_ID or chat.get("type") != "private" or chat.get("id") != OWNER_ID:
            return
        try:
            api("answerCallbackQuery", callback_query_id=callback["id"])
        except Exception:
            pass
        action = callback.get("data", "")
        if action in {"run", "stop", "status", "logs"}:
            execute(chat["id"], action)
        return

    msg = update.get("message", {})
    uid = msg.get("from", {}).get("id")
    chat = msg.get("chat", {})
    if uid != OWNER_ID or chat.get("type") != "private" or chat.get("id") != OWNER_ID:
        return
    cmd = msg.get("text", "").strip().split(" ", 1)[0].split("@", 1)[0].lower()
    if cmd.startswith("/"):
        execute(chat["id"], cmd[1:])


def main() -> None:
    lock_fp = LOCK_FILE.open("w")
    try:
        fcntl.flock(lock_fp, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise SystemExit("Telegram controller already running.")
    me = api("getMe")
    logger.info("Connected to @%s; owner ID configured.", me.get("username", "unknown"))
    offset = load_offset()
    delay = 2
    while True:
        try:
            updates = api(
                "getUpdates", offset=str(offset), timeout="25", limit="50",
                allowed_updates=json.dumps(["message", "callback_query"]),
            )
            delay = 2
            for update in updates:
                offset = max(offset, update["update_id"] + 1)
                save_offset(offset)
                handle_update(update)
        except KeyboardInterrupt:
            break
        except (HTTPError, URLError, TimeoutError, OSError, RuntimeError, ValueError) as err:
            # Never print raw HTTP exceptions; URLs contain the bot token.
            logger.warning("Polling problem (%s); retry in %ds.", type(err).__name__, delay)
            time.sleep(delay)
            delay = min(delay * 2, 60)


if __name__ == "__main__":
    main()
