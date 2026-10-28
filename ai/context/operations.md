# ai-slackbot — operating contract (for humans and agents)

This is the standing guide to how this Slack bot is deployed and operated.
Instance facts (live URLs, workspace, the secrets it uses) live in
[deployment.md](deployment.md), rendered from probed reality by the
bootstrap's `02-docs` phase; this file is the contract that stays true
between deployments. It is written to give an agent with repository read
access enough context to reason about and operate the bot without any
other source.

## What this system is

An AI chatbot for Slack on Cloudflare alone, expressed as an Orun
component-native desired-state repo.

- **`apps/api`** — the bot: one Hono app, bundled by wrangler into one
  Cloudflare Worker (`cloudflare-worker-turbo`). `POST /api/events` is
  Slack's Events API door. Every request is verified FIRST — Slack's
  signature, HMAC-SHA256 over `v0:<timestamp>:<body>` with the app's signing
  secret, a constant-time compare and a five-minute window — and a request
  that fails it is a `400` before any work. A signed `url_verification` is
  answered with its challenge; a retry (`X-Slack-Retry-Num`) is acknowledged
  and not answered again; an `event_callback` is acknowledged at once and
  answered in `waitUntil`: `app_mention` (a status message, then the answer
  in its place, in the thread), `message.im` in an assistant thread (the
  thread re-read with `conversations.replies`, the status set and cleared),
  `assistant_thread_started` (a greeting and two suggested prompts). Before
  Slack is connected (its two keys missing) the door answers `503` and does
  nothing. `GET /` is a JSON welcome; `GET /health` answers
  `{"status":"ok","name":…,"environment":…,"slack":…,"model":…,"tools":[…]}`
  — names only, never a value; anything else is a 404.
- **The agent** (`apps/api/src/lib/`) — the AI SDK's `generateText` over the
  thread, up to 10 steps, with the tools `getWeather` (Open-Meteo),
  `throwDice`, `bash` / `readFile` / `writeFile` (bash-tool over just-bash's
  in-memory workspace — no host, no network; the Worker runs just-bash's
  browser build, `src/vendor/just-bash.js`) and `searchWeb` (Exa, only when
  `EXA_API_KEY` is set). The model is Workers AI's
  `@cf/moonshotai/kimi-k2.6` through the Worker's `AI` binding, or OpenAI
  (`OPENAI_MODEL`, default `gpt-4o`) when `OPENAI_API_KEY` is set — called
  directly, never through an AI gateway.
- **The policy** (`apps/api/policies/`) — every tool call is checked by an
  Open Policy Agent policy before it runs: `decision.rego`, compiled to
  `policy.wasm`, which the Worker imports as a WebAssembly module (a Worker
  cannot compile bytes at runtime). A denial's reason is the reply, verbatim;
  every reply ends with a 🔧 footer naming each tool and its outcome. The
  committed `policy.wasm` is what deploys: after editing the Rego, rebuild it
  (`pnpm --filter @app/api policy:build`, needs `opa`) and commit both.
- **`tests/api`** — vitest: the routes and Slack's events driven in-process
  with `app.request()` against stand-ins for Slack's Web API and the AI
  binding (the real AI SDK, provider, policy and just-bash), the signature
  check against Node's own HMAC, and every rule of the shipped `policy.wasm`.
  A pull request's lanes do not run it (its `quick-check` lane on `dev`
  installs and checks the package; the Worker's lanes build, type-check and
  dry-deploy it): run `pnpm typecheck`, `pnpm lint` and `pnpm test` before
  you push.
- **`tooling/*`** — shared TypeScript and ESLint configuration, and the
  deploy-time wrangler renderer for workers that take wiring.

Environments: **`stage`** and **`prod`** are deployed; **`dev` is
verify-only by design** — lanes build, type-check and dry-run the deploy,
nothing deploys.

## Identity and tenancy

Every remote operation runs against ONE Orun workspace, declared in
`intent.yaml` under `execution.state.workspace` — committed, enforced, and
what CI uses. Do not remove it; headless credentials depend on it. If it
reads `ws_SET_ME`, the bootstrap had no workspace to write: set the real one
before anything else.

## How deployment works

