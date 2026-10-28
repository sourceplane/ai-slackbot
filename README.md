# ai-slackbot

Vercel's [AI SDK Slackbot](https://github.com/vercel-labs/ai-sdk-slackbot)
template — an AI chatbot for Slack that answers app mentions and direct
messages with an LLM and tools (weather, dice, a sandboxed bash, web search),
every tool call gated by an Open Policy Agent policy compiled to WebAssembly —
running natively as a **Cloudflare Worker**, deployed by
[Orun](https://github.com/sourceplane/orun) to stage and prod on every merge.
Packaging it as an Orun baseline is the next milestone (SB2).

Upstream's `api/events.ts` (a Vercel function) is a [Hono](https://hono.dev)
route here, at the same path: Hono's `fetch` handler is the Worker's, no
adapter. It verifies Slack's signature with WebCrypto before anything else,
acknowledges at once and answers in `waitUntil`. The model is Workers AI
through the Worker's own `AI` binding, so a fresh bot needs no AI key;
upstream's OpenAI is used, directly, once its key is stored. The policy, the
agent loop and the tools are upstream's. The bot is born **not connected**: it
deploys and `/api/events` says so until its owner creates a Slack app and
stores its two keys. See
[`specs/epics/ai-slackbot`](specs/epics/ai-slackbot/README.md) for the
design, the milestones and the as-built status.

## What is here (the product)

| Surface | Where |
|---|---|
| The routes — Slack's events at `POST /api/events`; `GET /` a JSON welcome, `GET /health` the bot's name, environment and what it is connected to | `apps/api/src/index.ts` |
| Slack: the signature check, the client, mentions, assistant threads and DMs | `apps/api/src/lib/slack-utils.ts`, `apps/api/src/lib/handle-*.ts` |
| The agent, its tools and the model | `apps/api/src/lib/run-agent.ts`, `generate-response.ts`, `model.ts` |
| The tool-call policy (Rego, and the WASM the Worker bundles) and its loader | `apps/api/policies/`, `apps/api/src/lib/policy/` |
| just-bash's browser build for the Worker | `apps/api/src/vendor/just-bash.js` (`wrangler.jsonc` → `alias`) |
| The bot's name (the rename's seam; what `/` and `/health` answer with) | `apps/api/src/identity.ts` |
| The template's licence (MIT, as its README declares) | `apps/api/LICENSE.md` |
| Worker config (name, Workers AI binding, per-environment vars) | `apps/api/wrangler.jsonc` |
| Deploy contract (and the keys it pushes as Worker secrets) | `apps/api/component.yaml` (`cloudflare-worker-turbo`) |
| Tests | `tests/api` (vitest: the routes and Slack's events in-process against stand-ins for Slack and Workers AI, the signature check, every policy rule) |

## Getting started

```bash
pnpm install
pnpm typecheck
pnpm lint
pnpm test
pnpm build            # wrangler deploy --dry-run → apps/api/dist (the bundle, no upload)
```

Run the Worker locally under workerd (Workers AI has no local mode, so
`wrangler dev` needs `wrangler login`; Slack's two keys go in
`apps/api/.dev.vars`):

```bash
pnpm --filter @app/api dev        # http://localhost:8787
curl http://localhost:8787/health # {"status":"ok","name":"AI SDK Slackbot","environment":"local","slack":…}
```

Connecting Slack: create a Slack app, put its signing secret and bot token in
`apps/api/.dev.vars` for local work (or store them as the environment's Orun
secrets and redeploy), and set its Request URL to the Worker's `/api/events`.

## How it maps to Vercel

| Vercel | Here |
|---|---|
| `api/events.ts`, a Vercel function | A Hono route at the same path, `POST /api/events`, on a plain Worker: `export default app` is the module handler; wrangler bundles `src/index.ts` with `nodejs_compat` |
| `waitUntil` from `@vercel/functions`, `maxDuration: 60` | The Worker's own `c.executionCtx.waitUntil`, after an immediate acknowledgement. A Worker keeps that work alive for about 30 s after the response, not 60 |
| Slack's signature checked with `node:crypto` — and the result dropped (`verifyRequest` returned a 400 nobody returned), the URL verification answered before it | WebCrypto HMAC-SHA256 over `v0:<ts>:<body>`, a constant-time compare and a five-minute window, checked FIRST for every request, the challenge included; a refusal is a 400 before any work |
| The bot's own id (`auth.test`) looked up before acknowledging | Looked up after, in the background, so Slack's 3 s go to the acknowledgement |
| Slack's retries (`X-Slack-Retry-Num`) handled as new events | Acknowledged (`X-Slack-No-Retry: 1`) and not answered again |
| `process.env` read at import; one `WebClient` per process | The Worker's secrets per request; a `WebClient` per event |
| OpenAI `gpt-4o` by default (`OPENAI_API_KEY`), or a local Ollama | Workers AI (`@cf/moonshotai/kimi-k2.6`) through the `AI` binding by default, no key; OpenAI directly once `OPENAI_API_KEY` is stored. Ollama is not carried: a Worker cannot reach `localhost` |
| AI SDK 7 canaries (`ai` 7.0.0-canary.164, `@ai-sdk/policy-opa` 1.0.0-canary.1, `@ai-sdk/openai` 4.0.0-canary.67) | Their stable releases (`ai` 7.0.155, `@ai-sdk/policy-opa` 1.0.155, `@ai-sdk/openai` 4.0.104), which `workers-ai-provider` 4 supports |
| `policies/policy.wasm` read from disk (`node:fs`) and compiled at runtime | Imported as a `WebAssembly.Module` that wrangler compiles at upload — a Worker refuses to compile bytes at runtime |
| `bash-tool` over `just-bash`'s Node build | The same `bash-tool`, over `just-bash`'s browser build (`src/vendor/just-bash.js`): the Node build's `python3`/`js` commands need `worker_threads` and its decompressors native addons. Two classes only bash-tool's opt-in tee transform uses are stubs that refuse |
| `searchWeb` always offered (Exa) | Offered, and named in the prompt, only when `EXA_API_KEY` is stored |
| `/` redirected to the template's GitHub repository | A JSON welcome naming the bot and its endpoints |
| Env vars in the Vercel project | Orun secrets per environment, pushed to the Worker as Worker secrets after each deploy (`runtimeSecrets`) |
| `vc dev` · `vc deploy` | `wrangler dev` · `wrangler deploy --env <stage\|prod>` |
| Deploy on push | Orun deploys `<repo>-api-{stage,prod}` on merge to `main` and smoke-tests `/health` and the signed events door (`apps/api/component.yaml`) |

## CI

| Workflow | What it runs | Ships to a bot |
|---|---|---|
| `ci.yml` | the Orun pipeline, and the only workflow a bot carries: `orun plan --changed`, then one job per lane. A pull request runs the verify lanes (the Worker built, type-checked and dry-deployed per environment; the tests' `quick-check` lane installs and checks the package, it does not run them), except the bootstrap's own landings (`orun/BASE-*`), where `plan` alone is the check; a merge deploys stage → prod. It plans nothing while `intent.yaml` names the placeholder workspace `ws_CHANGE_ME`, as this repository does. A manual run (Orunbase's Deploy button, or Run workflow on `main`) plans the environment and components it names under the push-to-main trigger, so they deploy as a merge deploys them | yes |

## Credits

The bot is Vercel's AI SDK Slackbot template
([vercel-labs/ai-sdk-slackbot](https://github.com/vercel-labs/ai-sdk-slackbot),
MIT as its README declares; the repository has no LICENSE file —
`apps/api/LICENSE.md`).
