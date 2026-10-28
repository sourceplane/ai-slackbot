#!/usr/bin/env bash
# TIER 2 — the API a bootstrap produces builds, deploys (dry) and serves.
#
# placement.test.sh proves the tree a bootstrap ends with is the right tree.
# This proves it WORKS, by doing to it what its own pipelines will:
#
#   1. at the 01-product landing (the commit its one pull request merges),
#      the landing's own checks — install with the lockfile the API ships,
#      render fixtures, typecheck, lint, test, build; then the same at the
#      02-docs landing. Both landings are checked in the box with
#      `orun validate` and `orun plan` alone (`checks: local`; their PR's CI
#      on an `orun/BASE-…` branch is `plan` alone, and the convergence on
#      main builds, deploys and smoke-tests the API), and a later pull
#      request of the API runs ci.yml's verify lanes, which build, type-check
#      and dry-deploy the Worker — so THIS is where the lint and the tests run
#      over a bootstrapped API: before the tag, not after a build has merged
#      it;
#   2. the stage lane's own steps, read out of `orun plan` in the product for a
#      pull request — EVERY `run:` step of the job, in order, exactly as
#      planned: the install, `verify-worker-structure` (the committed
#      `package.json` and `wrangler.jsonc`, checked BEFORE any build),
#      `wire-fixture`, the build, the typecheck and `deploy-dry-run`
#      (`wrangler deploy --dry-run --env stage`). The deploy profile has no
#      dry run, so the PR plan is the one with a deploy to rehearse. They run
#      IN THE TREE THE RUNNER STAGES for the job (testing/lib/stage-job.py),
#      with no build output in it and the dependency layout the pinned
#      composition produces: if its install step is `scope: lane`, the
#      top-level node_modules is a symlink to the source checkout's; if not,
#      the job's own install step runs inside the staged tree;
#   3. serve the staged Worker with `wrangler dev` (env.stage's own config,
#      its Workers AI binding pointed at a stand-in, testing/lib/
#      fake-workers-ai.js, since Workers AI has no local mode) and run the
#      component's OWN `smokeCommand` against it, verbatim and inside the
#      deploy profile's planned `smoke` step, and check it refuses the wrong
#      environment; check the deploy plan pushes the bot's five keys as Worker
#      secrets between the deploy and the smoke. First AS BORN — no keys:
#      `/` and `/health` name the bot and THIS environment and say Slack is
#      not connected, Workers AI the model, no searchWeb; `/api/events` a 503
#      that does no work. Then CONNECTED — Slack's two keys stored, its Web
#      API pointed at a stand-in (testing/lib/fake-slack-api.py): unsigned,
#      forged, stale and wrongly-keyed requests refused with a 400 and no
#      call made; the URL verification answered once signed; a retry
#      acknowledged and not answered; an app mention acknowledged at once and
#      answered after (waitUntil) in its thread, through the real AI SDK, the
#      real OPA policy and just-bash's in-memory bash (`ls`); a command the
#      policy refuses relayed verbatim; a DM answered from its thread's
#      history with the status set and cleared; a new assistant thread
#      greeted with the template's prompts (testing/lib/slack-e2e.py).
#
# What it cannot do is the platform's half: create the repository, mint the
# brokered Cloudflare token, deploy for real and probe workers.dev. That is a
# bootstrap against a workspace (BOOTSTRAP.md); everything short of it is here.
#
# Needs: orun, node, pnpm, python3 (+PyYAML), git, curl, setsid, and the
# network for `pnpm install` (or a warm store). A few minutes: three installs.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
# shellcheck source=lib/bootstrap.sh
source "$here/lib/bootstrap.sh"

for bin in orun node pnpm python3 git curl setsid; do
  command -v "$bin" >/dev/null || { echo "e2e.test.sh needs $bin on PATH" >&2; exit 1; }
done

scratch="$(mktemp -d)"
dev_pid=""
# wrangler dev runs under pnpm, node and workerd processes; a TERM to the
# first does not reach the rest, and waiting on it then never returns. So it is
# started as its own process group (setsid) and the whole group is stopped.
cleanup() {
  if [ -n "$dev_pid" ]; then
    kill -TERM -- "-$dev_pid" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 -- "-$dev_pid" 2>/dev/null || break; sleep 0.5; done
    kill -KILL -- "-$dev_pid" 2>/dev/null || true
  fi
  rm -rf "$scratch"
}
trap cleanup EXIT
values="$here/fixtures/acme.json"
repo="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['reponame'])" "$values")"
sub="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['subdomain'])" "$values")"
export CI=1 WRANGLER_SEND_METRICS=false TURBO_TELEMETRY_DISABLED=1
free_port() { python3 -c "import socket;s=socket.socket();s.bind(('127.0.0.1',0));print(s.getsockname()[1]);s.close()"; }

