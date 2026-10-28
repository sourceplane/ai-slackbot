#!/usr/bin/env bash
# THE REBRAND WRITES EACH VALUE ONCE, AND WHAT IT WROTE STAYS WRITTEN.
#
# Drives the real tooling/rebrand/rebrand.mjs over one-file trees and compares
# the file. Each case is a shape this baseline's identity actually takes in the
# tree — a source link, the API-name seam, the Worker name in wrangler.jsonc,
# the smoke's URL and the intent's environment URLs, the placeholder domain, a
# secret ref — and each can run through several passes (a re-run of a phase
# re-runs the rebrand over everything already placed, and 02-docs's heal runs
# it again), so a value written by one pass must survive every later one.
#
# The identity is PINNED (fixtures/baseline-identity.ai-slackbot.json) rather than
# read from .baseline/identity.json: what this tests is the engine, and its
# fixtures spell the identity out literally.
#
# Needs: node, git. No network.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
rebrand="$here/../tooling/rebrand/rebrand.mjs"
identity="$here/fixtures/baseline-identity.ai-slackbot.json"

fail=0
# check NAME VALUES-JSON FILE CONTENT WANT [PASSES]
check() {
  local name="$1" values="$2" file="$3" content="$4" want="$5" passes="${6:-1}"
  local tmp got out i
  tmp="$(mktemp -d)"
  git -C "$tmp" init -q
  mkdir -p "$tmp/$(dirname "$file")" "$tmp/.rebrand"
  printf '%s\n' "$content" > "$tmp/$file"
  printf '%s\n' "$values" > "$tmp/.rebrand/values.json"
  for ((i = 1; i <= passes; i++)); do
    git -C "$tmp" add -A
    if ! out="$(cd "$tmp" && node "$rebrand" --baseline-identity "$identity" --values .rebrand/values.json --allow-dirty 2>&1)"; then
      echo "   ✕  $name: rebrand pass $i failed:" >&2
      printf '%s\n' "$out" | sed 's/^/        /' >&2
      fail=1
      rm -rf "$tmp"
      return
    fi
  done
  got="$(cat "$tmp/$file")"
  rm -rf "$tmp"
  if [ "$got" = "$want" ]; then
    echo "   ok  $name"
  else
    echo "   ✕  $name:" >&2
    echo "        got:  $got" >&2
    echo "        want: $want" >&2
    fail=1
  fi
}

acme='{"reponame":"acme-api","productname":"Acme API","productdomain":"acme.dev","githuborg":"acme-inc","subdomain":"acme","orunWorkspace":"ws_79BDXAZQ"}'

echo "── rebrand: the API's own identity"
check "a source link names the product's owner and repository" \
  "$acme" README.md \
  'See https://github.com/sourceplane/ai-slackbot for the source.' \
  'See https://github.com/acme-inc/acme-api for the source.'
check "the API-name seam takes the product's name" \
  "$acme" apps/api/src/identity.ts 'export const API_NAME = "AI SDK Slackbot"' \
  'export const API_NAME = "Acme API"'
check "…and stays a valid string for a name with an apostrophe and an ampersand" \
  '{"reponame":"sams-tools","productname":"Sam'"'"'s Tools & Things","productdomain":"sam.dev"}' \
  apps/api/src/identity.ts 'export const API_NAME = "AI SDK Slackbot"' \
  'export const API_NAME = "Sam'"'"'s Tools & Things"'
check "the display name elsewhere is content, and is left alone" \
  "$acme" apps/api/src/notes.ts '// Welcome to AI SDK Slackbot.' \
  '// Welcome to AI SDK Slackbot.'
check "the framework is not the baseline: hono, Hono and hono/jsx are left alone" \
  "$acme" apps/api/src/index.ts "import { Hono } from 'hono' // hono/jsx" \
  "import { Hono } from 'hono' // hono/jsx"
check "the Worker name in wrangler.jsonc is re-prefixed" \
  "$acme" apps/api/wrangler.jsonc '  "name": "ai-slackbot-api",' \
  '  "name": "acme-api-api",'
