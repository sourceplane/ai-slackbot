#!/usr/bin/env bash
# The phases in `repo-blueprint.yaml` must be the phases the bootstrap runs,
# placing what they are meant to place, saying what they are, and naming only
# what the engine can resolve.
#
# The partition below is the bootstrap's order, written down a second time on
# purpose: the order is load-bearing (the deployment record cannot be written
# before the API is live), and a module that drifts into another phase fails
# at landing time, live, with nothing in this repository having looked wrong.
# Moving one is a deliberate change, argued in the diff that edits both places.
#
# ONE LANDING BUILDS THE PRODUCT (cirrus-baseline baseline-v22): `01-product`
# places every module — root files, workflows, tooling, the API and its tests
# — brands it, and lands it as one pull request; it is the only phase that
# deploys. `02-docs` places nothing: it records what went live and puts back
# what `01-product` deferred. The hook chain of `01-product` is cirrus's,
# hook for hook, and is pinned below.
#
# And the shape that keeps a bootstrap fast (orun >= v2.88.0, ported from
# sourceplane/turso-starter's copy of this file): the run-level task set-up
# runs in the background, each phase finds its task just before its landing,
# each landing checks its commit here (`checks: local`), and the convergence
# watch reads every few seconds.
#
# Adapted from sourceplane/cirrus-baseline's testing/phases.test.sh: the
# narration rules and the hook-only rule are Cirrus's, unchanged.
#
# bash + python3 + PyYAML. No network, no fakes, no credential.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"

echo "── repo-blueprint.yaml phases against what the bootstrap runs"
python3 - "$root" <<'PY'
import pathlib, re, sys

try:
    import yaml
except ImportError:
    sys.exit("PyYAML is required for the phase contract test (pip install pyyaml)")

root = pathlib.Path(sys.argv[1])
problems = []
def bad(m): problems.append(m)

bp = yaml.safe_load((root / "repo-blueprint.yaml").read_text())
phases = bp.get("phases") or []
if not phases:
    sys.exit("repo-blueprint.yaml declares no phases — this check has gone blind")

PARTITION = {
    "01-product": ["ai-deployment", "ai-operations", "api", "api-tests", "discovery-roots",
                   "github-workflows", "rebrand-values", "root-gitignore", "root-intent",
                   "root-package-json", "root-pnpm-lock",
                   "root-pnpm-workspace", "root-readme", "root-turbo", "tooling-eslint",
                   "tooling-tsconfig", "tooling-wire", "vscode"],
    "02-docs": [],
}
HOOK_ONLY = {"02-docs"}
# The phases that DEPLOY, and so must give a re-run something to land.
DEPLOYS = {"01-product"}

by_name = {p["name"]: p for p in phases}
names = [p["name"] for p in phases]

# ── the order IS the execution order ──────────────────────────────────────
if names != sorted(names):
    bad(f"phases are not in execution order: {names}. The numbered name IS the "
        f"order; a phase out of sequence is a barrier in the wrong place.")
if names != list(PARTITION):
    bad(f"phases are {names}; the bootstrap runs {list(PARTITION)}")

# ── the partition has not drifted ─────────────────────────────────────────
for name, want in PARTITION.items():
    if name not in by_name:
        continue
    now = sorted(by_name[name].get("modules") or [])
    if now != sorted(want):
        bad(f"phase {name} no longer places what it placed: gained "
            f"{sorted(set(now) - set(want)) or '[]'}, lost {sorted(set(want) - set(now)) or '[]'}")
declared = {m["name"] for m in bp.get("modules") or []}
placed = {m for p in phases for m in (p.get("modules") or [])}
for m in sorted(declared - placed):
    bad(f"module {m} is declared and no phase places it")
for name in HOOK_ONLY:
    if by_name.get(name, {}).get("modules"):
        bad(f"phase {name} places modules — it is declared as hooks only")

# ── nothing may GATE on a phase the tree cannot answer for ────────────────
# A hook-only phase places no files, so orun derives it as `unknown`, and
# `requires.phases` fails closed on `unknown`: a requirement naming one can
# never be satisfied.
for p in phases:
    for need in ((p.get("requires") or {}).get("phases") or []):
        if need in HOOK_ONLY:
            bad(f"phase {p['name']} requires {need}, which places no files — require "
                f"its predecessor instead")
        if need not in by_name or names.index(need) >= names.index(p["name"]):
            bad(f"phase {p['name']} requires {need}, which does not run before it")