# The landing's own checks, step for step, run here at once on the whole
# tree. A pull request in the API builds, type-checks and dry-deploys the
# Worker through ci.yml's lanes; the lint and the tests run here, and by hand
# before a push.
LANDING_CHECKS=(
  "pnpm install --frozen-lockfile"
  "pnpm run wire:fixture"
  "pnpm typecheck"
  "pnpm lint"
  "pnpm test"
  "pnpm build"
)
checks() { # DIR LOG
  local dir="$1" log="$2" cmd
  for cmd in "${LANDING_CHECKS[@]}"; do
    echo "   \$ $cmd" | tee -a "$log"
    if ! (cd "$dir" && bash -c "$cmd") >> "$log" 2>&1; then
      echo "FAIL: \`$cmd\` failed in $dir" >&2; tail -40 "$log" >&2; return 1
    fi
  done
}

echo "── the offline bootstrap (testing/lib/bootstrap.sh)"
tree="$scratch/$repo"
bootstrap_offline "$root" "$tree" "$values" "$scratch/logs" > "$scratch/bootstrap.log" 2>&1 || {
  echo "FAIL: the offline bootstrap stopped" >&2; tail -40 "$scratch/bootstrap.log" >&2; exit 1; }
s00="$(git -C "$tree" rev-parse HEAD~2)"; s01="$(git -C "$tree" rev-parse HEAD~1)"
echo "   2 phases placed and landed on orun's Initial commit"

# ── 1. each landing's own checks ───────────────────────────────────────────
echo "── 01-product's landing: install, the fixture render, typecheck, lint, test, build"
git -C "$tree" worktree add -q "$scratch/at-01" "$s01"
checks "$scratch/at-01" "$scratch/checks-01.log"
git -C "$tree" worktree remove --force "$scratch/at-01"

echo "── 02-docs's landing (the finished API), under the same checks"
checks "$tree" "$scratch/checks-api.log"

# ── 2. the stage lane, as a pull request plans it ──────────────────────────
echo "── the stage lane: every run step the PR plan gives api@stage, in a staged job tree"
(cd "$tree" && orun plan --intent intent.yaml --trigger github-pull-request --changed \
   --base "$s00" --head "$s01" --env stage --output "$scratch/plan-pr.json") > "$scratch/plan-pr.log" 2>&1 \
  || { echo "FAIL: orun plan (pull request)" >&2; tail -15 "$scratch/plan-pr.log" >&2; exit 1; }
python3 - "$scratch/plan-pr.json" "$scratch/steps" "$tree" <<'PY'
import json, pathlib, sys
import yaml
plan = json.load(open(sys.argv[1]))
out = pathlib.Path(sys.argv[2]); out.mkdir()
tree = pathlib.Path(sys.argv[3])
job = next(j for j in plan["jobs"] if j["component"] == "api" and j["environment"] == "stage")
params = yaml.safe_load((tree / "apps/api/component.yaml").read_text())["spec"]["parameters"]
order, uses = [], []
for s in job["steps"]:
    if "use" in s:
        uses.append(f"{s['id']}\t{s['use']}\t{json.dumps(s.get('with') or {})}")
        continue
    order.append(s["id"])
    (out / f"{s['id']}.sh").write_text(s.get("run") or "")
    (out / f"{s['id']}.wd").write_text(s.get("working-directory") or ".")
    if s.get("scope"):
        (out / f"{s['id']}.scope").write_text(s["scope"])
(out / "order").write_text("\n".join(order) + "\n")
(out / "uses").write_text("\n".join(uses) + "\n")
(out / "path").write_text(job.get("path") or "apps/api")
(out / "profile").write_text(job["profile"])
(out / "node").write_text(params["nodeVersion"])
(out / "pnpm").write_text(params["pnpmVersion"])
for k, v in (job.get("env") or {}).items():
    (out / "env").open("a").write(f"export {k}={json.dumps(v)}\n")