check "the smoke's URL: Worker name and subdomain, the environment kept" \
  "$acme" apps/api/component.yaml \
  'smokeCommand: base="${DEPLOYED_URL:-https://ai-slackbot-api-${ORUN_ENVIRONMENT}.your-workers-subdomain.workers.dev}"' \
  'smokeCommand: base="${DEPLOYED_URL:-https://acme-api-api-${ORUN_ENVIRONMENT}.acme.workers.dev}"'
check "an environment URL in the intent" \
  "$acme" intent.yaml '    url: https://ai-slackbot-api-prod.your-workers-subdomain.workers.dev' \
  '    url: https://acme-api-api-prod.acme.workers.dev'
check "the placeholder domain is the product's domain, not a renamed slug" \
  "$acme" intent.yaml '      BASE_DOMAIN: ai-slackbot.example.com' \
  '      BASE_DOMAIN: acme.dev'
check "no domain given: the reserved placeholder, for an owner to replace later" \
  '{"reponame":"acme-api","productname":"Acme API","githuborg":"acme-inc","subdomain":"acme"}' \
  intent.yaml '      BASE_DOMAIN: ai-slackbot.example.com' \
  '      BASE_DOMAIN: acme-api.example.com'
check "an empty domain is no domain" \
  '{"reponame":"acme-api","productname":"Acme API","productdomain":""}' \
  intent.yaml '      BASE_DOMAIN: ai-slackbot.example.com' \
  '      BASE_DOMAIN: acme-api.example.com'
check "the repo slug" \
  "$acme" package.json '  "name": "ai-slackbot",' \
  '  "name": "acme-api",'
check "a secret ref names the product's workspace and project" \
  "$acme" apps/api/component.yaml 'T: secret://ws_KWQ45Z6M/ai-slackbot/stage/CLOUDFLARE_API_TOKEN' \
  'T: secret://ws_79BDXAZQ/acme-api/stage/CLOUDFLARE_API_TOKEN'
check "org-owned identity is not renamed" \
  "$acme" intent.yaml 'apiVersion: sourceplane.io/v1 # mail ops@sourceplane.ai' \
  'apiVersion: sourceplane.io/v1 # mail ops@sourceplane.ai'
check "without githuborg a source link keeps the baseline's owner" \
  '{"reponame":"acme-api","productname":"Acme API","productdomain":"acme.dev"}' \
  README.md 'https://github.com/sourceplane/ai-slackbot' \
  'https://github.com/sourceplane/acme-api'

echo "── rebrand: a written value is not rewritten, in any later pass"
contains='{"reponame":"ai-slackbot-2","productname":"AI SDK Slackbot 2","productdomain":"ai-slackbot.example.com.au","githuborg":"sourceplane","subdomain":"your-workers-subdomain-2"}'
check "a repo slug containing the baseline's slug survives three passes" \
  "$contains" package.json '  "name": "ai-slackbot",' \
  '  "name": "ai-slackbot-2",' 3
check "a Worker name built on it survives three passes" \
  "$contains" apps/api/wrangler.jsonc '  "name": "ai-slackbot-api",' \
  '  "name": "ai-slackbot-2-api",' 3
check "a domain containing the baseline's domain survives three passes" \
  "$contains" intent.yaml 'BASE_DOMAIN: ai-slackbot.example.com' \
  'BASE_DOMAIN: ai-slackbot.example.com.au' 3
check "a subdomain containing the placeholder survives three passes" \
  "$contains" apps/api/component.yaml 'x: https://ai-slackbot-api-stage.your-workers-subdomain.workers.dev' \
  'x: https://ai-slackbot-2-api-stage.your-workers-subdomain-2.workers.dev' 3
check "an API name containing the baseline's name survives three passes" \
  "$contains" apps/api/src/identity.ts 'export const API_NAME = "AI SDK Slackbot"' \
  'export const API_NAME = "AI SDK Slackbot 2"' 3
