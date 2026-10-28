# ai-slackbot — Vercel's AI SDK Slackbot on Cloudflare Workers

**The template is a Slack bot in one Vercel function — Slack's Events API at
`api/events.ts`, answered by an AI SDK agent whose every tool call an Open
Policy Agent policy gates — so the port is a Hono route at the same path on
one plain Cloudflare Worker: Slack's signature verified first, the event
acknowledged at once and answered in `waitUntil`, Workers AI as the model so
it needs no key, deployed by Orun to stage and prod on every merge — and the
baseline that makes a copy of it somebody else's bot in one landing.**

| | |
|---|---|
| Status | In progress — SB0 on main |
| Upstream | [vercel-labs/ai-sdk-slackbot](https://github.com/vercel-labs/ai-sdk-slackbot) (MIT, as its README declares; no LICENSE file), at `7d84809` |
| Reference | [hono-api](https://github.com/sourceplane/hono-api) and hono-mcp — the same plain Worker, scaffolding, tests and bootstrap |
| Key | `SB` |

## Read in this order

1. [design.md](design.md) — the template, how each Vercel piece maps to
   Cloudflare, the repository and the build, and the alternatives rejected.
2. [implementation-plan.md](implementation-plan.md) — the milestones and
   what each one lands.
3. [risks-and-open-questions.md](risks-and-open-questions.md) — what is not
   proven, and what was accepted.
4. [IMPLEMENTATION-STATUS.md](IMPLEMENTATION-STATUS.md) — what shipped, and
   every departure from the upstream template.

## Milestones

| Milestone | What it lands | Task |
|---|---|---|
| SB0 — the spec | the repository, its intent, CI, tooling and spec index; this doc set | SB-1 |
| SB1 — the Slack bot on Workers | the template in `apps/api` as one plain Worker, its policy, its tests, the README | SB-2 |
| SB2 — a baseline | the console card, the build document, the context pack and the baseline's tests | SB-3 |