# ── every phase says what it is and what to budget ────────────────────────
for p in phases:
    for field in ("title", "expectedMinutes"):
        if not p.get(field):
            bad(f"phase {p['name']} declares no {field} — an operator reads both")
    if not (p.get("hooks") or {}):
        bad(f"phase {p['name']} declares no hooks — a phase that only places files "
            f"still has to land them")

def hooks_of(p):
    h = p.get("hooks") or {}
    if isinstance(h, list):
        return list(h)
    return [x for slot in ("pre", "post", "await") for x in (h.get(slot) or [])]

run_hooks = list((bp.get("hooks") or {}).get("preInstantiate") or [])

# ── every phase lands, and every landing is bound to its task ─────────────
for p in phases:
    ids = [h.get("id") for h in hooks_of(p)]
    lands = [h for h in hooks_of(p) if (h.get("uses") or "").startswith("orun.pr/land@")]
    if len(lands) != 1:
        bad(f"phase {p['name']} has {len(lands)} landing(s); a phase is ONE pull request")
        continue
    w = lands[0].get("with") or {}
    if w.get("task") != "{{ .phase.hooks.task.outputs.key }}":
        bad(f"phase {p['name']} lands without binding the PR to its task key")
    if "task" not in ids or ids.index("task") > ids.index(lands[0].get("id")):
        bad(f"phase {p['name']} must ensure its task before it lands")
    if p["name"] in DEPLOYS:
        if not any("retouch.mjs" in " ".join(h.get("run") or []) for h in hooks_of(p)):
            bad(f"phase {p['name']} deploys and has no retouch hook — a re-run after a "
                f"failed convergence would land an empty diff and redeploy nothing")
        awaits = (p.get("hooks") or {}).get("await") or []
        watch = [h for h in awaits if (h.get("uses") or "").startswith("orun.run/watch@")]
        if not watch or (watch[0].get("with") or {}).get("sha") != "{{ .phase.hooks.land.outputs.mergeSha }}":
            bad(f"phase {p['name']} deploys and does not watch the convergence of the "
                f"commit it merged (orun.run/watch@v1 with sha: mergeSha)")

# ── every phase's task is one the run-level list opens, in the same order ─
def task_names(hooks):
    return [(h.get("with") or {}).get("name") for h in hooks
            if (h.get("uses") or "").startswith("orun.task/ensure@")
            and (h.get("with") or {}).get("kind") == "task"]
opened = task_names(run_hooks)
per_phase = [n for p in phases for n in task_names(hooks_of(p))]
if opened != per_phase:
    bad(f"the run-level list opens tasks {opened}; the phases ensure {per_phase} — "
        f"a task is found by its title, so the two must be the same words")
milestones = [(h.get("with") or {}).get("name") for h in run_hooks
              if (h.get("with") or {}).get("kind") == "milestone"]
if milestones != names:
    bad(f"the run-level list opens milestones {milestones}; the phases are {names}")

# ── every contract a hook names exists, beside the blueprint ──────────────
for h in run_hooks + [x for p in phases for x in hooks_of(p)]:
    rel = (h.get("with") or {}).get("contract")
    if rel and not (root / rel).exists():
        bad(f"hook {h.get('id')} names contract {rel}, which does not exist")
    if rel and not rel.startswith(".baseline/tasks/"):
        bad(f"hook {h.get('id')} names contract {rel} outside .baseline/tasks/ — "
            f"`tasks/` is this repository's own work tree, where an unkeyed "
            f"contract is an error")
for p in phases:
    for h in hooks_of(p):
        argv = " ".join(h.get("run") or [])
        for ref in re.findall(r"\{\{ \.baseline\.dir \}\}/(\S+?)(?:\"|'|\s|$)", argv + " "):
            if not (root / ref).exists():
                bad(f"phase {p['name']} hook {h.get('id')} runs {ref}, which this "
                    f"repository does not have")

# ── every phase has a documentation page, and every page a phase ──────────
docs_dir = root / "docs" / "phases"
pages = {f.stem for f in docs_dir.glob("*.md")} - {"README"}
for n in names:
    if n not in pages:
        bad(f"phase {n} has no page at docs/phases/{n}.md")
for page in sorted(pages - set(names)):
    bad(f"docs/phases/{page}.md documents a phase repo-blueprint.yaml does not declare")

