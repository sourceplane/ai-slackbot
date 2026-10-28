#!/usr/bin/env bash
# TIER 1 — the tree is placed, branded, and made to answer.
#
# A real bootstrap is `orun new --run-hooks --resume` against a workspace: it
# places each phase, runs that phase's hooks, lands a pull request and watches
# the convergence. Everything in that sentence except the platform can run
# here, offline, and this file runs it:
#
#   1. the whole blueprint placed in one go — orun runs `validate` and
#      `plan --dry-run` inside the produced tree and says so; asserted, because
#      a future orun that stopped running them would weaken this tier in silence;
#   2. THE OFFLINE BOOTSTRAP (testing/lib/bootstrap.sh) — both phases placed in
#      order, finished by the blueprint's OWN `run:` hooks (retouch, rebrand,
#      re-tenant, work-tree strip, the deferrals and their restore, the
#      deployment record), each landing a commit on top of orun's
#      `Initial commit`;
#   3. the product it ends with: branded with no residue, carrying nothing of
#      the factory and naming none of its paths, re-tenanted, its gates
#      restored, its record rendered;
#   4. what the product's own CI does with the 01-product merge: `orun plan`
#      exactly as ci.yml runs it (`--from-ci github --event-file … --changed`)
#      for the push that merged it — infrastructure before anything reading
#      its wiring (this API has none, so nothing waits), the API deployed to
#      stage and prod side by side, nothing on dev, the Worker, the smoke and
#      the secret refs the product's own;
#   5. a `--resume` over the finished API places nothing and un-brands nothing.
#
# testing/e2e.test.sh goes on from here: it installs, builds and serves the
# product and runs its smoke against it.
#
# Needs: orun, node, pnpm, python3 (+PyYAML), git. No credential. The
# deployment-record probes reach the network if they can, and pass without it.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
# shellcheck source=lib/bootstrap.sh
source "$here/lib/bootstrap.sh"

for bin in orun node pnpm python3 git; do
  command -v "$bin" >/dev/null || { echo "placement.test.sh needs $bin on PATH" >&2; exit 1; }
done

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
fails=0
fail() { echo "  ✕ $*" >&2; fails=$((fails + 1)); }
values="$here/fixtures/acme.json"
repo="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['reponame'])" "$values")"
org="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['githuborg'])" "$values")"

sets=()
while IFS=$'\t' read -r k v; do sets+=( --set "$k=$v" ); done < <(
  python3 - "$values" <<'PY'
import json, sys
for k, v in json.load(open(sys.argv[1])).items():
    if not k.startswith("_"):
        print(f"{k}\t{'true' if v is True else 'false' if v is False else v}")
PY
)

# ── 1. the whole blueprint, one placement ──────────────────────────────────
echo "── placing the whole blueprint at once (offline, no credential)"
whole="$scratch/whole"
mkdir -p "$whole"/{apps,infra,packages,tests}
for d in apps infra packages tests; do touch "$whole/$d/.gitkeep"; done
if ! orun new --blueprint "$root/repo-blueprint.yaml" --out "$whole" "${sets[@]}" > "$scratch/whole.log" 2>&1; then
  echo "FAIL: the placement did not run" >&2; tail -20 "$scratch/whole.log" >&2; exit 1
fi
# The line's wording moved between orun releases (v2.58: `repo gate: validate +
# plan --dry-run passed`; v2.79: `Verified  intent valid · N components …`).
grep -Eq "repo gate: validate \+ plan --dry-run passed|Verified +intent valid" "$scratch/whole.log" \
  || fail "the placement did not report the repo-scale gate (orun validate + plan --dry-run inside the tree)"
n="$(find "$whole" -type f -not -path '*/.orun/*' | wc -l | tr -d ' ')"
[ "$n" -ge 30 ] || fail "only $n files placed — that is not an API"
[ "$fails" -eq 0 ] && echo "   $n files placed; the repo-scale gate ran"

# ── 2. the offline bootstrap ───────────────────────────────────────────────
echo "── the offline bootstrap: both phases, their own hooks, a landing each"
tree="$scratch/$repo"     # named as the repository is: orun names the project after it
bootstrap_offline "$root" "$tree" "$values" "$scratch/logs" > "$scratch/bootstrap.log" 2>&1 || {
  echo "FAIL: the offline bootstrap stopped" >&2; tail -40 "$scratch/bootstrap.log" >&2; exit 1; }
grep -E '^── ' "$scratch/bootstrap.log" | sed 's/^/  /'
commits="$(git -C "$tree" rev-list --count HEAD)"
[ "$commits" = 3 ] || fail "the bootstrap made $commits commits, not orun's initial one and one per phase (3)"
[ -z "$(git -C "$tree" ls-tree -r --name-only HEAD~2)" ] || fail "the first commit is not orun's empty Initial commit"

