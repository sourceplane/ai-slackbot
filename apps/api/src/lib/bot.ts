import type { LanguageModel } from "ai";
import type { Env } from "../env";
import { modelFor } from "./model";
import { slackClient, type Slack } from "./slack-utils";
import type { SearchWeb } from "./run-agent";
import { exaSearch } from "./utils";

// Everything one Slack event is answered with, built from the Worker's own
// secrets for that request: upstream read process.env at import and kept one
// client per process; a Worker's environment arrives with the request.
export interface BotContext {
  slack: Slack;
  model: LanguageModel;
  searchWeb?: SearchWeb;
  policy: { mode?: string; opaUrl?: string };
}

export function botContext(env: Env): BotContext {
  return {
    slack: slackClient(env.SLACK_BOT_TOKEN as string, env.SLACK_API_URL),
    model: modelFor(env).model,
    searchWeb: exaSearch(env.EXA_API_KEY),
    policy: { mode: env.POLICY_MODE, opaUrl: env.OPA_URL },
  };
}