# ── narration: authored here, printed from state (Cirrus's rules) ─────────
META_AT = {
    "start": {"files", "expectedMinutes"},
    "await": {"files", "expectedMinutes"},
    "failed": {"files", "expectedMinutes"},
    "done": {"files", "expectedMinutes", "elapsed", "next"},
}
STATE_WORDS = {"done", "failed", "complete", "completed", "succeeded", "skipped"}
PHASE_KEYS = {"name", "title"}
input_keys = set((bp.get("inputs") or {}).keys())

ws_input = (bp.get("inputs") or {}).get("orunWorkspace") or {}
if ws_input.get("from") != "workspace":
    bad("inputs.orunWorkspace must declare `from: workspace` — a console build has no other way to say it")

def strip_expressions(line):
    return re.sub(r"\{\{.*?\}\}", "", line, flags=re.S)

def refs(line):
    found = []
    for expr in re.findall(r"\{\{(.*?)\}\}", line, re.S):
        found += re.findall(r"\.([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*)", expr)
    return found

def check_line(where, line, slot, hook_ids):
    prose = strip_expressions(line).lower()
    for w in STATE_WORDS:
        if re.search(rf"\b{w}\b", prose):
            bad(f"{where} asserts {w!r} — `state` is the truth and narration is the "
                f"caption. Describe the world, not the run.")
    for ref in refs(line):
        parts = ref.split(".")
        head = parts[0]
        if head == "phase":
            if len(parts) != 2 or parts[1] not in PHASE_KEYS:
                bad(f"{where} names .{ref}; a phase carries {sorted(PHASE_KEYS)}")
        elif head == "inputs":
            if len(parts) != 2 or parts[1] not in input_keys:
                bad(f"{where} names .{ref}, which is not a declared input")
        elif head == "meta":
            allowed = META_AT.get(slot, META_AT["start"])
            if len(parts) != 2 or parts[1] not in allowed:
                bad(f"{where} names .{ref}; the {slot} event carries {sorted(allowed)}")
        elif head == "hooks":
            if len(parts) < 2 or parts[1] not in hook_ids:
                bad(f"{where} names .{ref}; this phase has no such hook")
        else:
            bad(f"{where} names .{ref}; narration may reference phase, inputs, meta and hooks")

for p in phases:
    n = p.get("narrate") or {}
    ids = {h.get("id") for h in hooks_of(p)}
    awaits = bool((p.get("hooks") or {}).get("await"))
    for slot in ("start", "await", "done", "failed"):
        line = n.get(slot)
        if slot == "await" and not awaits:
            # A phase that waits on nothing never says its await line.
            if line:
                bad(f"phase {p['name']} declares narrate.await and has no await hooks — "
                    f"nobody would ever read it")
            continue
        if not line:
            bad(f"phase {p['name']} declares no narrate.{slot}")
            continue
        check_line(f"phase {p['name']} narrate.{slot}", line, slot, ids)
    for h in ((p.get("hooks") or {}).get("await") or []):
        line = h.get("narrate")
        if not line:
            bad(f"phase {p['name']} await hook {h.get('id')} declares no narrate — a "
                f"wait with no words reads as a stalled build")
            continue
        check_line(f"phase {p['name']} hook {h.get('id')} narrate", line, "done", ids)
    for slot in ("pre", "post"):
        for h in ((p.get("hooks") or {}).get(slot) or []):
            if h.get("narrate"):
                check_line(f"phase {p['name']} hook {h.get('id')} narrate", h["narrate"], "start", ids)

# ── ONE LANDING: every component is placed by the deploying phase ─────────
# A component placed by any other phase would deploy in a convergence of its
# own, after a landing of its own — the fixed cost the one-landing bootstrap
# exists to pay once.
module_from = {m["name"]: (m.get("from") or "").rstrip("/") for m in bp.get("modules") or []}
phase_of = {m: p["name"] for p in phases for m in (p.get("modules") or [])}
components = {c.parent.relative_to(root).as_posix()
              for c in root.rglob("component.yaml")
              if "node_modules" not in c.parts and ".git" not in c.parts and ".orun" not in c.parts}
for name, src in sorted(module_from.items()):
    if src in components and phase_of.get(name) not in DEPLOYS:
        bad(f"module {name} places the component {src} from phase {phase_of.get(name)}; "
            f"every component lands in {sorted(DEPLOYS)}")
watching = {p["name"] for p in phases
            if any((h.get("uses") or "").startswith("orun.run/watch@") for h in hooks_of(p))}
if watching != DEPLOYS:
    bad(f"the phases that watch a convergence are {sorted(watching)}; only {sorted(DEPLOYS)} deploys")

