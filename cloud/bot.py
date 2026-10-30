#!/usr/bin/env python3
"""Private Telegram control bot for the cloud XRIXUID service (no remote shell)."""
import json
import os
import time
from urllib.parse import urlencode
from urllib.request import Request, urlopen

TOKEN = os.environ.get("TG_BOT_TOKEN", "")
OWNER = os.environ.get("TG_OWNER_ID", "")
CONTROL = os.environ.get("CONTROL_TOKEN", "")
TARGET = os.environ.get("CONTROL_URL", "http://app:9100").rstrip("/")
if not TOKEN or not OWNER.isdigit() or len(CONTROL) < 24:
    raise SystemExit("Configure TG_BOT_TOKEN, TG_OWNER_ID, CONTROL_TOKEN")

MENU = {
    "inline_keyboard": [
        [{"text": "▶ Run", "callback_data": "run"},
         {"text": "⏹ Stop", "callback_data": "stop"}],
        [{"text": "📊 Status", "callback_data": "status"},
         {"text": "📜 Logs", "callback_data": "logs"}],
    ]
}


def telegram(method, **args):
    req = Request("https://api.telegram.org/bot" + TOKEN + "/" + method,
                  data=urlencode(args).encode(), method="POST")
    with urlopen(req, timeout=45) as response:
        body = json.load(response)
    if not body.get("ok"):
        raise RuntimeError("Telegram API failed")
    return body["result"]


def send(text):
    telegram("sendMessage", chat_id=OWNER, text=text[:3900],
             reply_markup=json.dumps(MENU, ensure_ascii=False))


def control(path, method="GET"):
    req = Request(TARGET + "/" + path,
                  headers={"Authorization": "Bearer " + CONTROL},
                  data=b"" if method == "POST" else None,
                  method=method)
    with urlopen(req, timeout=210) as response:
        return json.load(response)


def perform(action):
    if action in ("start", "help"):
        send("🤖 XRIXUID Cloud Control\n/run — start app\n/stop — stop app\n/status — check app\n/logs — latest app logs")
    elif action == "status":
        data = control("status")
        send("📊 XRIXUID Cloud\nApp: " +
             ("✅ Running" if data["running"] else "⏹ Stopped") +
             ("\n⚠️ " + data["error"] if data.get("error") else ""))
    elif action == "logs":
        send("📜 XRIXUID logs\n" + control("logs").get("logs", "No logs"))
    elif action in ("run", "stop"):
        send("⏳ Processing /" + action + " ...")
        result = control("run" if action == "run" else "stop", "POST")
        send(("✅ " if result.get("ok") else "❌ ") + result.get("message", "Done"))
    else:
        send("Unknown command. Send /start")


def main():
    print("XRIXUID Telegram worker started", flush=True)
    offset = 0
    delay = 2
    while True:
        try:
            updates = telegram(
                "getUpdates", offset=str(offset), timeout="30",
                allowed_updates=json.dumps(["message", "callback_query"]),
            )
            delay = 2
            for update in updates:
                offset = max(offset, update["update_id"] + 1)
                callback = update.get("callback_query")
                if callback:
                    chat = callback.get("message", {}).get("chat", {})
                    source_id = str(callback.get("from", {}).get("id"))
                    action = callback.get("data", "")
                    if source_id != OWNER or chat.get("type") != "private" or str(chat.get("id")) != OWNER:
                        continue
                    try:
                        telegram("answerCallbackQuery", callback_query_id=callback["id"])
                    except Exception:
                        pass
                    if action not in ("run", "stop", "status", "logs"):
                        continue
                else:
                    message = update.get("message", {})
                    chat = message.get("chat", {})
                    source_id = str(message.get("from", {}).get("id"))
                    if source_id != OWNER or chat.get("type") != "private" or str(chat.get("id")) != OWNER:
                        continue
                    action = message.get("text", "").split(" ")[0].split("@")[0].removeprefix("/").lower()
                try:
                    perform(action)
                except Exception as ex:
                    print("Command failed:", type(ex).__name__, flush=True)
                    try:
                        send("❌ Action failed. Check cloud container logs.")
                    except Exception:
                        pass
        except Exception as ex:
            print("Telegram polling issue:", type(ex).__name__, flush=True)
            time.sleep(delay)
            delay = min(60, delay * 2)


if __name__ == "__main__":
    main()
