# ai-slackbot — implementation plan

Three milestones, one task each, each landed as one pull request.

## SB0 — the spec (SB-1)

The repository is born with hono-api's frame — `intent.yaml` (dev
verify-only, stage, prod after stage; the placeholder workspace
`ws_CHANGE_ME`, so CI plans nothing until it is linked), `ci.yml` byte for
byte turso-starter's (as hono-api carries it), the shared TypeScript and
ESLint configuration, the wrangler renderer, the pnpm workspace and turbo
pipeline, and the spec index — and this doc set and the three task
contracts land on it.

## SB1 — the Slack bot on Workers (SB-2)

- `apps/api/src/index.ts`: upstream's `api/events.ts` as a Hono route at the
  same path — Slack's signature verified first with WebCrypto, the URL
  verification, retries acknowledged and not answered, the event handled in
  `waitUntil` — plus `/` and `/health`; `src/identity.ts` holds `API_NAME`.
- `src/lib/`: upstream's handlers, agent, reply builder and policy loader,
  taking a per-request context (the Slack client, the model, the optional
  search) instead of `process.env` at import; Workers AI as the default model
  (`model.ts`); Exa only with its key.
- `policies/`: upstream's Rego, its tests and its compiled `policy.wasm`,
  imported as a WebAssembly module; `src/vendor/just-bash.js`, just-bash's
  browser build for bash-tool.
- `wrangler.jsonc` (the `AI` binding in every environment, the just-bash
  alias) and `component.yaml` (`cloudflare-worker-turbo`, the five keys as
  optional secrets pushed by `runtimeSecrets`, a smoke over `/health` and the
  events door). `LICENSE.md`.
- `tests/api`: vitest — the routes and every Slack event in-process against
  stand-ins for Slack's Web API and the AI binding, the signature check
  against Node's HMAC, every rule of the shipped `policy.wasm`, the reply
  format, the model choice and the name seam.
- The README: connect Slack, run, test, deploy; how each Vercel piece maps.

Done when typecheck, lint, test and build are green, and `wrangler dev`
answers Slack's signed events against the stand-ins.

## SB2 — a baseline (SB-3)

hono-mcp's baseline machinery, adapted: the console card (`blueprint.yaml`)
and the build document (`repo-blueprint.yaml`) — two phases, `01-product` in
one landing and `02-docs` recording what went live — the rename engine with
its one seam (`API_NAME`) and `.wasm` excluded, the context pack, the
deployment-record hook probing `/health` and the events door, and the
baseline's tests: contract, leak (the policy and the vendor shim must ship),
placement, and the end-to-end tier serving the staged Worker as born and
connected, driving every Slack event through the stand-ins.