# ── 3. the product it ends with ────────────────────────────────────────────
echo "── the API it produced"
(cd "$tree" && node "$root/tooling/rebrand/rebrand.mjs" --verify --values .rebrand/values.json) > "$scratch/verify.log" 2>&1 \
  || { fail "rebrand --verify found the baseline's identity in the API:"; sed 's/^/      /' "$scratch/verify.log" >&2; }

python3 - "$tree" "$values" "$root" <<'PY' || fails=$((fails + 1))
import json, pathlib, re, subprocess, sys
import yaml
tree, values, root = pathlib.Path(sys.argv[1]), json.load(open(sys.argv[2])), pathlib.Path(sys.argv[3])
problems = []
def bad(m): problems.append(m)
repo, org, name, sub = values["reponame"], values["githuborg"], values["productname"], values["subdomain"]

tracked = subprocess.run(["git", "ls-files"], cwd=tree, capture_output=True, text=True, check=True).stdout.split()

# Nothing of the factory, nothing local, exactly the two context pages.
NEVER = (".baseline/", "specs/", "tasks/", "testing/", "hooks/", "docs/phases/",
         "tooling/rebrand/", "tooling/bootstrap/", ".github/workflows/baseline.yml",
         ".github/workflows/tag.yml", "BOOTSTRAP.md", "repo-blueprint.yaml", "blueprint.yaml")
for p in tracked:
    if any(p == n or p.startswith(n) for n in NEVER):
        bad(f"{p} is in the API — it is the factory")
    if re.search(r"(^|/)(\.env(\.local)?|\.dev\.vars|node_modules|\.orun|\.wrangler|dist)(/|$)", p):
        bad(f"{p} is in the API — a local or built file")
ai = {p for p in tracked if p.startswith("ai/")}
if ai != {"ai/context/deployment.md", "ai/context/operations.md"}:
    bad(f"ai/ in the API is {sorted(ai)}")

# No tracked file names a factory path: the product has none of them.
FACTORY = re.compile(
    r"repo-blueprint|BOOTSTRAP\.md|(?<![\w.-])(testing|specs|tasks|docs/phases|hooks)/"
    r"|\.baseline/|tooling/(rebrand|bootstrap)/")
for p in tracked:
    if p == "pnpm-lock.yaml":
        continue
    try:
        text = (tree / p).read_text()
    except UnicodeDecodeError:
        continue
    for n, line in enumerate(text.splitlines(), 1):
        m = FACTORY.search(line)
        if m:
            bad(f"{p}:{n} names the factory path {m.group(0)!r}: {line.strip()[:80]}")

# The identity, where the API carries it.
ident = (tree / "apps/api/src/identity.ts").read_text()
if f"API_NAME = {json.dumps(name)}" not in ident:
    bad(f"apps/api/src/identity.ts does not name the API {name!r}")
wrangler = (tree / "apps/api/wrangler.jsonc").read_text()
wname = re.search(r'^\s*"name":\s*"([^"]+)"', wrangler, re.M)
if not wname or wname.group(1) != f"{repo}-api":
    bad(f"wrangler.jsonc names the Worker {wname and wname.group(1)!r}, not {repo}-api")
comp = yaml.safe_load((tree / "apps/api/component.yaml").read_text())["spec"]["parameters"]
if f"https://{repo}-api-${{ORUN_ENVIRONMENT}}.{sub}.workers.dev" not in comp["smokeCommand"]:
    bad(f"the smoke does not read the API's own Worker: {comp['smokeCommand']}")
if comp["wranglerConfig"] != "wrangler.jsonc" or comp.get("wranglerTemplate"):
    bad("the Worker's config is no longer the committed wrangler.jsonc")
if json.loads((tree / "package.json").read_text())["name"] != repo:
    bad("package.json is not named for the API")

# The intent: re-tenanted, no work tree, both gates back.
intent_text = (tree / "intent.yaml").read_text()
intent = yaml.safe_load(intent_text)
if intent["metadata"]["name"] != repo:
    bad(f"intent metadata.name is {intent['metadata']['name']}")
if intent["execution"]["state"]["workspace"] != values["orunWorkspace"]:
    bad(f"intent workspace is {intent['execution']['state']['workspace']}, not the API's")
if "work" in intent:
    bad("intent.yaml still declares the baseline's work tree")
if "promotion" not in intent["environments"]["prod"] or "@promotion-deferred" in intent_text:
    bad("prod's promotion gate was not restored by 02-docs")
