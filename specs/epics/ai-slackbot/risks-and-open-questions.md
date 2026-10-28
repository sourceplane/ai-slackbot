# ai-slackbot — risks and open questions

| ID | Risk | State | Notes |
|---|---|---|---|
| SB-A | `baseline-v1` is not yet proven live: the repository created and linked, the deploy token minted, a real deploy, the keys pushed by `secrets-live`, the smoke and the probes | OPEN | Proven offline in Baseline CI: the offline bootstrap with the blueprint's own hooks, the stage lane's own steps in a staged job tree, the Worker served as born and connected |
| SB-B | No real Slack workspace and no real Workers AI answer | OPEN | The e2e's stand-ins (`testing/lib/fake-slack-api.py`, `fake-workers-ai.js`) check the token, the payloads and the call order; whether `kimi-k2.6` uses the tools as well as `gpt-4o` is unmeasured |
| SB-C | `waitUntil` keeps background work alive for about 30 s after the response; upstream's function had 60 s | WATCH | A long multi-step answer (ten steps, web search) can be cut off. A Queue would lift it, and is not an Orun composition yet |
| SB-D | `workers-ai-provider` is deprecated (its successor is `agents/models/ai-sdk`); 4.0.1 is its AI SDK 7 release | WATCH | The same package ai-chatbot and nuxt-ai-chatbot run |
| SB-E | The policy's `allowed_dice_channel` is upstream's channel id | ACCEPTED | `throwDice` is denied everywhere until the owner sets theirs (README) |
| SB-F | Anyone can POST to `/api/events` | ACCEPTED | Only a request signed with the app's secret, within five minutes, is handled; the rest are a 400 before any work |
| SB-G | just-bash's `python3` and `js` commands are absent in the Worker (its browser build) | ACCEPTED | The policy's allow-list names neither |
| SB-H | A deploy pushes the keys that exist and deletes none | ACCEPTED | `wrangler secret delete` removes one (README) |
| SB-I | Upstream ships no LICENSE file; its README declares MIT, its package.json ISC | ACCEPTED | `apps/api/LICENSE.md` states this and carries the MIT terms |
| SB-J | `bash-tool` 1.3.17's peer range names `ai` ^6; the bot runs `ai` 7 | ACCEPTED | Upstream runs the same pair (on `ai` 7 canaries); 1.3.19 widens the range |