# ── 01-product's hook chain is cirrus-baseline's ─────────────────────────────
# The identity chain (retouch before git exists, then git, rebrand, re-tenant,
# the work-tree strip, the two deferrals, restage, verify), the repository and
# its link, the brokered credentials — ONE `secrets` reconcile (orun >=
# v2.87.0), after the link and before the landing whose convergence uses
# them — then the task, found just before the landing so that everything
# before it runs beside the background task set-up, and the landing. No
# lockfile hook: the shipped lockfile is installed frozen by the lanes and by
# testing/e2e.test.sh. No phase has a `pre` hook.
PRE = {"01-product": [], "02-docs": []}
CHAIN = ["retouch", "git-init", "git-stage", "rebrand", "orun-workspace",
         "work-tree", "promotion", "dev-lanes", "git-restage", "rebrand-verify",
         "repo", "link", "secrets", "task", "land"]
TYPED = {"repo": "orun.repo/ensure@v1", "secrets": "orun.integrations/reconcile@v1",
         "task": "orun.task/ensure@v1", "land": "orun.pr/land@v1"}
RUN_HAS = {"retouch": "retouch.mjs", "work-tree": "work-tree.mjs --strip",
           "promotion": "promotion.mjs --defer", "dev-lanes": "dev-lanes.mjs --defer",
           "rebrand": "rebrand.mjs --values", "rebrand-verify": "rebrand.mjs --verify"}
for name, want in PRE.items():
    got = [h.get("id") for h in ((by_name.get(name, {}).get("hooks") or {}).get("pre") or [])]
    if got != want:
        bad(f"phase {name}'s pre hooks are {got}; want {want} — a task found in `pre` waits "
            f"for the background task set-up before the phase has done anything")
product = by_name.get("01-product") or {}
post = (product.get("hooks") or {}).get("post") or []
chain = [h.get("id") for h in post]
if chain != CHAIN:
    bad(f"01-product's post hooks are {chain}; cirrus-baseline's are {CHAIN}")
# One reconcile per provider, every key it mints listed in `secrets:` with its
# own template: one connections read and one secrets read for all of them,
# the missing keys created side by side — not one hook (and two round trips)
# per key.
reconciles = [h for h in post if (h.get("uses") or "") == "orun.integrations/reconcile@v1"]
if not reconciles:
    bad("01-product mints no credential — its convergence deploys, and binds CLOUDFLARE_API_TOKEN")
providers = [(h.get("with") or {}).get("provider") for h in reconciles]
if len(set(providers)) != len(providers):
    bad(f"01-product reconciles {providers} — one hook per provider, its keys in `secrets:`")
for h in reconciles:
    w = h.get("with") or {}
    items = w.get("secrets") or []
    if w.get("keys") or w.get("template") or not items or \
            any(not (i or {}).get("key") or not (i or {}).get("template") for i in items):
        bad(f"reconcile hook {h.get('id')} does not mint its keys as `secrets: [{{key, template}}]` — "
            f"one hook per provider, each key under its own scope template")
for h in post:
    want = TYPED.get(h.get("id"))
    if want and h.get("uses") != want:
        bad(f"01-product hook {h.get('id')} uses {h.get('uses')!r}, not {want}")
    need = RUN_HAS.get(h.get("id"))
    if need and need not in " ".join(h.get("run") or []):
        bad(f"01-product hook {h.get('id')} does not run `{need}`")

# The await: the convergence of the merge commit, then the URLs. There is no
# wiring await (orun.secrets/exists@v1): this API has no infra component, so
# nothing lease-publishes a WIRING_* document. Were one added, its readers
# would prove it instead — the Worker resolving the document in the same
# convergence from its component.yaml secret refs, where every later run
# reads it, fail-closed — which is the rule sourceplane/turso-starter's copy
# of this file holds. It is not ported here because there is nothing for it
# to read, so an infra component stops this test until it is (or until its
# wiring is awaited again).
infra = sorted(c for c in components if c.startswith("infra/"))
if infra:
    bad(f"{infra} would publish wiring this file does not check — port turso-starter's reader "
        f"rule (each WIRING_* resolved in the convergence on stage and prod, the reader waiting "
        f"for its publisher on main), or await it with orun.secrets/exists@v1")
awaits = (product.get("hooks") or {}).get("await") or []
if [h.get("id") for h in awaits] != ["converge", "verify"]:
    bad(f"01-product's await hooks are {[h.get('id') for h in awaits]}; want ['converge', 'verify']")
