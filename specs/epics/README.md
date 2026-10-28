# Epics

Orun-style work programs. Each epic is a folder carrying `epic.yaml` (the
declaration the platform reads: slug, key prefix, milestones with exit
criteria and task keys) beside its doc set. The pull request that adds the
folder is the adoption; the merge creates the epic in the workspace.

| Epic | Cluster | Status | What it is |
|------|---------|--------|------------|
| [`ai-slackbot/`](./ai-slackbot/) | **SB** | In progress (SB1: the site on Workers) | Vercel's AI SDK Slackbot — an AI chatbot for Slack whose every tool call an Open Policy Agent policy gates — as one Cloudflare Worker answering Slack's Events API with Workers AI, and an Orun baseline that instantiates it in one landing (SB2) |

As-built ≠ intent: what shipped lives in each epic's `IMPLEMENTATION-STATUS.md`.