PY
order="$(tr '\n' ' ' < "$scratch/steps/order")"
echo "   $(cat "$scratch/steps/profile"): $order"
for need in install-workspace-dependencies verify-worker-structure build-worker deploy-dry-run; do
  grep -qx "$need" "$scratch/steps/order" || { echo "FAIL: the stage lane plans no $need step" >&2; exit 1; }
done
[ "$(grep -n -x verify-worker-structure "$scratch/steps/order" | cut -d: -f1)" -lt "$(grep -n -x build-worker "$scratch/steps/order" | cut -d: -f1)" ] \
  || { echo "FAIL: the structure check is planned after the build" >&2; exit 1; }
# The `use:` steps set up the runner's toolchain; here it is this machine's,
# so it must be the one the component asks for.
node_major="$(node -p 'process.versions.node.split(".")[0]')"
[ "$node_major" = "$(cat "$scratch/steps/node")" ] || { echo "FAIL: node $node_major here, the lane sets up $(cat "$scratch/steps/node")" >&2; exit 1; }
[ "$(pnpm --version)" = "$(cat "$scratch/steps/pnpm")" ] || { echo "FAIL: pnpm $(pnpm --version) here, the lane sets up $(cat "$scratch/steps/pnpm")" >&2; exit 1; }
echo "   setup-node $node_major and setup-pnpm $(pnpm --version) stand in for the lane's \`use:\` steps"

# The job's private tree, staged as orun stages it, from a source checkout
# with no build output (a CI checkout has none, so step 1's is removed rather
# than copied in) and the dependencies the pinned composition says: a
# lane-scoped install ran once in the source tree (step 1 ran the same
# command) and is linked in, or the job installs its own.
rm -rf "$tree/apps/api/.wrangler" "$tree/apps/api/dist" "$tree/tests/api/coverage"
work="$tree/.orun/runs/e2e/api.stage.verify-deploy/work"
install_scope="$(cat "$scratch/steps/install-workspace-dependencies.scope" 2>/dev/null || echo job)"
if [ "$install_scope" = lane ]; then
  python3 "$here/lib/stage-job.py" "$tree" "$work" --shared-deps
  [ -L "$work/node_modules" ] || { echo "FAIL: the staged tree's node_modules is not the lane's symlink" >&2; exit 1; }
else
  python3 "$here/lib/stage-job.py" "$tree" "$work"
  [ ! -e "$work/node_modules" ] || { echo "FAIL: the staged tree carries node_modules it should install" >&2; exit 1; }
fi
for built in apps/api/dist apps/api/.wrangler; do
  [ ! -e "$work/$built" ] || { echo "FAIL: the staged tree carries build output ($built)" >&2; exit 1; }
done
echo "   staged: $(realpath --relative-to="$tree" "$work"); install scope: $install_scope; no build output"

while IFS= read -r step; do
  [ -n "$step" ] || continue
  if [ "$step" = install-workspace-dependencies ] && [ "$install_scope" = lane ]; then
    echo "   · $step (lane-scoped: ran once in the source tree)"; continue
  fi
  echo "   ▸ $step"
  # The runner's per-job environment: the job's env (intent environment
  # `env:`) and ORUN_ENVIRONMENT; the step runs in the component's directory.
  if ! (cd "$work/$(cat "$scratch/steps/path")/$(cat "$scratch/steps/$step.wd")" && \
        { [ -f "$scratch/steps/env" ] && source "$scratch/steps/env"; true; } && \
        export ORUN_ENVIRONMENT=stage && bash -e "$scratch/steps/$step.sh") > "$scratch/$step.log" 2>&1; then
    echo "FAIL: the stage lane's $step step" >&2; tail -40 "$scratch/$step.log" >&2; exit 1
  fi
done < "$scratch/steps/order"
[ "$install_scope" = lane ] || { [ -d "$work/node_modules" ] && [ ! -L "$work/node_modules" ]; } \
  || { echo "FAIL: the job's install did not land inside its own tree" >&2; exit 1; }
grep -Eq 'env\.ENVIRONMENT \("stage"\)' "$scratch/deploy-dry-run.log" \
  || { echo "FAIL: the dry run did not resolve env.stage (ENVIRONMENT=stage)" >&2; tail -20 "$scratch/deploy-dry-run.log" >&2; exit 1; }
grep -Eq 'env\.AI +AI' "$scratch/deploy-dry-run.log" \
  || { echo "FAIL: the dry run did not bind Workers AI as env.AI" >&2; tail -20 "$scratch/deploy-dry-run.log" >&2; exit 1; }
