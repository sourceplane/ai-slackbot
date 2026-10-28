# 01-product — the bot, built in one landing

**Places** everything a bot built from this baseline is made of, as ONE
pull request: the root manifests (`intent.yaml`, `package.json`, the pnpm
workspace and lockfile, `turbo.json`), `.github/workflows`
(`ci.yml` — the baseline's own `baseline.yml` and
`tag.yml` are ignored), the shared TypeScript/ESLint config and the wrangler
renderer, the bot's README and its two context pages, the identity file
`.rebrand/values.json`, `.gitkeep` files for the four discovery roots, and
`apps/api` (the Worker and its deploy contract) with `tests/api` (vitest).

**Requires** the GitHub App installation on `githuborg` and the Cloudflare
connection — both probed, each waited for up to ten minutes. The platform
sees a pull request only through the installation on the account that owns
the repository, and every deploy credential is minted from the Cloudflare
connection.

## What runs

The run's task set-up — the epic, both milestones, both tasks — runs in the
background from the start (`background: true`), so every hook up to `task`
runs beside it; `task` is the first that waits for it.

| hook | what it does |
|---|---|
| `retouch` | the redeploy marker on `apps/api/component.yaml` and `tests/api/component.yaml` (`.baseline/tasks/01-product.TaskContract.yaml`'s `affects`) |
| `git-init`, `git-stage` | the rebrand enumerates with `git ls-files`, so the tree is a staged repo first |
| `rebrand` | renames the baseline's identity to the bot's (`tooling/rebrand/rebrand.mjs`): the repo slug, the Worker name, the `API_NAME` seam, the domain, the subdomain |
| `orun-workspace` | writes the bot's workspace into `intent.yaml` (`ws_SET_ME` if there is none — loud, not silent) |
| `work-tree` | removes the baseline's own `work:` block from `intent.yaml` — `specs/` and `tasks/` do not ship |
| `promotion` | defers prod's wait on stage until `02-docs` (both environments deploy side by side) |
| `dev-lanes` | keeps dev's verify lanes off main's convergences until `02-docs` |
| `git-restage`, `rebrand-verify` | refuses the landing if any baseline identity is left |
| `repo` | `orun.repo/ensure@v1` — creates `githuborg/reponame` (private unless `repoPrivate=false`) |
| `link` | `orun cloud link` (best effort) then `orun cloud check` — an unlinked repo stops here |
| `secrets` | `orun.integrations/reconcile@v1`, both keys in one hook, created side by side: `CLOUDFLARE_API_TOKEN`, brokered from the Cloudflare connection with the `workers-deploy` scope; `CLOUDFLARE_ACCOUNT_ID`, the connection fact |
| `task` | finds the phase's task (opened by the run-level list) and yields its key — waiting, if it must, for the background set-up |
| `land` | one PR bound to the task, its commit checked in the box first (`checks: local`: `orun validate`, then `orun plan` as the PR and as the merge would plan it, under a second); merged without waiting for the PR's CI |
| `converge` (await) | `orun.run/watch@v1` on the merge commit's run, read every 5 s; resumes it up to three times |
| `verify` (await) | `orun.http/probe@v1` on `/health` at both workers.dev URLs |

There is no `orun.secrets/exists@v1` await: the bot has no infra component,
so nothing lease-publishes a `WIRING_*` secret. A product that adds one (a
KV namespace, a D1 database) gives `apps/api/component.yaml` an enforced
`dependsOn` on it and resolves its wiring from its secret refs, so a green
convergence already says the document is where every later run reads it.

## What the convergence does

`orun plan --changed` plans `api` on stage and prod (the `deploy` profile)
and — dev's push activation being deferred — nothing on dev. Each lane:

1. installs the workspace (`pnpm install --frozen-lockfile`);
2. `verify-worker-structure` — `test -f package.json` and
   `test -f wrangler.jsonc`, BEFORE any build: the config is committed, never
   generated;
3. `wire-fixture` and `wire-live` — no-ops: the Worker is not
   wiring-templated;
4. builds and typechecks `@app/api`;
5. deploys `<reponame>-api-<env>` with `wrangler deploy --env <env>` (retried
   on Cloudflare's first-deploy race);
6. smoke-tests it: `/health` on its workers.dev URL must answer
   `"status":"ok"` for that environment, and `/api/events` must refuse an
   unsigned event — a 503 before Slack is connected, a 400 after (retried
   while the route propagates). Between the deploy and the smoke,
   `secrets-live` pushes the keys the environment has stored (Slack's two,
   and OpenAI's and Exa's if set) to the Worker as Worker secrets.

Stage and prod deploy side by side (the promotion gate is deferred).

`api-tests` verifies on dev only, on a pull request, and its `quick-check`
lane installs and checks the package; it does not run the tests. The
landing's own pull request runs `plan` alone, and nothing waits for it — the
same plan ran in the box before the push: the baseline's own CI installs,
type-checks, lints, tests and builds this exact tree before a tag is cut.

## Verified

The convergence run for the merge commit is green, and
`https://<reponame>-api-{stage,prod}.<subdomain>.workers.dev/health` answer.

## Troubleshooting

| symptom | cause → fix |
|---|---|
| parks on `waiting for github for <org>` | the workspace's GitHub connection is to another account. Connect the App installation on `<org>` (console → Integrations → GitHub), then `--resume` |
| parks on the `providers` probe for cloudflare | Cloudflare is not connected to the workspace. Connect it (console → Integrations → Cloudflare, paste the Account API token) |
| `link` fails: `… is not linked to workspace` | the credential cannot write links and the platform has not linked the repo. Allow-list it (console → Settings → Git repos) and re-run the phase |
| `land`: `the landing's own check failed — orun plan for …` | the placed tree does not plan; the next line is orun's error. Nothing was pushed. Fix it and re-run the phase |
| `rebrand-verify` lists leftovers | a file carries an identity form no rule renames. Add a rule to `tooling/rebrand/rebrand.mjs` (and a case to `testing/rebrand.test.sh`) |
| `intent.yaml` says `workspace: ws_SET_ME` | `orunWorkspace` was empty and the build ran outside a workspace. Set it and re-run |
| deploy lane: `secret resolution failed … CLOUDFLARE_API_TOKEN` | the reconcile did not run or minted against a revoked connection. Re-connect and re-run the phase; the reconcile re-mints only what is missing |
| deploy lane: Authentication error (10000) | the connection's token lacks Workers Scripts Write. Re-issue it with the permission groups the console's Connect recipe lists |
| smoke fails right after the FIRST deploy | workers.dev route propagation; the composition retries the smoke with backoff (~4.5 min). A convergence resume clears what is left |
| the watch says green, the probe says 404 | another workflow ran on the push and the watch took its run. Only `ci.yml` may run on a push to main |
| re-run lands nothing | the hooks did not run (`--run-hooks`), or the contract names no component — `node tooling/bootstrap/retouch.mjs --check --affects .baseline/tasks/01-product.TaskContract.yaml` in the bot's tree says which |

## Re-running

Idempotent: placement is additive, rebrand is a no-op on branded files,
`git init` and the repo step are guarded, and the reconcile keeps keys that
exist. A re-run of a phase whose PR already merged lands the retouch markers
alone, which re-plans exactly the components it names. Once the tree is
branded the phase derives as `drifted`, so `--resume` leaves it alone; re-run
it deliberately with `--phase 01-product` (or `--redo 01-product` under
`--resume`).
