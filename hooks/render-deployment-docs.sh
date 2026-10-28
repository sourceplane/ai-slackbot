#!/usr/bin/env bash
# Render the Slack bot's LIVE-DEPLOYMENT documentation from verified state.
# Called by phase 02-docs as a `run:` hook (and safe to run by hand, from the
# server's checkout). Idempotent: the generated file and the README section are
# fully re-rendered on every run, so re-running after a redeploy or a custom
# domain refreshes them.
#
#   hooks/render-deployment-docs.sh <out> <workspace> <baseline-dir>
#
# What it writes (in <out>):
#   ai/context/deployment.md   — REGENERATED: URLs with live probe results,
#                                identity, and the secrets the deployment
#                                uses BY NAME
#   ai/context/operations.md   — healed from the baseline's copy if absent
#                                (the static operating contract; never rewritten)
#   README.md                  — the section between <!-- 02-docs:begin/end -->
#                                is replaced (appended after the title if the
#                                README predates the markers)
#
# No secret VALUE is ever read or written here — secrets are named, not read.
#
# IT ASKS THE PLATFORM NOTHING. The record used to carry the workspace's slug,
# its secrets listed per rung and its integrations — five CLI calls, one after
# another, from the build box — and all of it is what the console shows live
# and this file could only show as it was the day it was written. The record
# keeps what the repository is the right place for: the identity the code
# names, what answered at the URLs, and where to look for the rest.
set -euo pipefail

out="${1:?usage: render-deployment-docs.sh <out> <workspace> <baseline-dir>}"
ws="${2:-}"
L="${3:?usage: render-deployment-docs.sh <out> <workspace> <baseline-dir>}"

cd "$out"
vals=".rebrand/values.json"
[ -f "$vals" ] || { echo "render-docs: $vals missing — is this a bootstrapped server?" >&2; exit 1; }
val() { python3 -c "import json,sys;print(json.load(open('$vals')).get(sys.argv[1],'') or '')" "$1"; }

repo="$(val reponame)"
brand="$(val brandSlug)"; [ -n "$brand" ] || brand="$repo"
sub="$(val subdomain)"; [ -n "$sub" ] || sub="your-workers-subdomain"
[ -n "$ws" ] || ws="$(sed -n 's/^[[:space:]]*workspace:[[:space:]]*\([^[:space:]#]*\).*/\1/p' intent.yaml | head -1)"
[ -n "$ws" ] || ws="?"

# CI lane pin (what version the deploy lanes run).
lanepin="$(sed -n 's/^ *version: *\(v[0-9.]*\) *$/\1/p' .github/workflows/ci.yml 2>/dev/null | head -1)"
[ -n "$lanepin" ] || lanepin="?"

# curl emits the -w format even on connection failure (000) — capture, don't
# append, or a failed probe reads "000000".
probe() { local c; c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$1" 2>/dev/null)" || true; printf '%s' "${c:-000}"; }
badge() { case "$1" in 2*|3*) echo "LIVE ($1)" ;; 000) echo "unreachable" ;; *) echo "answering $1" ;; esac; }
# What /health says the Worker is: the environment its deploy configured.
health_env() {
  { curl -s --max-time 20 "$1/health" 2>/dev/null || true; } | python3 -c "
import json,sys
try: print(json.load(sys.stdin).get('environment') or '?')
except Exception: print('?')"
}

# What /health says the bot is connected to: Slack or not, the model, and the
# tools — by name; /health never prints a value.
bot_state() {
  { curl -s --max-time 20 "$1/health" 2>/dev/null || true; } | python3 -c '
import json, sys
try:
    h = json.load(sys.stdin)
    m = h.get("model") or {}
    print("Slack %s; model %s %s; tools %s" % (h.get("slack", "?"), m.get("provider", "?"), m.get("id", "?"), ", ".join(h.get("tools") or [])))
except Exception:
    print("no /health answer")'
}

# Slack's door: an unsigned POST must be refused (400 connected, 503 before).
events_door() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -X POST "$1/api/events" -H 'content-type: application/json' -d '{"type":"url_verification","challenge":"probe"}' 2>/dev/null || true)"
  case "$code" in
    400) echo "refuses an unsigned event (400): connected" ;;
    503) echo "answers 503: Slack not connected yet" ;;
    *) echo "answered ${code:-nothing}" ;;
  esac
}

stage_url="https://${brand}-api-stage.${sub}.workers.dev"
prod_url="https://${brand}-api-prod.${sub}.workers.dev"