kinds = [(h.get("uses") or "").split("@")[0] for h in awaits]
want_kinds = ["orun.run/watch", "orun.http/probe"]
if kinds != want_kinds:
    bad(f"01-product awaits {kinds}; it must await {want_kinds}")
probe_urls = []
for h in awaits:
    if (h.get("uses") or "").startswith("orun.http/probe@"):
        probe_urls = (h.get("with") or {}).get("urls") or []
for env in ("stage", "prod"):
    if not any(f"-{env}." in u for u in probe_urls):
        bad(f"01-product's probe names no {env} URL: {probe_urls}")

# 02-docs: puts back what 01-product deferred, renders the record, finds its
# task, lands — and awaits nothing: its render probes every URL as it writes
# the record, and its landing redeploys nothing, so there is no probe after
# it to wait for.
docs = by_name.get("02-docs") or {}
dpost = (docs.get("hooks") or {}).get("post") or []
if [h.get("id") for h in dpost] != ["promotion", "dev-lanes", "render", "task", "land"]:
    bad(f"02-docs's post hooks are {[h.get('id') for h in dpost]}; want promotion, dev-lanes, render, task, land")
for h in dpost:
    argv = " ".join(h.get("run") or [])
    if h.get("id") in ("promotion", "dev-lanes") and "--restore" not in argv:
        bad(f"02-docs hook {h.get('id')} does not --restore")
dawait = (docs.get("hooks") or {}).get("await") or []
if dawait:
    bad(f"02-docs awaits {[h.get('id') for h in dawait]} — its render probes as it writes and its "
        f"landing redeploys nothing, so there is nothing after it to wait for")

# ── THE FAST SHAPE (orun >= v2.88.0) ──────────────────────────────────────
# The run-level list is the task set-up, all of it in the background: the
# first phase's provider check, placement, rebrand, repository, link and
# secrets run while it opens the epic, the milestones and the tasks.
for h in run_hooks:
    if not h.get("background"):
        bad(f"hooks.preInstantiate {h.get('id')} is not `background: true` — the first phase "
            f"waits for it before doing anything, though nothing before its landing reads it")
# No phase keeps a `pre` hook on the task plane: it would wait for the whole
# background before the phase has placed a file.
TASK_PLANE = ("orun.task/", "orun.pr/land@")
for p in phases:
    for h in ((p.get("hooks") or {}).get("pre") or []):
        if (h.get("uses") or "").startswith(TASK_PLANE):
            bad(f"phase {p['name']} pre hook {h.get('id')} uses {h['uses']} — it waits for "
                f"the background task set-up; find the task in `post`, just before the landing")
# Every landing checks its commit here and merges, instead of waiting ~25 s
# for a runner to plan the tree this box just wrote.
for p in phases:
    for h in hooks_of(p):
        if (h.get("uses") or "").startswith("orun.pr/land@") and (h.get("with") or {}).get("checks") != "local":
            bad(f"phase {p['name']} lands with checks {(h.get('with') or {}).get('checks', 'ci')!r}, "
                f"not 'local' — it waits for a runner to plan a tree that is here")
# The convergence watch reads every few seconds, not the action's default 40.
for p in phases:
    for h in ((p.get("hooks") or {}).get("await") or []):
        if (h.get("uses") or "").startswith("orun.run/watch@"):
            every = (h.get("with") or {}).get("pollSeconds")
            if not isinstance(every, int) or every > 10:
                bad(f"phase {p['name']} watches its convergence every {every or 40} s; at most 10 — "
                    f"the build goes on that much after the run is green")

# ── what a baseline of this shape never grows back ────────────────────────
if (root / "flows").exists():
    bad("flows/ exists — the bootstrap is the blueprint; every mechanism is a typed orun action")

if problems:
    print("FAIL: the blueprint's phases and the bootstrap disagree:", file=sys.stderr)
    for p in problems:
        print(f"  - {p}", file=sys.stderr)
    sys.exit(1)

placed_n = sum(len(p.get("modules") or []) for p in phases)
narrated = sum(len(p.get("narrate") or {}) for p in phases)
narrated += sum(1 for p in phases for h in hooks_of(p) if h.get("narrate"))
print(f"   {len(phases)} phases, {placed_n} modules, {len(HOOK_ONLY)} hook-only — in execution order")
print(f"   hooks in the one-landing order; task set-up in the background, every landing checked here")
print(f"   {narrated} authored narration lines, every reference resolving")
PY

echo "phases.test.sh: ok"
