import { WebClient } from '@slack/web-api'
import type { ModelMessage } from 'ai'

// One WebClient per request, from the Worker's own secrets: a Worker's
// environment is the request's, so nothing is read at module load (upstream
// built one client from process.env at import). `slackApiUrl` is Slack's own
// unless the e2e points SLACK_API_URL at its stand-in.
export function slackClient(token: string, apiUrl?: string) {
  return new WebClient(token, apiUrl ? { slackApiUrl: apiUrl } : {})
}

export type Slack = WebClient

const encoder = new TextEncoder()

function hex(bytes: ArrayBuffer) {
  return [...new Uint8Array(bytes)].map((b) => b.toString(16).padStart(2, '0')).join('')
}

// Constant-time over the two strings' bytes: the length is not a secret (a
// v0= signature is always 67 characters), the content is.
function timingSafeEqual(a: string, b: string) {
  const x = encoder.encode(a)
  const y = encoder.encode(b)
  if (x.length !== y.length) return false
  let diff = 0
  for (let i = 0; i < x.length; i++) diff |= x[i]! ^ y[i]!
  return diff === 0
}

// See https://api.slack.com/authentication/verifying-requests-from-slack —
// HMAC-SHA256 over `v0:<timestamp>:<raw body>` with the app's signing secret,
// with WebCrypto (upstream's node:crypto), refused when the timestamp is more
// than five minutes from now. `now` is a parameter so the tests can pin it.
export async function isValidSlackRequest({
  signingSecret,
  timestamp,
  signature,
  rawBody,
  now = Date.now(),
}: {
  signingSecret: string
  timestamp: string | null
  signature: string | null
  rawBody: string
  now?: number
}): Promise<boolean> {
  if (!timestamp || !signature) return false
  if (!/^\d+$/.test(timestamp)) return false
  // Prevent replay attacks on the order of 5 minutes
  if (Math.abs(now / 1000 - Number(timestamp)) > 60 * 5) return false

  const key = await crypto.subtle.importKey(
    'raw',
    encoder.encode(signingSecret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  )
  const mac = await crypto.subtle.sign('HMAC', key, encoder.encode(`v0:${timestamp}:${rawBody}`))
  return timingSafeEqual(`v0=${hex(mac)}`, signature)
}

export const updateStatusUtil = (slack: Slack, channel: string, thread_ts: string) => {
  return async (status: string) => {
    await slack.assistant.threads.setStatus({
      channel_id: channel,
      thread_ts: thread_ts,
      status: status,
    })
  }
}

export async function getThread(
  slack: Slack,
  channel_id: string,
  thread_ts: string,
  botUserId: string,
): Promise<ModelMessage[]> {
  const { messages } = await slack.conversations.replies({
    channel: channel_id,
    ts: thread_ts,
    limit: 50,
  })

  // Ensure we have messages

  if (!messages) throw new Error('No messages found in thread')

  const result = messages
    .map((message) => {
      const isBot = !!message.bot_id
      if (!message.text) return null

      // For app mentions, remove the mention prefix
      // For IM messages, keep the full text
      let content = message.text
      if (!isBot && content.includes(`<@${botUserId}>`)) {
        content = content.replace(`<@${botUserId}> `, '')
      }

      return {
        role: isBot ? 'assistant' : 'user',
        content: content,
      } as ModelMessage
    })
    .filter((msg): msg is ModelMessage => msg !== null)

  return result
}

export const getBotId = async (slack: Slack) => {
  const { user_id: botUserId } = await slack.auth.test()

  if (!botUserId) {
    throw new Error('botUserId is undefined')
  }
  return botUserId
}