rows=""
for pair in "stage|$stage_url" "prod|$prod_url"; do
  env="${pair%%|*}"; url="${pair#*|}"
  rows+="| health (${env}) | ${url}/health | $(badge "$(probe "$url/health")"), reports \`$(health_env "$url")\` |"$'\n'
  rows+="| state (${env}) | ${url}/health | $(bot_state "$url") |"$'\n'
  rows+="| Slack events (${env}) | ${url}/api/events | $(events_door "$url") |"$'\n'
  rows+="| root (${env}) | ${url}/ | $(badge "$(probe "$url/")") |"$'\n'
done

now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Heal the static operating contract when the server predates it.
mkdir -p ai/context
if [ ! -f ai/context/operations.md ] && [ -f "$L/ai/context/operations.md" ]; then
  cp "$L/ai/context/operations.md" ai/context/operations.md
  git add ai/context/operations.md 2>/dev/null || true
  node "$L/tooling/rebrand/rebrand.mjs" --values "$vals" --allow-dirty >/dev/null 2>&1 || true
  echo "render-docs: healed ai/context/operations.md"
fi

cat > ai/context/deployment.md <<EOF
# ${repo} — live deployment manifest

> GENERATED by the \`02-docs\` phase on ${now}; re-run it to refresh
> (idempotent; see [operations.md](operations.md)). Hand-edits here are
> overwritten. No secret values appear in this file — secrets are named only.

## Identity

| | |
|---|---|
| repository / project slug | \`${repo}\` |
| Orun workspace | \`${ws}\` |
| declared in | \`intent.yaml\` → \`execution.state.workspace\` |
| Workers | \`${brand}-api-stage\`, \`${brand}-api-prod\` on \`${sub}.workers.dev\` |
| CI lane CLI pin | orun \`${lanepin}\` (\`.github/workflows/ci.yml\`) |

## Public URLs (probed ${now})

| surface | URL | status |
|---|---|---|
${rows}
The \`dev\` environment is verify-only by design — no deployed URL.

## Secrets (names only)

| secret | where | what it is |
|---|---|---|
| \`CLOUDFLARE_API_TOKEN\` | the workspace | BROKERED from its Cloudflare connection (\`workers-deploy\`): deploys the Worker |
| \`CLOUDFLARE_ACCOUNT_ID\` | the workspace | the connection's account id — a fact, not a credential |

| \`SLACK_SIGNING_SECRET\`, \`SLACK_BOT_TOKEN\` | each environment (optional) | the Slack app's — stored by the owner, pushed to the Worker as secrets on deploy |
| \`OPENAI_API_KEY\`, \`OPENAI_MODEL\`, \`EXA_API_KEY\` | each environment (optional) | OpenAI instead of Workers AI; Exa for the searchWeb tool |

Brokered secrets are minted per run, so no long-lived value is at rest. The
bot's own keys are the owner's, stored per environment and handed to the
Worker as Worker secrets by each deploy; the bot reads no wiring. What the workspace holds right now (every secret
by name, and its integrations and their health) is on the console's Secrets
and Integrations pages for \`${ws}\`.

## How this deployment changes

Merges to \`main\` converge automatically: CI plans the changed components and
runs each lane with \`orun run --remote-state\` against the workspace above.
See [operations.md](operations.md) for the full operating contract.
EOF
echo "render-docs: wrote ai/context/deployment.md"

python3 - "$prod_url" <<'PY'
import re, sys
prod = sys.argv[1]
begin, end = "<!-- 02-docs:begin -->", "<!-- 02-docs:end -->"
body = f"""{begin}
This Slack bot is **live**: its Slack app's Event Subscriptions Request URL is
`{prod}/api/events`. Verified URLs, identity and the secrets it uses are
recorded in [ai/context/deployment.md](ai/context/deployment.md) (re-rendered
by the `02-docs` phase); how it deploys and how to operate it:
[ai/context/operations.md](ai/context/operations.md).
{end}"""
s = open("README.md").read()
if begin in s and end in s:
    s = re.sub(re.escape(begin) + r".*?" + re.escape(end), lambda _m: body, s, count=1, flags=re.S)
else:
    lines = s.splitlines(keepends=True)
    at = 1
    while at < len(lines) and lines[at].strip() == "":
        at += 1
    lines.insert(at, f"\n## Live deployment\n\n{body}\n")
    s = "".join(lines)
open("README.md", "w").write(s)
print("render-docs: README live-deployment section rendered")
PY
echo "render-docs: done"