if "github-push-main" not in intent["environments"]["dev"]["activation"]["triggerRefs"] or "@dev-lanes-deferred" in intent_text:
    bad("dev's push activation was not restored by 02-docs")
for env in ("stage", "prod"):
    want = f"https://{repo}-api-{env}.{sub}.workers.dev"
    if intent["environments"][env].get("url") != want:
        bad(f"environments.{env}.url is {intent['environments'][env].get('url')}, not {want}")
if any("SITE_URL" in ((e or {}).get("env") or {}) for e in intent["environments"].values()):
    bad("intent.yaml sets a SITE_URL — the API renders no absolute link to itself")
for page in (intent.get("repo") or {}).get("docs", {}).get("pages", []):
    if not (tree / page["path"]).exists():
        bad(f"intent repo.docs names {page['path']}, which the API does not have")

# The landing, as 01-product made it.
for rel in ("apps/api/component.yaml", "tests/api/component.yaml"):
    if not re.search(r"^# orun: redeploy 01-product \S+$", (tree / rel).read_text(), re.M):
        bad(f"{rel} carries no 01-product redeploy marker")
dep = (tree / "ai/context/deployment.md").read_text()
if "GENERATED by the `02-docs` phase" not in dep or f"https://{repo}-api-prod.{sub}.workers.dev/health" not in dep:
    bad("ai/context/deployment.md was not rendered for the API")
readme = (tree / "README.md").read_text()
if not readme.startswith(f"# {repo}\n") or "This Slack bot is **live**" not in readme:
    bad("README.md is not the bot's, or its live-deployment section was not rendered")
if f"`https://{repo}-api-prod.{sub}.workers.dev/api/events`" not in readme:
    bad("README.md's live-deployment section does not give Slack the bot's own /api/events URL")

# Provenance prose, over the BRANDED files.
PROV = re.compile(r"\bfork(ed)? (of|from)\b|\bbaseline (repo|repository|commit|tag)\b|\bthis baseline\b", re.I)
for rel in tracked:
    if not re.search(r"\.(md|ts|json|jsonc|ya?ml|js|mjs)$", rel) or rel == "pnpm-lock.yaml":
        continue
    for n, line in enumerate((tree / rel).read_text().splitlines(), 1):
        if PROV.search(line):
            bad(f"{rel}:{n} speaks of the factory: {line.strip()[:70]}")

if problems:
    for p in problems:
        print(f"  ✕ {p}", file=sys.stderr)
    sys.exit(1)
print(f"   {len(tracked)} tracked files; branded, re-tenanted, gates restored, record rendered; no factory path named")
PY

# ── 4. the product's own CI, over the 01-product merge ─────────────────────
# Exactly ci.yml's plan step: a GitHub push event for the commit 01-product
# merged, whose `before` is the repository's Initial commit. The deferrals
# are in force at that commit (02-docs restores them later), so this is the
# plan the bootstrap's convergence watch waits on.
echo "── orun plan in the API, for the push that merged 01-product (as ci.yml plans it)"
s00="$(git -C "$tree" rev-parse HEAD~2)"; s01="$(git -C "$tree" rev-parse HEAD~1)"
git -C "$tree" checkout -q "$s01"
cat > "$scratch/push.json" <<EOF
{"ref": "refs/heads/main", "before": "$s00", "after": "$s01", "created": false, "forced": false,
 "repository": {"name": "$repo", "full_name": "$org/$repo", "default_branch": "main", "owner": {"login": "$org"}},
 "head_commit": {"id": "$s01"}}
EOF
(cd "$tree" && orun validate --intent intent.yaml) > "$scratch/validate.log" 2>&1 \
  || { fail "orun validate refused the API's intent at 01-product"; tail -10 "$scratch/validate.log" >&2; }
(cd "$tree" && env GITHUB_ACTIONS=true GITHUB_EVENT_NAME=push GITHUB_EVENT_PATH="$scratch/push.json" \
     GITHUB_REF=refs/heads/main GITHUB_SHA="$s01" GITHUB_REPOSITORY="$org/$repo" \
   orun plan --from-ci github --event-file "$scratch/push.json" --intent intent.yaml \
     --output "$scratch/plan.json" --changed) > "$scratch/plan.log" 2>&1 \
  || { fail "orun plan failed in the API at 01-product"; tail -15 "$scratch/plan.log" >&2; }
git -C "$tree" checkout -q main
python3 - "$scratch/plan.json" "$values" "$tree" <<'PY' || fails=$((fails + 1))
import json, pathlib, sys
import yaml
plan, values, tree = json.load(open(sys.argv[1])), json.load(open(sys.argv[2])), pathlib.Path(sys.argv[3])
repo, sub, ws = values["reponame"], values["subdomain"], values["orunWorkspace"]
problems = []
def bad(m): problems.append(m)
trig = (plan.get("metadata") or {}).get("trigger") or {}
if trig.get("name") != "github-push-main" or trig.get("mode") != "event-file":
    bad(f"the plan did not come from the push event: {trig}")