1. Merge (or push) to `main`.
2. CI (`.github/workflows/ci.yml`) runs `orun plan --changed` — only
   components whose files changed are planned — then runs each planned lane
   with `orun run --remote-state`, authenticated by GitHub OIDC (the
   exchange resolves this repository's linked workspace server-side).
3. Each deploy lane installs the workspace, checks the Worker's structure
   (`package.json` and the committed `wrangler.jsonc`), builds and
   typechecks it, runs `wrangler deploy --env <env>` — the Worker is
   `ai-slackbot-api-<env>` — pushes the keys the environment has stored to
   the Worker as Worker secrets (`secrets-live`: `wrangler secret bulk`, names
   only in the log; a key nobody stored is skipped), and smoke-tests it:
   `/health` on its workers.dev URL must answer `"status":"ok"` for that
   environment, and `/api/events` must refuse an unsigned event (`503` before
   Slack is connected, `400` after).
4. `prod` deploys after `stage` has converged on the same commit
   (`environments.prod.promotion` in intent.yaml).
5. **The convergence run is the deployment.** A green run means every
   planned lane applied. Failed lanes are retried with
   `gh run rerun --failed`, which resumes the same execution.

Caveats that matter:

- A push that touches no component files plans zero lanes — that run is
  green and deployed nothing. Never treat "latest run green" as "bot
  converged"; probe `/health` instead.
- A key stored after a deploy reaches the Worker on the NEXT deploy: store
  it, then deploy by hand (below). A deploy pushes the keys that exist and
  deletes none; removing one from the Worker is `wrangler secret delete`.
- The answer runs in `waitUntil` after Slack's acknowledgement, which a
  Worker keeps alive for about 30 seconds after the response: a long
  multi-step answer can be cut off.
- A change to `intent.yaml`'s `environments` maps to no component and
  redeploys nothing on its own. Land it with a change under `apps/api`.

## Secrets model

- **Brokered provider secrets**: `CLOUDFLARE_API_TOKEN` (Workers deploy
  scope) and `CLOUDFLARE_ACCOUNT_ID` — pointers minted per run from the
  workspace's Cloudflare connection. No long-lived values at rest; nothing
  to rotate by hand.
- Inspect by NAME only: `orun secrets list --org <ws> --project` and
  `--env stage|prod`. No tooling in this repository prints a secret value,
  and no document in `ai/context/` may contain one.
- **The bot's own keys**, stored per environment by its owner and pushed to
  the Worker as Worker secrets on each deploy (`apps/api/component.yaml`:
  `optionalSecretEnv` + `runtimeSecrets`). None is required to deploy:
  - `SLACK_SIGNING_SECRET`, `SLACK_BOT_TOKEN` — the Slack app's; both are
    needed before `/api/events` answers;
  - `OPENAI_API_KEY` (and `OPENAI_MODEL`) — OpenAI instead of Workers AI;
  - `EXA_API_KEY` — the `searchWeb` tool.
  Set one with `orun secrets set <KEY> --org <ws> --env <env>`, then deploy.
  For local work they go in `apps/api/.dev.vars` (git-ignored).

## Verifying the system

```bash
# the bot on each environment (also recorded, probed, in deployment.md):
# its state by name, and Slack's door refusing an unsigned event
curl -s https://ai-slackbot-api-stage.your-workers-subdomain.workers.dev/health
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://ai-slackbot-api-prod.your-workers-subdomain.workers.dev/api/events -d '{}'
# the Worker's logs (the answers run after the response, in waitUntil)
pnpm --filter @app/api exec wrangler tail ai-slackbot-api-prod

# workspace readiness (integrations + repository link)
orun integrations list --org <ws> --json && orun cloud check --org <ws>
```

## Common operations

| task | how |
|---|---|
| connect Slack | create the Slack app, store `SLACK_SIGNING_SECRET` and `SLACK_BOT_TOKEN` for the environment, deploy it, then set the app's Request URL to `<worker URL>/api/events` and subscribe it to `app_mention`, `assistant_thread_started`, `message.im` (README, "Connect Slack") |
| add a tool | `tool()` in `apps/api/src/lib/run-agent.ts` and a rule for it in `apps/api/policies/decision.rego` (a tool the policy does not name is denied), `policy:build`, a test in `tests/api`, merge |
| change what the bot may do | edit `decision.rego` (and `decision_test.rego`), `pnpm --filter @app/api policy:test`, `policy:build`, commit the `.rego` and `policy.wasm` together, merge |
| change the model | `WORKERS_AI_MODEL` in `apps/api/src/lib/model.ts` (a model that calls tools); or store `OPENAI_API_KEY` to use OpenAI |
| deploy a change | merge to `main`; watch the run; failed lanes → `gh run rerun --failed` |
| deploy by hand | Orunbase's Deploy button, or `gh workflow run ci.yml --ref main -f environment=<env> [-f component=<a,b>]` — the named components (blank: every one) run in that environment as a merge runs them; started off `main` it is refused |
| redeploy without a change | edit the last line of `apps/api/component.yaml` (`# orun: redeploy <reason> <stamp>`) and merge — it is a deploy trigger, nothing reads it |
| rename the bot | `API_NAME` in `apps/api/src/identity.ts` — what `/` and `/health` answer with (the name users see in Slack is the Slack app's) |
| serve a custom domain | attach it to the Worker in Cloudflare (README, "Custom domain"), point the Slack app's Request URL at it, then replace the placeholder `ai-slackbot.example.com` in `intent.yaml`'s `BASE_DOMAIN` (every environment) with it; the workers.dev URL keeps answering for the smoke |
| add a key | `orun secrets set <KEY> --org <ws> --env <env>` and deploy; a new key name is also declared in the component's `optionalSecretEnv` and named in `runtimeSecrets` |
| remove a key from the Worker | `pnpm exec wrangler secret delete <KEY> --env <env>` from `apps/api` — a deploy never deletes one |
| headless credentials | `ORUN_TOKEN` (workspace-scoped) + `GITHUB_TOKEN` |

The deployment record is the bootstrap's `02-docs` phase. Re-running it (the
Orun console's Retry on that phase) re-probes the URLs and re-renders
[deployment.md](deployment.md); it is idempotent.

## Evolution

Structural changes (a second Worker, a data store for memory beyond Slack's
threads, a queue for answers longer than `waitUntil` allows) follow the same
contract that deployed the bot: add a component under `apps/`, `infra/` or
`packages/` with a `component.yaml`, land it as a pull request, and the
convergence run applies it. A Worker that reads an infra component's wiring
declares `dependsOn` on it, `mode: enforced` on `github-push-main`, so one
convergence applies the infra first.
