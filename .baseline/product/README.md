# ai-slackbot

An AI chatbot for **Slack** on one **Cloudflare Worker**. It answers app
mentions and direct messages with an LLM and tools — the weather, a die, a
sandboxed `bash` over a small in-memory workspace, and web search once Exa's
key is stored — and every tool call is checked first against an
[Open Policy Agent](https://www.openpolicyagent.org) policy compiled to
WebAssembly, so what the bot may *do* is a Rego file you edit, not code.
Slack's Events API reaches it at `/api/events`, a [Hono](https://hono.dev)
route that verifies Slack's signature, acknowledges at once and answers in
the background. Its model is **Workers AI**, through the Worker's own `AI`
binding, so it needs no AI key; the [AI SDK](https://ai-sdk.dev) runs the
agent loop. Every merge to `main` deploys it to stage, then prod.

## Live deployment

<!-- 02-docs:begin -->
Not recorded yet. The bootstrap's last phase writes the live URLs, the
workspace and the secrets the bot uses into
[ai/context/deployment.md](ai/context/deployment.md); how the bot deploys and
how to operate it is in [ai/context/operations.md](ai/context/operations.md).
<!-- 02-docs:end -->

## Connect Slack

The bot is born **not connected**: it deploys, `/health` answers, and
`/api/events` says (with a 503) that Slack is not connected yet. To connect it:

1. Create a Slack app at [api.slack.com/apps](https://api.slack.com/apps) →
   *Create New App* → *From scratch*, in your workspace.
2. *Basic Information* → *App Credentials*: copy the **Signing Secret**.
3. *App Home*: under *Show Tabs* → *Messages Tab*, allow users to send
   messages from the messages tab.
4. *OAuth & Permissions* → *Bot Token Scopes*: `app_mentions:read`,
   `assistant:write`, `chat:write`, `channels:history` (add `groups:history`
   for private channels and `mpim:history` for group DMs), `im:history`,
   `im:read`, `im:write`. Install the app to the workspace and copy the
   **Bot User OAuth Token** (`xoxb-…`). Scopes added later need a reinstall.
5. Store both as this environment's secrets and redeploy, so the deploy hands
   them to the Worker:

   ```bash
   orun secrets set SLACK_SIGNING_SECRET --org <ws> --env prod
   orun secrets set SLACK_BOT_TOKEN --org <ws> --env prod
   ```

   then Orunbase's **Deploy** on the `api` component (or **Run workflow** on
   the CI workflow, environment `prod`). `/health` now reports Slack
   `connected`.
6. *Event Subscriptions*: enable events and set the **Request URL** to
   `https://ai-slackbot-api-prod.your-workers-subdomain.workers.dev/api/events`
   (Slack sends a signed challenge, which the bot answers). Under *Subscribe
   to bot events* add `app_mention`, `assistant_thread_started` and
   `message.im`, and save.

Mention the bot in a channel, or message it directly. Stage is a second
environment with its own keys: a second Slack app (or the same one pointed at
the stage URL while you test).

## What it can do — and the policy that decides

| Tool | What it does | Needs |
|---|---|---|
| `getWeather` | the current weather for a city (Open-Meteo) | nothing |
| `throwDice` | rolls a six-sided die | nothing |
| `bash`, `readFile`, `writeFile` | a sandboxed bash over an in-memory workspace ([just-bash](https://github.com/vercel-labs/just-bash), via [bash-tool](https://github.com/vercel-labs/bash-tool)) — no host, no network | nothing |
| `searchWeb` | web search with [Exa](https://exa.ai) | `EXA_API_KEY` |

Every call goes through `apps/api/policies/decision.rego` before it runs:
the weather for five cities only, web search on `vercel.com` only, the die in
one channel (set `allowed_dice_channel` to yours), a single allow-listed,
workspace-relative bash command, reads inside the workspace, no writes. A
refusal is relayed to the user verbatim, and every reply ends with a 🔧
footer naming each tool that ran and whether it was blocked. Edit the Rego,
then rebuild the WASM the Worker bundles (needs the
[`opa`](https://www.openpolicyagent.org/docs/latest/#running-opa) CLI):

```bash
pnpm --filter @app/api policy:test    # the policy's own tests (decision_test.rego)
pnpm --filter @app/api policy:build   # → apps/api/policies/policy.wasm
```

`apps/api/policies/README.md` has the input shape and how to add a rule. The
policy gates what a tool *does*, not what the model *says*: see that file's
"Limitations".

## The model

Workers AI's `@cf/moonshotai/kimi-k2.6`, through the `AI` binding — no key,
billed to the Cloudflare account. To use OpenAI instead (the template's
default, `gpt-4o`), store `OPENAI_API_KEY` (and optionally `OPENAI_MODEL`) as
the environment's secrets and redeploy; the bot calls OpenAI directly. To
change the Workers AI model, edit `WORKERS_AI_MODEL` in
`apps/api/src/lib/model.ts` — pick one that calls tools.

## Routes

| Route | Answers |
|---|---|
| `POST /api/events` | Slack's Events API: the signed URL verification, `app_mention`, `assistant_thread_started`, `message.im`. Unsigned, forged or stale requests: `400`. Before Slack is connected: `503` |
| `GET /` | a JSON welcome — the bot's name, its endpoints, whether Slack is connected |
| `GET /health` | `{"status":"ok","name":…,"environment":…,"slack":…,"model":…,"tools":[…]}` — what the deploy's smoke and an operator's probe read; names only, never a key |
| anything else | `404 Not Found` |

## What is here

| Surface | Where |
|---|---|
| The routes (Slack's events, `/`, `/health`) | `apps/api/src/index.ts` |
| Signature check, the Slack client, the thread reader | `apps/api/src/lib/slack-utils.ts` |
| Mentions, assistant threads and DMs | `apps/api/src/lib/handle-app-mention.ts`, `apps/api/src/lib/handle-messages.ts` |
| The agent: system prompt, tools, outcomes | `apps/api/src/lib/run-agent.ts`, `apps/api/src/lib/generate-response.ts` |
| The model | `apps/api/src/lib/model.ts` |
| The policy and its loader | `apps/api/policies/`, `apps/api/src/lib/policy/` |
| The bot's name (what `/` and `/health` answer with) | `apps/api/src/identity.ts` |
| Worker config (name, Workers AI binding, per-environment vars) | `apps/api/wrangler.jsonc` |
| Deploy contract (and the secrets it pushes) | `apps/api/component.yaml` (`cloudflare-worker-turbo`) |
| Tests | `tests/api` (vitest: the routes and Slack's events in-process, the signature check, every policy rule) |

## Getting started

```bash
pnpm install
pnpm typecheck
pnpm lint
pnpm test
pnpm build            # wrangler deploy --dry-run → apps/api/dist (the bundle, no upload)
```

Run it locally under workerd. Workers AI has no local mode, so `wrangler dev`
needs `wrangler login` for the `AI` binding; put Slack's two keys in
`apps/api/.dev.vars` (git-ignored) and expose the port to Slack with a
tunnel (e.g. `npx untun@latest tunnel http://localhost:8787`), whose URL +
`/api/events` is the Request URL while you develop:

```bash
printf 'SLACK_SIGNING_SECRET=…\nSLACK_BOT_TOKEN=xoxb-…\n' > apps/api/.dev.vars
pnpm --filter @app/api dev                 # http://localhost:8787
curl http://localhost:8787/health          # {"status":"ok",…,"environment":"local","slack":"connected",…}
```

Add a tool in `apps/api/src/lib/run-agent.ts` with the AI SDK's `tool()`, and
a rule for it in `decision.rego` — a tool the policy does not name is denied.

## How it deploys

Merges to `main` converge through [Orun](https://github.com/sourceplane/orun):
`.github/workflows/ci.yml` plans the changed components and runs each lane
against the workspace in `intent.yaml`. The bot deploys to `stage`, then to
`prod` once stage has converged on the same commit; `dev` only verifies. The
Worker is `ai-slackbot-api-<env>` on your account's workers.dev subdomain.
After each deploy, the keys the environment has stored — `SLACK_SIGNING_SECRET`,
`SLACK_BOT_TOKEN`, `OPENAI_API_KEY`, `OPENAI_MODEL`, `EXA_API_KEY` — are pushed
to the Worker as Worker secrets (a key nobody stored is skipped, by name), and
every deploy is smoke-tested over HTTP: `/health` must answer `"status":"ok"`
for that environment, and `/api/events` must refuse an unsigned event. A pull
request runs the same pipeline's verify lanes: the Worker built, type-checked
and dry-deployed for each environment, with nothing deployed. They do not
lint or run the tests, so run `pnpm typecheck`, `pnpm lint` and `pnpm test`
before you push. (A push to `main` builds, deploys and smoke-tests.)

The pipeline holds one credential, GitHub's own `GITHUB_TOKEN`. The
Cloudflare token and account id are brokered per run from the workspace's
Cloudflare connection; Slack's keys and any model or search key are the
owner's Orun secrets, never in the repository or in GitHub.

**Deploy by hand.** Orunbase's **Deploy** button on a component, or **Run
workflow** on the CI workflow in GitHub's Actions tab (on `main`), runs
`ci.yml` for the environment and components you pick, and each one deploys
exactly as a merge would deploy it. Leave the component blank to redeploy
every component in that environment, with nothing changed: after storing or
rotating a key, say. A component with nothing to run in that environment (a
test suite in `prod`) is left out with a notice.

**Removing a key.** A deploy pushes the keys that exist and deletes none: to
take one off the Worker, `pnpm exec wrangler secret delete <KEY> --env <env>`
from `apps/api`.

## Limits worth knowing

- **Background time.** The answer runs in `waitUntil` after Slack's
  acknowledgement, which a Worker keeps alive for about 30 seconds after the
  response. A long multi-step answer can be cut off there.
- **Open door, signed.** Anyone who can reach the URL can POST, but only a
  request signed with your app's signing secret, within five minutes, is
  handled; the rest are refused before any work.
- **Not stateful.** The conversation is Slack's thread, re-read each turn
  (`conversations.replies`, the last 50 messages); the bot keeps nothing.

## Custom domain

The bot answers on workers.dev from its first deploy. To serve it on your own
domain, add the domain to the Cloudflare account the bot deploys into and
attach it to the Worker (dashboard → Workers & Pages → `ai-slackbot-api-prod`
→ Settings → Domains & Routes → Add → Custom domain), then point the Slack
app's Request URL at `https://<your domain>/api/events`. The workers.dev URL
keeps answering, and the deploy's smoke keeps reading it — unless the
environment sets `DEPLOYED_URL` in `intent.yaml`, which the smoke reads
instead:

```yaml
environments:
  prod:
    env:
      DEPLOYED_URL: https://ai-slackbot.example.com
```

The repository names the domain in one place, `BASE_DOMAIN` in `intent.yaml`
(one line per environment), which the bot was born with as the reserved
placeholder `ai-slackbot.example.com` — the example above carries it too.
Replace it with your domain in the same change that attaches it.

## Credits

The bot is Vercel's AI SDK Slackbot template
([vercel-labs/ai-sdk-slackbot](https://github.com/vercel-labs/ai-sdk-slackbot),
MIT as its README declares — `apps/api/LICENSE.md`), its policy
(`apps/api/policies/`) included.
