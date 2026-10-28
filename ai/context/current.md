# ai-slackbot — where this repository stands

The entry page for anyone (or any agent) picking this repository up. It is
this repository's own state and does not ship to a bot built from it; the
two pages that do are [operations.md](operations.md) and
[deployment.md](deployment.md).

## What it is

Vercel's AI SDK Slackbot template — an AI chatbot for Slack whose every tool
call is gated by an Open Policy Agent policy — as one Cloudflare Worker,
packaged as an Orun baseline: `orun new --blueprint repo-blueprint.yaml`
builds a new Slack bot in its own repository and takes it to live on stage
and prod in one landing (`01-product`), then records what went live
(`02-docs`). The bot is born not connected; its owner creates the Slack app
and stores its two keys afterwards.

## Release

| | |
|---|---|
| Latest tag | `baseline-v1` (SB2 — the baseline) |
| Proven live | No. Everything short of the platform is proven offline in Baseline CI — the staged Worker served by `wrangler dev`, as born and connected, Slack's events driven against stand-ins for Slack's Web API and Workers AI; a live bootstrap from a tag, a real Slack workspace and a real Workers AI answer are still to come (risks SB-A, SB-B) |

## Where to read

| Question | Page |
|---|---|
| What shipped, and every departure from upstream | `specs/epics/ai-slackbot/IMPLEMENTATION-STATUS.md` |
| Why it is built this way | [decisions.md](decisions.md), then `specs/epics/ai-slackbot/design.md` |
| What could still go wrong | [open-risks.md](open-risks.md), then `specs/epics/ai-slackbot/risks-and-open-questions.md` |
| How to instantiate it | `BOOTSTRAP.md`, `docs/phases/` |
| What each component is | `apps/api/docs/`, `tests/api/docs/` (generated; `python3 tooling/catalog/gen-component-docs.py`) |

## Next

1. Bootstrap one bot from `baseline-v1` against a workspace, connect a Slack
   app to it, mention it and DM it, and record its timings (closes SB-A,
   SB-B).
