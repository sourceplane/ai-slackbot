// What the Worker is given. `AI` is the account's Workers AI (wrangler.jsonc);
// ENVIRONMENT is the `vars` of the environment the deploy targeted. Every
// other key is a Worker SECRET the owner stores after the build (README →
// "Connect Slack"); none is required for the Worker to deploy and answer
// /health, and the bot says what is missing instead of failing.
export type Env = {
  AI: Ai
  ENVIRONMENT?: string
  // Slack: the app's signing secret (verifies every request) and its bot
  // token (posts the replies). Both are needed before /api/events answers.
  SLACK_SIGNING_SECRET?: string
  SLACK_BOT_TOKEN?: string
  // The model: Workers AI by default; upstream's OpenAI when its key is set.
  OPENAI_API_KEY?: string
  OPENAI_MODEL?: string
  // Web search (Exa): the searchWeb tool exists only when this is set.
  EXA_API_KEY?: string
  // The policy backend: the bundled WASM by default; a running OPA server
  // when POLICY_MODE=http and OPA_URL are set.
  POLICY_MODE?: string
  OPA_URL?: string
  // TEST ONLY — where the Slack Web API is. Unset, it is Slack's own
  // (https://slack.com/api/); the e2e points it at a local stand-in.
  SLACK_API_URL?: string
}

/** Slack is connected when both of its keys are present. */
export const slackConnected = (env: Env) => Boolean(env.SLACK_SIGNING_SECRET && env.SLACK_BOT_TOKEN)
