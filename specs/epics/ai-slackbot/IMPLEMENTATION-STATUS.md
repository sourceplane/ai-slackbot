# ai-slackbot — implementation status

| Milestone | State | Landed |
|---|---|---|
| SB0 — the spec | ✅ | SB-1 |
| SB1 — the Slack bot on Workers | ✅ | SB-2 |
| SB2 — a baseline | ✅ | SB-3, tagged `baseline-v1` |

## Departures from the upstream template

Everything not listed here is the template as it is upstream at `7d84809`.

| # | What | Why |
|---|---|---|
| 1 | The app lives in `apps/api` of a pnpm workspace (`@app/api`); `api/events.ts` is a Hono route at the same path (`src/index.ts`), `lib/` is `src/lib/`, `policies/` is `apps/api/policies/` | The workspace's shape (hono-api's); a plain Worker |
| 2 | Every request is verified first, the URL verification included; a failure is a `400` before any work (upstream answered the challenge first and dropped the check's result) | A forged event must not be handled |
| 3 | The signature is checked with WebCrypto (`crypto.subtle` HMAC-SHA256, a constant-time compare); the timestamp must be digits | `node:crypto` is not the Worker's API for this; a malformed header is refused, not parsed |
| 4 | The event is acknowledged at once; `auth.test`, the handlers and the reply run in `c.executionCtx.waitUntil` (upstream awaited `auth.test` first, then `@vercel/functions`' `waitUntil`) | Slack's 3 s go to the acknowledgement |
| 5 | A retry (`X-Slack-Retry-Num`) is acknowledged with `X-Slack-No-Retry: 1` and not handled | Upstream answered every retry again |
| 6 | Before both Slack keys are set, `/api/events` answers `503 slack_not_connected` | A product deploys before its owner has a Slack app |
| 7 | The Slack client, the model and the search are built per request from the Worker's env (`src/lib/bot.ts`), passed to the handlers; upstream read `process.env` at import | A Worker's secrets arrive with the request |
| 8 | The model is Workers AI (`@cf/moonshotai/kimi-k2.6`, `workers-ai-provider` 4.0.1 over the `AI` binding) unless `OPENAI_API_KEY` is set, then OpenAI (`OPENAI_MODEL`, default `gpt-4o`) directly; Ollama (`MODEL_PROVIDER=ollama`) is not carried | No key by default; a Worker cannot reach `localhost` |
| 9 | `ai` 7.0.0-canary.164 → 7.0.155, `@ai-sdk/policy-opa` 1.0.0-canary.1 → 1.0.155, `@ai-sdk/openai` 4.0.0-canary.67 → 4.0.104 (the stable releases, one provider core); `ai-sdk-ollama`, `@vercel/functions`, `@ai-sdk/provider-utils` dropped; everything else at upstream's locked versions (`@slack/web-api` 7.16.0, `bash-tool` 1.3.17, `just-bash` 3.0.1, `exa-js` 1.10.3, OPA 2.0.0 / opa-wasm 1.10.0, `zod` 4.4.3) | `workers-ai-provider` 4 supports AI SDK 7 stable; `policy-opa` pins `ai` exactly |
| 10 | `policy.wasm` is imported as a `WebAssembly.Module` (`src/lib/policy/load.ts`, `src/wasm.d.ts`), not read from disk; `POLICY_MODE=http` needs `OPA_URL` (upstream defaulted to `localhost:8181`) | A Worker cannot compile bytes at runtime, and has no disk |
| 11 | `just-bash` resolves, in the Worker, to `src/vendor/just-bash.js` — its browser build, with `BashTransformPipeline` and `TeePlugin` as stubs that throw (wrangler `alias`) | The Node build needs `worker_threads` and native addons; bash-tool uses those two only for its opt-in tee transform |
| 12 | `searchWeb` is offered, and named in the system prompt, only when `EXA_API_KEY` is set (`toolNames`, `systemPrompt` in `run-agent.ts`) | A tool that can only fail is not offered |
| 13 | `GET /` is a JSON welcome (upstream's `vercel.json` redirected `/` to its GitHub repository); `GET /health` added: `status`, `name`, `environment`, `slack`, `model`, `tools` — names only | The deploy's smoke and the bootstrap's probes read it |
| 14 | `src/identity.ts`: `API_NAME = "AI SDK Slackbot"`, the one rename seam | One seam; Slack shows the Slack app's own name |
| 15 | `assistantThreadMessage` no longer logs the whole event (`JSON.stringify(event)`) | It carried user ids and channel ids into every log line |
| 16 | `wrangler.jsonc` (`<repo>-api`, `nodejs_compat`, the `AI` binding in every environment, the alias) and `component.yaml` (`cloudflare-worker-turbo`, five optional secrets pushed by `runtimeSecrets`, a smoke over `/health` and the events door) | The Worker's config and the deploy contract replace Vercel's |
| 17 | `policy:build` / `policy:test` run from `apps/api`; the policies README says the committed `policy.wasm` is what deploys (upstream claimed `pnpm build` rebuilt it, which its build script did not) | Accuracy; CI has no `opa` |
| 18 | `apps/api/LICENSE.md`: the MIT terms upstream's README declares, and that the repository ships no LICENSE file | The product carries the template's licence |
| 19 | Tests: `tests/api` (vitest, in-process) — the routes and every Slack event against stand-ins for Slack's Web API and the AI binding, the signature check against Node's HMAC, every rule of the shipped `policy.wasm`, the reply format, the model choice, the name seam | The template ships only the policy's Rego tests |

## Verified

- `pnpm typecheck`, `lint`, `test` (tests/api 29) and `build` green; the
  Worker is 1.03 MiB gzipped (5.3 MiB raw), with `policy.wasm` (143 KiB) its
  own module — Workers Free.
- Every Baseline CI tier passes locally on orun v2.89.0, and under
  `wrangler dev` the staged Worker answered as born (`503` on the events
  door) and connected: the signed challenge, refusals of unsigned, forged,
  stale and wrongly-keyed requests with no call made, a retry acknowledged
  only, a mention answered through the policy and just-bash (`ls`), a
  refusal relayed (`rm`), a DM from its thread, a new thread greeted.
