# ai-slackbot — decisions

The choices that shape this repository, one line each, with where the full
reasoning lives. Superseded decisions stay listed, marked, so the history
reads in order.

| # | Decision | Why | Source |
|---|---|---|---|
| 1 | A plain Worker (`cloudflare-worker-turbo`), a Hono route at upstream's path (`POST /api/events`) | Upstream's `api/events.ts` is one function; Hono's default export is a Workers module handler, and the bot keeps no state between events — Slack's thread is the conversation | `specs/epics/ai-slackbot/design.md` |
| 2 | Slack's signature verified first, with WebCrypto, for every request — the URL verification included; a refusal is a 400 before any work | Upstream answered the challenge before verifying and dropped the check's result, so a forged event was handled | design.md §3 |
| 3 | Acknowledge at once; `auth.test`, the thread, the model and the reply in `waitUntil` | Slack retries what it does not see acknowledged in 3 s; upstream spent part of that on `auth.test` | design.md §3 |
| 4 | A retry (`X-Slack-Retry-Num`) is acknowledged with `X-Slack-No-Retry: 1` and not answered | Every event is acknowledged at once, so a retry is the same event again | design.md §3 |
| 5 | Workers AI (`@cf/moonshotai/kimi-k2.6`, the `AI` binding) by default; OpenAI directly with its key; Ollama not carried | No key nobody brokers; a model that calls tools (ai-chatbot's); a Worker cannot reach `localhost`. Never an AI gateway | design.md §4 |
| 6 | AI SDK 7 canaries → their stable releases (`ai` 7.0.155, `@ai-sdk/policy-opa` 1.0.155, `@ai-sdk/openai` 4.0.104); every other dependency at upstream's locked version | `workers-ai-provider` 4 supports AI SDK 7 stable; the policy package pins its `ai` version exactly | IMPLEMENTATION-STATUS |
| 7 | The policy as a bundled `WebAssembly.Module` (wrangler compiles the `.wasm` import at upload) | A Worker refuses to compile WebAssembly bytes at runtime; opa-wasm's loader takes a compiled module | design.md §5 |
| 8 | bash-tool kept, over just-bash's browser build (`src/vendor/just-bash.js`, wrangler `alias`) | The Node build needs `worker_threads` and native addons; the browser build is the same in-memory bash; two classes only the opt-in tee transform uses are stubs that refuse | design.md §5 |
| 9 | `searchWeb` offered, and named in the prompt, only with `EXA_API_KEY` | A tool that can only fail is not offered | design.md §4 |
| 10 | The bot's keys are optional Orun secrets pushed as Worker secrets after each deploy (`runtimeSecrets`); born not connected (`/api/events` 503) | A product deploys before its owner has a Slack app; no key reaches a build | design.md §6 |
| 11 | `GET /health` reports Slack, the model and the tools by name; the smoke reads it and checks the events door refuses an unsigned event | The deploy proves the environment and that the door is closed to forgeries, without a Slack app | operations.md |
| 12 | One name seam (`apps/api/src/identity.ts`, `API_NAME`) | The rename has one seam; Slack shows the Slack app's own name | IMPLEMENTATION-STATUS |