# The fixture the placement and end-to-end gates build with: a slug that ENDS
# in the baseline's, so its Worker is `<…>-ai-slackbot-api`.
suffixed='{"reponame":"acme-ai-slackbot","productname":"Acme","productdomain":"api.acme.dev","githuborg":"acme-inc","subdomain":"acme"}'
check "a repo slug ending in the baseline's slug survives three passes" \
  "$suffixed" package.json '  "name": "ai-slackbot",' \
  '  "name": "acme-ai-slackbot",' 3
check "…and its Worker name in the smoke URL" \
  "$suffixed" apps/api/component.yaml 'x: https://ai-slackbot-api-${ORUN_ENVIRONMENT}.your-workers-subdomain.workers.dev' \
  'x: https://acme-ai-slackbot-api-${ORUN_ENVIRONMENT}.acme.workers.dev' 3
check "…and, with no domain, its placeholder (which ends in the baseline's domain)" \
  '{"reponame":"acme-ai-slackbot","productname":"Acme","githuborg":"acme-inc","subdomain":"acme"}' \
  intent.yaml '      BASE_DOMAIN: ai-slackbot.example.com' \
  '      BASE_DOMAIN: acme-ai-slackbot.example.com' 3

# --verify runs in every phase. Without the product's values it cannot tell
# the product's own identity from a leftover; with them it can. A real
# leftover must fail it either way.
verify() { # NAME VALUES FILE CONTENT WANT(pass|fail) [--values]
  local name="$1" values="$2" file="$3" content="$4" want="$5" withvalues="${6:-}" tmp got
  tmp="$(mktemp -d)"
  git -C "$tmp" init -q
  mkdir -p "$tmp/$(dirname "$file")" "$tmp/.rebrand"
  printf '%s\n' "$content" > "$tmp/$file"
  printf '%s\n' "$values" > "$tmp/.rebrand/values.json"
  git -C "$tmp" add -A
  if (cd "$tmp" && node "$rebrand" --baseline-identity "$identity" --verify ${withvalues:+--values .rebrand/values.json} >/dev/null 2>&1); then got=pass; else got=fail; fi
  rm -rf "$tmp"
  if [ "$got" = "$want" ]; then echo "   ok  $name"; else echo "   ✕  $name: --verify ${got}ed, want $want" >&2; fail=1; fi
}
echo "── rebrand --verify: the product's own identity is not residue"
verify "given the values, a slug containing the baseline's passes" \
  "$contains" package.json '"name": "ai-slackbot-2"' pass --values
verify "without them it cannot know, and fails" \
  "$contains" package.json '"name": "ai-slackbot-2"' fail
verify "given the values, a slug ending in the baseline's passes" \
  "$suffixed" apps/api/wrangler.jsonc '"name": "acme-ai-slackbot-api"' pass --values
verify "given the values, a real leftover still fails" \
  "$acme" package.json '"name": "ai-slackbot"' fail --values
verify "a leftover Worker name fails" \
  "$acme" apps/api/wrangler.jsonc '"name": "ai-slackbot-api"' fail --values
verify "a leftover code identifier fails (no rule renames it — so nothing may spell it)" \
  "$acme" apps/api/src/x.ts 'export class AiSlackbot {}' fail --values
verify "a clean product passes" \
  "$acme" package.json '"name": "acme-api"' pass --values

echo "── rebrand: a residue it cannot rename fails the rebrand itself"
tmp="$(mktemp -d)"; git -C "$tmp" init -q; mkdir -p "$tmp/.rebrand" "$tmp/apps/api"
printf '%s\n' "$acme" > "$tmp/.rebrand/values.json"
printf 'const x = "AI_SLACKBOT_TOKEN"\n' > "$tmp/apps/api/x.ts"
git -C "$tmp" add -A
if (cd "$tmp" && node "$rebrand" --baseline-identity "$identity" --values .rebrand/values.json --allow-dirty >/dev/null 2>&1); then
  echo "   ✕  an unrenamable env-var prefix passed the rebrand" >&2; fail=1
else
  echo "   ok  an unrenamable env-var prefix fails the rebrand, naming the file"
fi
rm -rf "$tmp"

[ "$fail" -eq 0 ] || exit 1
echo "rebrand.test.sh: ok"
