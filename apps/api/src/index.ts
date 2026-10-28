import { Hono } from 'hono'
import type { SlackEvent } from '@slack/web-api'
import { API_NAME } from './identity'
import { slackConnected, type Env } from './env'
import { botContext } from './lib/bot'
import { handleNewAppMention } from './lib/handle-app-mention'
import { assistantThreadMessage, handleNewAssistantMessage } from './lib/handle-messages'
import { modelFor } from './lib/model'
import { toolNames } from './lib/run-agent'
import { getBotId, isValidSlackRequest } from './lib/slack-utils'

const app = new Hono<{ Bindings: Env }>()

const NOT_CONNECTED = {
  ok: false,
  error: 'slack_not_connected',
  message:
    'Slack is not connected yet: store SLACK_SIGNING_SECRET and SLACK_BOT_TOKEN as this environment’s secrets and redeploy (README → Connect Slack).',
}

// Slack's Events API: every event the app subscribes to (app_mention,
// assistant_thread_started, message.im) is POSTed here. Upstream's
// api/events.ts, as a Hono route at the same path.
app.post('/api/events', async (c) => {
  // Before Slack is connected there is nothing to verify a request against
  // and nothing to answer with: say so, and do no work.
  if (!slackConnected(c.env)) return c.json(NOT_CONNECTED, 503)

  // VERIFIED FIRST — every request Slack sends is signed, the URL
  // verification included, and nothing is parsed, looked up or answered
  // before its signature and timestamp check out. (Upstream answered the
  // challenge before verifying, and dropped the result of the check, so a
  // forged event was handled as a real one.)
  const rawBody = await c.req.text()
  const valid = await isValidSlackRequest({
    signingSecret: c.env.SLACK_SIGNING_SECRET as string,
    timestamp: c.req.header('X-Slack-Request-Timestamp') ?? null,
    signature: c.req.header('X-Slack-Signature') ?? null,
    rawBody,
  })
  if (!valid) return c.text('Invalid request', 400)

  let payload: { type?: string; challenge?: string; event?: SlackEvent }
  try {
    payload = JSON.parse(rawBody)
  } catch {
    return c.text('Invalid request', 400)
  }

  // See https://api.slack.com/events/url_verification
  if (payload.type === 'url_verification') {
    return c.text(String(payload.challenge ?? ''), 200)
  }
  if (payload.type !== 'event_callback' || !payload.event) {
    return c.text('Invalid request', 400)
  }

  // A RETRY IS NOT A NEW EVENT. Slack re-sends an event it did not see
  // acknowledged within 3 s; this route acknowledges at once and answers in
  // the background, so a retry is the same event again — acknowledged, not
  // answered twice.
  if (c.req.header('X-Slack-Retry-Num')) {
    c.header('X-Slack-No-Retry', '1')
    return c.text('Success!', 200)
  }

  // Acknowledge now; answer after. The bot's own user id (auth.test), the
  // thread, the model and the reply all run in waitUntil — upstream looked
  // the bot up before acknowledging, which spent Slack's 3 s on a round trip.
  const event = payload.event
  const bot = botContext(c.env)
  c.executionCtx.waitUntil(
    (async () => {
      try {
        const botUserId = await getBotId(bot.slack)

        if (event.type === 'app_mention') {
          await handleNewAppMention(bot, event, botUserId)
        }

        if (event.type === 'assistant_thread_started') {
          await assistantThreadMessage(bot, event)
        }

        if (
          event.type === 'message' &&
          !event.subtype &&
          event.channel_type === 'im' &&
          !event.bot_id &&
          !event.bot_profile &&
          event.bot_id !== botUserId
        ) {
          await handleNewAssistantMessage(bot, event, botUserId)
        }
      } catch (error) {
        console.error('Error generating response', error)
      }
    })(),
  )

  return c.text('Success!', 200)
})

// What the bot is and where Slack talks to it. Upstream redirected / to its
// own GitHub repository; a product's root describes the product instead.
app.get('/', (c) => {
  return c.json({
    message: `${API_NAME} — an AI chatbot for Slack`,
    endpoints: {
      events: '/api/events',
      health: '/health',
    },
    slack: slackConnected(c.env) ? 'connected' : 'not connected',
  })
})

// The operational contract: what the deploy's smoke and the bootstrap's probe
// read. It names the bot and the environment whose config the Worker runs, so
// a 200 here is this bot, deployed to that environment — not any page that
// happens to answer — and says what it is connected to, by NAME, never a
// value: Slack or not, which model, which tools.
app.get('/health', (c) => {
  const env = c.env
  const model = modelFor(env)
  return c.json({
    status: 'ok',
    name: API_NAME,
    environment: env?.ENVIRONMENT ?? 'unknown',
    slack: slackConnected(env) ? 'connected' : 'not connected',
    model: { provider: model.provider, id: model.id },
    tools: toolNames({ search: Boolean(env?.EXA_API_KEY) }),
  })
})

export default app
