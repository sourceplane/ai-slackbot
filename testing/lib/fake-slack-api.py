#!/usr/bin/env python3
"""A stand-in for the slice of Slack's Web API the bot calls, for the e2e only.

The bot reaches Slack through @slack/web-api's WebClient, whose base URL the
Worker takes from SLACK_API_URL (unset in a product: Slack's own). Pointed at
this server, every Web API call the bot makes lands here instead:

    auth.test                          → the bot's own user id (UBOT)
    chat.postMessage / chat.update     → recorded, answered with a ts
    assistant.threads.setStatus        → recorded
    assistant.threads.setSuggestedPrompts → recorded
    conversations.replies              → the thread the e2e seeded (POST /seed)

Every call must carry `Authorization: Bearer <the token the e2e stored>` —
the bot's SLACK_BOT_TOKEN — or it is refused with `invalid_auth`, as Slack
refuses it. GET /calls returns what was asked, in order, for the e2e to
assert against. The WebClient posts form-encoded bodies; JSON is accepted too.

    fake-slack-api.py <port> <expected-token>
"""
import json
import sys
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1])
TOKEN = sys.argv[2]
CALLS = []
THREADS = {}
LOCK = threading.Lock()
TS = [1700000000]


def next_ts():
    with LOCK:
        TS[0] += 1
        return f"{TS[0]}.000100"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json; charset=utf-8")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/calls":
            with LOCK:
                return self.reply(200, CALLS)
        return self.reply(404, {"ok": False, "error": "unknown_method"})

    def do_POST(self):
        length = int(self.headers.get("content-length") or 0)
        raw = self.rfile.read(length).decode() if length else ""
        if self.path == "/seed":
            seed = json.loads(raw)
            with LOCK:
                THREADS[seed["ts"]] = seed["messages"]
            return self.reply(200, {"ok": True})
        if not self.path.startswith("/api/"):
            return self.reply(404, {"ok": False, "error": "unknown_method"})
        method = self.path[len("/api/"):].split("?")[0]
        ctype = (self.headers.get("content-type") or "").split(";")[0].strip()
        if ctype == "application/json":
            args = json.loads(raw or "{}")
        else:
            args = {k: v[-1] for k, v in urllib.parse.parse_qs(raw, keep_blank_values=True).items()}
            for k, v in list(args.items()):
                if isinstance(v, str) and v[:1] in "[{":
                    try:
                        args[k] = json.loads(v)
                    except ValueError:
                        pass
        auth = self.headers.get("authorization") or ""
        with LOCK:
            CALLS.append({"method": method, "args": args, "auth": auth == f"Bearer {TOKEN}"})
        if auth != f"Bearer {TOKEN}":
            return self.reply(200, {"ok": False, "error": "invalid_auth"})
        if method == "auth.test":
            return self.reply(200, {"ok": True, "user_id": "UBOT", "bot_id": "BBOT"})
        if method in ("chat.postMessage", "chat.update"):
            return self.reply(200, {"ok": True, "channel": args.get("channel"), "ts": args.get("ts") or next_ts()})
        if method in ("assistant.threads.setStatus", "assistant.threads.setSuggestedPrompts"):
            return self.reply(200, {"ok": True})
        if method == "conversations.replies":
            with LOCK:
                msgs = THREADS.get(args.get("ts"), [])
            return self.reply(200, {"ok": True, "messages": msgs})
        return self.reply(200, {"ok": False, "error": "unknown_method"})


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
