# ai-slackbot — design

## 1. The template

Vercel's AI SDK Slackbot (`vercel-labs/ai-sdk-slackbot`, at `7d84809`) is one
Vercel function, `api/events.ts`, that Slack's Events API POSTs to. It
answers the URL verification, then hands `app_mention`,
`assistant_thread_started` and `message.im` events to handlers under `lib/`
inside Vercel's `waitUntil`. The handlers post a status, read the thread
(`conversations.replies`), run an AI SDK agent (`generateText`, up to ten
steps) and post or update the answer. The agent's tools are `getWeather`
(Open-Meteo), `searchWeb` (Exa), `throwDice` and bash-tool's `bash`,
`readFile` and `writeFile` over just-bash's in-memory workspace; every tool
call is gated by `@ai-sdk/policy-opa` against an OPA policy
(`policies/decision.rego`), compiled to WASM and read from disk. The model is
OpenAI's `gpt-4o`, or a local Ollama.

## 2. Where it runs

One plain Cloudflare Worker (`cloudflare-worker-turbo`): a Hono app whose
default export is the module handler, the route at upstream's path. Nothing
outlives a request — Slack's thread is the conversation, re-read each turn —
so there is no Durable Object, no database and no queue.

## 3. Slack's door

Every request is verified FIRST: the `X-Slack-Signature` header against an
HMAC-SHA256 of `v0:<X-Slack-Request-Timestamp>:<raw body>` with the app's
signing secret (WebCrypto; a constant-time compare), refused if the timestamp
is more than five minutes from now. Upstream answered the URL verification
before verifying and dropped the check's result (`verifyRequest` returned a
400 nobody returned), so a forged event was handled as a real one; here a
failure is a `400` and nothing else happens. Then: the challenge is answered;
a retry (`X-Slack-Retry-Num`) is acknowledged with `X-Slack-No-Retry: 1` and
not answered again, because the first delivery was acknowledged at once and
is already being answered; an `event_callback` is acknowledged at once and
everything — the bot's own id (`auth.test`, which upstream looked up before
acknowledging), the thread, the model, the reply — runs in the Worker's
`waitUntil`. Before Slack is connected (either key missing) the door answers
`503` with what to do, and does nothing.

**Rejected:** answering the challenge unsigned, as upstream (a forged
challenge is harmless, but one rule — verify first — is simpler to hold);
deduplicating retries by event id in KV (every event is acknowledged in
milliseconds, so a retry means Slack lost the acknowledgement, not that the
answer is missing); a Queue for the answer (not an Orun composition yet —
the 30-second `waitUntil` window is risk SB-C).

## 4. The model and the tools

Workers AI through the Worker's own `AI` binding, `@cf/moonshotai/kimi-k2.6`
— a model that calls tools, the one ai-chatbot uses — via
`workers-ai-provider`, so a fresh bot answers with no key. Upstream's OpenAI
is used, directly with `@ai-sdk/openai`, once `OPENAI_API_KEY` is stored
(`OPENAI_MODEL` picks the model, as upstream). Never an AI gateway. Ollama is
not carried: it serves on `localhost`, which a deployed Worker cannot reach.
`searchWeb` needs Exa's key, so without `EXA_API_KEY` the model is not
offered it and the system prompt does not name it — a tool that can only
fail is not a tool.

**Rejected:** OpenAI as the default (a key nobody brokers); AI SDK 7's
string model ids (they route through Vercel's AI Gateway).

## 5. The policy and the sandbox on Workers

A Worker cannot compile WebAssembly bytes at runtime. So `policy.wasm` is an
import, which wrangler compiles at upload into a `WebAssembly.Module`, and
opa-wasm's `loadPolicy` — which `@ai-sdk/policy-opa`'s `wasmPolicyClient`
calls with whatever it is given — takes a module as readily as bytes. The
committed `policy.wasm` is what deploys; `policy:build` rebuilds it with the
`opa` CLI, which CI does not carry.

just-bash ships a Node build and a browser build. The Node build's `python3`
and `js` commands need `node:worker_threads`, and its decompressors load
native addons; neither runs in a Worker. The browser build is the same
in-memory bash without them, but it lacks two classes bash-tool imports
from the package root — `BashTransformPipeline` and `TeePlugin`, used only
by bash-tool's opt-in `experimentalTeeTransform`, which the template never
turns on. So wrangler aliases `just-bash` to `src/vendor/just-bash.js`: the
browser build re-exported, and those two as stubs that throw if anyone turns
the transform on. bash-tool itself is upstream's. Under Node (the tests) the
package's own Node build is used.

**Rejected:** writing the three tools again over just-bash directly (more
code, and the template's tool descriptions and output limits would drift);
dropping the sandbox (it is the template's showcase of policy-gated
actions).

## 6. Keys and the repository

The bot's keys — `SLACK_SIGNING_SECRET`, `SLACK_BOT_TOKEN`, and optionally
`OPENAI_API_KEY`, `OPENAI_MODEL`, `EXA_API_KEY` — are the owner's Orun
secrets per environment, declared in `optionalSecretEnv` and pushed to the
Worker as Worker secrets after each deploy by the composition's
`secrets-live` step (`runtimeSecrets`). None reaches a build. The bot is
therefore born not connected and says so; the README walks through creating
the Slack app.

The repository is hono-mcp's (hono-api's shape): `apps/api`, `tests/api`,
the shared tooling, two phases. `/health` reports what the bot is connected
to by name, and the deploy's smoke checks it and that the events door
refuses an unsigned event — the one check that needs no Slack app.