echo "   the dry run bundled the Worker with env.stage's ENVIRONMENT=\"stage\" and its Workers AI binding"

# ── 3. serve it, and smoke it as the deploy does ───────────────────────────
# Workers AI has no local mode: the AI binding always calls the account, and
# the e2e has none. So the staged Worker's own config (env.stage of the
# wrangler.jsonc the lane just dry-deployed) is served with `ai` swapped for a
# service binding to testing/lib/fake-workers-ai.js — a second Worker in the
# same `wrangler dev`, reached over RPC exactly as the real binding is — and
# everything else unchanged. Twice: as the bot is born (no keys), and
# connected (Slack's two keys, its Web API pointed at a stand-in).
fake="$scratch/fake-workers-ai"
mkdir -p "$fake"
cp "$here/lib/fake-workers-ai.js" "$fake/index.js"
printf '{ "name": "fake-workers-ai", "main": "index.js", "compatibility_date": "2026-10-01" }\n' > "$fake/wrangler.jsonc"
devconfig() { # SLACK_API_URL|"" — writes apps/api/wrangler.e2e.json in the staged tree
  python3 - "$work/apps/api/wrangler.jsonc" "$work/apps/api/wrangler.e2e.json" "${1:-}" <<'PY'
import json, re, sys
src = re.sub(r"(?m)^\s*//.*$", "", open(sys.argv[1]).read())
cfg = json.loads(src)
stage = cfg.pop("env")["stage"]
if stage.get("ai") != {"binding": "AI"} or cfg.get("ai") != {"binding": "AI"}:
    sys.exit("the staged wrangler.jsonc does not bind Workers AI as AI (top level and env.stage)")
cfg.pop("ai"); stage.pop("ai")
cfg.pop("$schema", None)
cfg.update(stage)                       # env.stage's vars: ENVIRONMENT=stage
cfg["name"] = cfg["name"] + "-stage"
cfg["services"] = [{"binding": "AI", "service": "fake-workers-ai", "entrypoint": "FakeAI"}]
if sys.argv[3]:
    cfg["vars"]["SLACK_API_URL"] = sys.argv[3]
json.dump(cfg, open(sys.argv[2], "w"), indent=1)
PY
}
serve() { # LOG — wrangler dev over wrangler.e2e.json and the stand-in
  port="$(free_port)"; iport="$(free_port)"
  (cd "$work/apps/api" && exec setsid pnpm exec wrangler dev --config wrangler.e2e.json --config "$fake/wrangler.jsonc" \
     --ip 127.0.0.1 --port "$port" --inspector-port "$iport" --show-interactive-dev-session=false) \
     > "$1" 2>&1 < /dev/null &
  dev_pid=$!
  url="http://127.0.0.1:$port"
  for _ in $(seq 1 90); do
    curl -s -o /dev/null "$url/health" && return 0
    kill -0 "$dev_pid" 2>/dev/null || { echo "FAIL: wrangler dev exited" >&2; tail -30 "$1" >&2; exit 1; }
    sleep 1
  done
  echo "FAIL: wrangler dev never answered" >&2; tail -30 "$1" >&2; exit 1
}
stop() {
  kill -TERM -- "-$dev_pid" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 -- "-$dev_pid" 2>/dev/null || break; sleep 0.5; done
  kill -KILL -- "-$dev_pid" 2>/dev/null || true
  dev_pid=""
}

smoke="$(python3 -c "import yaml,sys;print(yaml.safe_load(open(sys.argv[1]))['spec']['parameters']['smokeCommand'])" "$tree/apps/api/component.yaml")"
smoke_both() { # what — the component's own smokeCommand, and that it refuses prod
  DEPLOYED_URL="$url" ORUN_ENVIRONMENT=stage bash -c "$smoke" || { echo "FAIL: the deploy's smoke refused the bot ($1)" >&2; exit 1; }
  if DEPLOYED_URL="$url" ORUN_ENVIRONMENT=prod bash -c "$smoke" 2>/dev/null; then
    echo "FAIL: the smoke passed prod's check against the stage Worker — it does not read the environment" >&2; exit 1
  fi
}

(cd "$tree" && orun plan --intent intent.yaml --trigger github-push-main --changed \
   --base "$s00" --head "$s01" --env stage --output "$scratch/plan-push.json") > "$scratch/plan-push.log" 2>&1 \
  || { echo "FAIL: orun plan (push to main)" >&2; tail -15 "$scratch/plan-push.log" >&2; exit 1; }