jobs = {(j["component"], j["environment"]): j for j in plan["jobs"]}
by_id = {j["id"]: j for j in plan["jobs"]}

# INFRA BEFORE APP. Every component under infra/ that a deploy reads wiring
# from must be a job the deploy waits on. This API has no infra component, so
# the rule holds vacuously — and the API deploys with nothing to wait for.
infra = {c.parent.name for c in tree.glob("infra/*/component.yaml")}
infra_names = {yaml.safe_load((tree / "infra" / d / "component.yaml").read_text())["metadata"]["name"] for d in infra}
for (comp, env), j in jobs.items():
    if comp in infra_names:
        continue
    waits = {by_id[d]["component"] for d in (j.get("dependsOn") or []) if d in by_id}
    for need in infra_names:
        if (need, env) in jobs and need not in waits:
            bad(f"{comp}@{env} does not wait on {need}@{env} — infrastructure must apply first")
order = "no infra component — nothing to order before the API" if not infra_names else f"{sorted(infra_names)} before the API"

if set(jobs) != {("api", "stage"), ("api", "prod")}:
    bad(f"the 01-product merge plans {sorted(jobs)}; it must deploy api to stage and prod and nothing else "
        f"(dev's push lanes are deferred during the bootstrap)")
for (comp, env), j in jobs.items():
    if not j["profile"].endswith(".deploy"):
        bad(f"{comp}@{env} plans profile {j['profile']}, not a deploy")
    if j.get("dependsOn"):
        bad(f"{comp}@{env} waits on {j['dependsOn']} — during the bootstrap stage and prod deploy side by side")
    steps = {s["id"]: s.get("run") or "" for s in j["steps"]}
    ids = [s["id"] for s in j["steps"]]
    for need in ("verify-worker-structure", "build-worker", "deploy", "smoke"):
        if need not in steps:
            bad(f"{comp}@{env} has no {need} step")
    if "verify-worker-structure" in ids and "build-worker" in ids and ids.index("verify-worker-structure") > ids.index("build-worker"):
        bad(f"{comp}@{env} checks the Worker's structure after the build")
    if 'test -f "wrangler.jsonc"' not in steps.get("verify-worker-structure", ""):
        bad(f"{comp}@{env}'s structure check does not look for the committed wrangler.jsonc")
    if f"--env {env}" not in steps.get("deploy", ""):
        bad(f"{comp}@{env} does not deploy with --env {env}")
    if f"https://{repo}-api-${{ORUN_ENVIRONMENT}}.{sub}.workers.dev" not in steps.get("smoke", ""):
        bad(f"{comp}@{env}'s smoke is not the API's own: {steps.get('smoke','')[:200]}")
    refs = {r["asEnv"]: r["ref"] for r in j.get("secretRefs") or []}
    for key in ("CLOUDFLARE_API_TOKEN", "CLOUDFLARE_ACCOUNT_ID"):
        ref = refs.get(key, "")
        if not ref.startswith(f"secret://{ws}/") or f"project:{repo}" not in ref:
            bad(f"{comp}@{env} resolves {key} from {ref or 'nowhere'} — not the API's workspace and project")
if problems:
    for p in problems:
        print(f"  ✕ {p}", file=sys.stderr)
    sys.exit(1)
print(f"   {order}; api → stage + prod, deploy, side by side; structure check, Worker, smoke and secrets the API's own")
PY

# ── 5. a resume over the finished API ──────────────────────────────────────
echo "── --resume over the finished API"
before="$(git -C "$tree" status --porcelain; git -C "$tree" rev-parse HEAD)"
orun new --blueprint "$root/repo-blueprint.yaml" --out "$tree" --resume "${sets[@]}" > "$scratch/resume.log" 2>&1 \
  || { fail "--resume did not run"; tail -10 "$scratch/resume.log" >&2; }
after="$(git -C "$tree" status --porcelain; git -C "$tree" rev-parse HEAD)"
[ "$before" = "$after" ] || { fail "--resume changed the finished API:"; git -C "$tree" status --short | head -10 >&2; }
grep -q "API_NAME = \"Sam's Tools & Things\"" "$tree/apps/api/src/identity.ts" \
  || fail "--resume reverted the API's identity"
[ "$fails" -eq 0 ] && echo "   nothing placed again, nothing un-branded"

[ "$fails" -eq 0 ] || { echo "placement.test.sh: $fails failure(s)" >&2; exit 1; }
echo "placement.test.sh: ok"
