# ai-slackbot — open risks

What is not yet proven or not yet decided. The full write-up of every risk,
including the accepted and resolved ones, is
`specs/epics/ai-slackbot/risks-and-open-questions.md`; this page lists only what
is still live, so it should be short.

| ID | Risk | State | What closes it |
|---|---|---|---|
| SB-A | No live bootstrap yet: the repository created and linked, the deploy token minted, a real `wrangler deploy`, the keys pushed, the smoke and the probes against workers.dev | OPEN | The first bootstrap from `baseline-v1` |
| SB-B | No real Slack workspace and no real Workers AI answer: the offline proof uses stand-ins for Slack's Web API and the AI binding; whether `kimi-k2.6` calls the tools as well as upstream's `gpt-4o` is unmeasured | OPEN | A live bootstrap connected to a Slack app |
| SB-C | `waitUntil` keeps background work alive for about 30 s after the response (upstream had 60 s): a long multi-step answer can be cut off | WATCH | Live timings; a queue if it bites (Queues are not an Orun composition yet) |
| SB-D | `workers-ai-provider` is deprecated in favour of `agents/models/ai-sdk`; 4.0.1 is its last AI SDK 7 release | WATCH | A move when the replacement is proven on the binding without a gateway |

Accepted, and worth knowing before you change them: SB-E (the policy's
`allowed_dice_channel` is upstream's channel id — set yours), SB-F (anyone
can POST to `/api/events`; only signed, fresh requests are handled), SB-G
(just-bash's `python3` and `js` commands are not in its browser build),
SB-H (a deploy pushes keys and deletes none), SB-I (upstream ships no LICENSE
file; its README declares MIT).
