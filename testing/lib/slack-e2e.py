#!/usr/bin/env python3
"""The served bot's routes and Slack's events, for testing/e2e.test.sh.

    slack-e2e.py born      <url> <values.json>
    slack-e2e.py connected <url> <values.json>   (SLACK_STANDIN, SIGNING_SECRET,
                                                  BOT_TOKEN, DEV_LOG in the env)

`born` is the Worker as a bootstrap produces it, no key stored: the routes,
and Slack's door saying it is not connected without doing any work.
`connected` is the same Worker with Slack's two keys stored and its Web API
pointed at testing/lib/fake-slack-api.py: every request Slack can send, signed
as Slack signs it (HMAC-SHA256 over v0:<ts>:<body>), and what the bot then
asked of Slack, read back from the stand-in. The model is the Workers AI
stand-in (testing/lib/fake-workers-ai.js), whose calls the bot's wrangler log
records.
"""
import hashlib
import hmac
import json
import os
import sys
import time
import urllib.error
import urllib.request

mode, base, values_path = sys.argv[1], sys.argv[2], sys.argv[3]
name = json.load(open(values_path))["productname"]
problems = []


def bad(m):
    problems.append(m)


def req(method, path, body=None, headers=None, base_url=None):
    data = body.encode() if isinstance(body, str) else body
    r = urllib.request.Request((base_url or base) + path, data=data, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(r, timeout=30) as resp:
            return resp.status, dict(resp.headers), resp.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read().decode()


def signed(body, secret=None, ts=None, extra=None):
    ts = str(ts if ts is not None else int(time.time()))
    sig = "v0=" + hmac.new((secret or os.environ["SIGNING_SECRET"]).encode(), f"v0:{ts}:{body}".encode(), hashlib.sha256).hexdigest()
    h = {"content-type": "application/json", "x-slack-request-timestamp": ts, "x-slack-signature": sig}
    h.update(extra or {})
    return h


def event(ev):
    return json.dumps({"type": "event_callback", "event": ev})


def finish(summary):
    if problems:
        for p in problems:
            print(f"  ✕ {p}", file=sys.stderr)
        sys.exit(1)
    print(f"   {summary}")


# ── what every mode answers the same way ──────────────────────────────────
s, h, body = req("GET", "/")
try:
    welcome = json.loads(body)
except ValueError:
    welcome = {}
    bad(f"/ is not JSON: {body[:80]!r}")
if s != 200 or welcome.get("message") != f"{name} — an AI chatbot for Slack":
    bad(f"/ does not name the bot: {s} {body[:160]!r}")
if welcome.get("endpoints") != {"events": "/api/events", "health": "/health"}:
    bad(f"/ does not give the bot's endpoints: {body[:160]!r}")

s, h, body = req("GET", "/health")
try:
    health = json.loads(body)
except ValueError:
    health = {}
    bad(f"/health is not JSON: {body[:80]!r}")
if s != 200 or health.get("status") != "ok" or health.get("name") != name:
    bad(f"/health does not name the bot: {s} {body[:200]!r}")
if health.get("environment") != "stage":
    bad(f"/health reports environment {health.get('environment')!r}, not 'stage'")
if health.get("model") != {"provider": "workers-ai", "id": "@cf/moonshotai/kimi-k2.6"}:
    bad(f"/health's model is {health.get('model')!r}, not Workers AI")
if health.get("tools") != ["getWeather", "throwDice", "bash", "readFile", "writeFile"]:
    bad(f"/health's tools are {health.get('tools')!r} (no searchWeb without Exa's key)")

s, _, _ = req("GET", "/no-such-route")
if s != 404:
    bad(f"/no-such-route answered {s}, want 404")

if mode == "born":
    if health.get("slack") != "not connected" or welcome.get("slack") != "not connected":
        bad(f"as born, Slack is reported {health.get('slack')!r} / {welcome.get('slack')!r}")
    # Before Slack is connected the door says so, signed or not, and does no work.
    for headers in ({"content-type": "application/json"}, signed('{"type":"url_verification","challenge":"x"}', secret="any")):
        s, _, body = req("POST", "/api/events", '{"type":"url_verification","challenge":"x"}', headers)
        try:
            answer = json.loads(body)
        except ValueError:
            answer = {}
        if s != 503 or answer.get("error") != "slack_not_connected":
            bad(f"as born, POST /api/events answered {s} {body[:120]!r}, want 503 slack_not_connected")
    finish(f"/ and /health name {name!r} in stage, Slack not connected, Workers AI the model; an unknown path 404; /api/events 503 slack_not_connected")
    sys.exit(0)

# ── connected ─────────────────────────────────────────────────────────────
standin = os.environ["SLACK_STANDIN"]
dev_log = os.environ["DEV_LOG"]


def calls():
    _, _, body = req("GET", "/calls", base_url=standin)
    return json.loads(body)


def wait_for(pred, what, seconds=40):
    end = time.time() + seconds
    while time.time() < end:
        got = calls()
        if pred(got):
            return got
        time.sleep(0.5)
    bad(f"timed out waiting for {what}; the stand-in saw: {json.dumps(calls())[:600]}")
    return calls()


if health.get("slack") != "connected":
    bad(f"connected, /health reports Slack {health.get('slack')!r}")
if os.environ["SIGNING_SECRET"] in json.dumps(health) or os.environ["BOT_TOKEN"] in json.dumps(health):
    bad("/health printed a secret value")

# 1. Refused before any work: unsigned, forged, stale, wrongly keyed.
challenge = json.dumps({"type": "url_verification", "challenge": "3eZbrw1aBm2rZgRNFdxV2595E9CY3gmdALWMmHkvFXO7tYXAYM8P"})
refusals = {
    "unsigned": {"content-type": "application/json"},
    "forged": {**signed(challenge), "x-slack-signature": "v0=" + "0" * 64},
    "stale": signed(challenge, ts=int(time.time()) - 600),
    "another app's secret": signed(challenge, secret="another-apps-signing-secret"),
}
for what, headers in refusals.items():
    s, _, body = req("POST", "/api/events", challenge, headers)
    if s != 400 or body != "Invalid request":
        bad(f"a {what} request answered {s} {body[:80]!r}, want 400 Invalid request")
forged_mention = event({"type": "app_mention", "channel": "C9", "user": "U9", "text": "<@UBOT> run `ls`", "ts": "1700000000.009999"})
s, _, _ = req("POST", "/api/events", forged_mention, signed(forged_mention, secret="another-apps-signing-secret"))
if s != 400:
    bad(f"a forged app mention answered {s}, want 400")
time.sleep(1)
if calls():
    bad(f"a refused request reached Slack: {json.dumps(calls())[:300]}")

# 2. Slack's URL verification, once signed.
s, _, body = req("POST", "/api/events", challenge, signed(challenge))
if s != 200 or body != "3eZbrw1aBm2rZgRNFdxV2595E9CY3gmdALWMmHkvFXO7tYXAYM8P":
    bad(f"the signed URL verification answered {s} {body[:80]!r}")

# 3. A retry is acknowledged, not answered again.
retry = event({"type": "app_mention", "channel": "C1", "user": "U1", "text": "<@UBOT> hi", "ts": "1700000000.000010"})
s, h, body = req("POST", "/api/events", retry, signed(retry, extra={"x-slack-retry-num": "1", "x-slack-retry-reason": "http_timeout"}))
if s != 200 or {k.lower(): v for k, v in h.items()}.get("x-slack-no-retry") != "1":
    bad(f"a retry answered {s} {h}")
time.sleep(1.5)
if calls():
    bad(f"a retry was answered: {json.dumps(calls())[:300]}")

# 4. An app mention: acknowledged at once, answered after, in its thread,
#    through the policy (`ls` is allowed) and just-bash's in-memory files.
mention = event({"type": "app_mention", "channel": "C123", "user": "U1", "text": "<@UBOT> please run `ls`", "ts": "1700000000.000001"})
t0 = time.time()
s, _, body = req("POST", "/api/events", mention, signed(mention))
ack = time.time() - t0
if s != 200 or body != "Success!":
    bad(f"the app mention answered {s} {body[:80]!r}")
if ack > 3:
    bad(f"the app mention took {ack:.1f}s to acknowledge (Slack allows 3)")
got = wait_for(lambda c: any(x["method"] == "chat.update" for x in c), "the mention's answer")
methods = [x["method"] for x in got]
if methods[:3] != ["auth.test", "chat.postMessage", "chat.update"]:
    bad(f"the mention made {methods}, want auth.test, chat.postMessage, chat.update")
if not all(x["auth"] for x in got):
    bad("a Web API call did not carry the bot's own token")
post = next((x for x in got if x["method"] == "chat.postMessage"), {"args": {}})
if post["args"].get("channel") != "C123" or post["args"].get("thread_ts") != "1700000000.000001" or post["args"].get("text") != "is thinking...":
    bad(f"the status message was {post['args']}")
answer = next((x for x in got if x["method"] == "chat.update"), {"args": {}})["args"].get("text", "")
if "README.md" not in answer or "notes.txt" not in answer or not answer.endswith("_🔧 bash_"):
    bad(f"the mention's answer was {answer!r}")
n = len(got)

# 5. A command the policy refuses is relayed verbatim, not the model's text.
deny = event({"type": "app_mention", "channel": "C123", "user": "U1", "text": "<@UBOT> please run `rm notes.txt`", "ts": "1700000000.000002"})
req("POST", "/api/events", deny, signed(deny))
got = wait_for(lambda c: sum(1 for x in c if x["method"] == "chat.update") >= 2, "the refusal")
refusal = [x for x in got if x["method"] == "chat.update"][-1]["args"].get("text", "")
if not refusal.startswith("`rm` is not an allowed command. Allowed: ") or not refusal.endswith("_🔧 bash (blocked by policy)_"):
    bad(f"the refusal was {refusal!r}")
n = len(got)

# 6. A direct message, answered in its assistant thread from the thread's history.
req("POST", "/seed", json.dumps({"ts": "1700000000.000500", "messages": [
    {"user": "U1", "text": "first question", "ts": "1700000000.000500"},
    {"bot_id": "BBOT", "text": "first answer", "ts": "1700000000.000501"},
    {"user": "U1", "text": "hello there", "ts": "1700000000.000502"},
]}), {"content-type": "application/json"}, base_url=standin)
dm = event({"type": "message", "channel_type": "im", "channel": "D1", "user": "U1", "text": "hello there", "ts": "1700000000.000502", "thread_ts": "1700000000.000500"})
req("POST", "/api/events", dm, signed(dm))
got = wait_for(lambda c: [x["method"] for x in c[n:]][-1:] == ["assistant.threads.setStatus"] and len(c) - n >= 5, "the DM's answer")
dm_calls = got[n:]
if [x["method"] for x in dm_calls] != ["auth.test", "assistant.threads.setStatus", "conversations.replies", "chat.postMessage", "assistant.threads.setStatus"]:
    bad(f"the DM made {[x['method'] for x in dm_calls]}")
else:
    if dm_calls[1]["args"].get("status") != "is thinking..." or dm_calls[4]["args"].get("status") != "":
        bad(f"the DM's status was not set then cleared: {dm_calls[1]['args']} / {dm_calls[4]['args']}")
    reply = dm_calls[3]["args"]
    if reply.get("channel") != "D1" or reply.get("thread_ts") != "1700000000.000500" or reply.get("text") != "Echo: hello there\n\n_🔧 none_":
        bad(f"the DM's answer was {reply}")
n = len(got)

# 7. A new assistant thread is greeted with the template's suggested prompts.
started = event({"type": "assistant_thread_started", "assistant_thread": {"channel_id": "D1", "thread_ts": "1700000000.000900"}})
req("POST", "/api/events", started, signed(started))
got = wait_for(lambda c: any(x["method"] == "assistant.threads.setSuggestedPrompts" for x in c[n:]), "the thread's greeting")
prompts = next(x for x in got[n:] if x["method"] == "assistant.threads.setSuggestedPrompts")["args"].get("prompts")
if prompts != [
    {"title": "Get the weather", "message": "What is the current weather in London?"},
    {"title": "Get the news", "message": "What is the latest Premier League news from the BBC?"},
]:
    bad(f"the suggested prompts were {prompts!r}")

# What the model was asked: Workers AI's model, the tools without searchWeb,
# and a second turn carrying the tool's result.
log = open(dev_log, encoding="utf-8", errors="replace").read()
asked = [json.loads(line.split("fake-workers-ai ", 1)[1]) for line in log.splitlines() if "fake-workers-ai {" in line]
if not asked or any(a["model"] != "@cf/moonshotai/kimi-k2.6" for a in asked):
    bad(f"the model asked was not Workers AI's: {asked[:2]}")
if any("searchWeb" in a["tools"] for a in asked):
    bad("searchWeb was offered without Exa's key")
if not any(a["roles"][-1:] == ["tool"] for a in asked):
    bad("no model call carried a tool's result back")

finish(f"refused 5 bad requests with no call made; the challenge; a retry acknowledged only; a mention answered in {ack:.2f}s ack + thread (bash ls); a policy refusal relayed; a DM from its history; a thread greeted — {len(asked)} model calls")