python3 - "$scratch/plan-push.json" "$scratch/smoke-step.sh" "$tree/apps/api/component.yaml" <<'PY'
import json, sys
import yaml
plan = json.load(open(sys.argv[1]))
job = next(j for j in plan["jobs"] if j["component"] == "api" and j["environment"] == "stage")
assert job["profile"].endswith(".deploy"), job["profile"]
ids = [s["id"] for s in job["steps"]]
step = next(s for s in job["steps"] if s["id"] == "smoke")
open(sys.argv[2], "w").write(step["run"])
# The deploy hands the bot's keys to the Worker as SECRETS, after the deploy
# and before the smoke — exactly the keys the component declares, by name.
spec = yaml.safe_load(open(sys.argv[3]))["spec"]
want = ["SLACK_SIGNING_SECRET", "SLACK_BOT_TOKEN", "OPENAI_API_KEY", "OPENAI_MODEL", "EXA_API_KEY"]
names = [n.strip() for n in spec["parameters"]["runtimeSecrets"].split(",")]
if names != want:
    sys.exit(f"runtimeSecrets is {names}, want {want}")
if sorted(spec["optionalSecretEnv"]) != sorted(want):
    sys.exit(f"optionalSecretEnv declares {sorted(spec['optionalSecretEnv'])}, want {sorted(want)}")
if not (ids.index("deploy") < ids.index("secrets-live") < ids.index("smoke")):
    sys.exit(f"secrets-live is not between the deploy and the smoke: {ids}")
push = next(s for s in job["steps"] if s["id"] == "secrets-live")["run"]
if ",".join(want) not in push or "wrangler secret bulk" not in push:
    sys.exit("the planned secrets-live step does not push the bot's keys with `wrangler secret bulk`")
PY
echo "   the deploy plan pushes the bot's five keys as Worker secrets between the deploy and the smoke"

echo "── wrangler dev over the staged Worker (env.stage), as it is born: no Slack, Workers AI stood in for"
devconfig ""
serve "$scratch/dev-born.log"
echo "   ▸ the component's own smokeCommand, verbatim, DEPLOYED_URL=$url ORUN_ENVIRONMENT=stage — and it refuses the stage Worker as prod"
smoke_both "as born"
echo "   ▸ the deploy profile's planned smoke step (its retry loop around the same command)"
(DEPLOYED_URL="$url" ORUN_ENVIRONMENT=stage bash "$scratch/smoke-step.sh") > "$scratch/smoke-step.log" 2>&1 \
  || { echo "FAIL: the planned smoke step refused the bot" >&2; tail -20 "$scratch/smoke-step.log" >&2; exit 1; }
echo "   ▸ every route, before Slack is connected"
python3 "$here/lib/slack-e2e.py" born "$url" "$values" || { tail -30 "$scratch/dev-born.log" >&2; exit 1; }
stop

echo "── …and connected: Slack's signing secret and bot token stored, its Web API stood in for"
slack_port="$(free_port)"
secret="e2e-$(python3 -c 'import secrets;print(secrets.token_hex(16))')"
token="xoxb-e2e-$(python3 -c 'import secrets;print(secrets.token_hex(8))')"
python3 "$here/lib/fake-slack-api.py" "$slack_port" "$token" > "$scratch/slack.log" 2>&1 &
slack_pid=$!
trap 'kill "$slack_pid" 2>/dev/null || true; cleanup' EXIT
printf 'SLACK_SIGNING_SECRET=%s\nSLACK_BOT_TOKEN=%s\n' "$secret" "$token" > "$work/apps/api/.dev.vars"
devconfig "http://127.0.0.1:$slack_port/api/"
serve "$scratch/dev.log"
echo "   ▸ the smoke again (Slack's door now refuses an unsigned event with a 400)"
smoke_both "connected"
echo "   ▸ Slack's events: what is refused, the challenge, a retry, a mention, a refusal, a DM thread, a new thread"
SLACK_STANDIN="http://127.0.0.1:$slack_port" SIGNING_SECRET="$secret" BOT_TOKEN="$token" DEV_LOG="$scratch/dev.log" \
  python3 "$here/lib/slack-e2e.py" connected "$url" "$values" || { tail -40 "$scratch/dev.log" >&2; exit 1; }
rm -f "$work/apps/api/.dev.vars"

echo "e2e.test.sh: ok"
