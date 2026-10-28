import type {
  AssistantThreadStartedEvent,
  GenericMessageEvent,
} from "@slack/web-api";
import { getThread, updateStatusUtil } from "./slack-utils";
import { generateResponse } from "./generate-response";
import { runtimeContextFromEvent } from "./policy/runtime-context";
import type { BotContext } from "./bot";

export async function assistantThreadMessage(
  bot: BotContext,
  event: AssistantThreadStartedEvent,
) {
  const { channel_id, thread_ts } = event.assistant_thread;
  console.log(`Thread started: ${channel_id} ${thread_ts}`);

  await bot.slack.chat.postMessage({
    channel: channel_id,
    thread_ts: thread_ts,
    text: "Hello, I'm an AI assistant built with the AI SDK by Vercel!",
  });

  await bot.slack.assistant.threads.setSuggestedPrompts({
    channel_id: channel_id,
    thread_ts: thread_ts,
    prompts: [
      {
        title: "Get the weather",
        message: "What is the current weather in London?",
      },
      {
        title: "Get the news",
        message: "What is the latest Premier League news from the BBC?",
      },
    ],
  });
}

export async function handleNewAssistantMessage(
  bot: BotContext,
  event: GenericMessageEvent,
  botUserId: string,
) {
  if (
    event.bot_id ||
    event.bot_id === botUserId ||
    event.bot_profile ||
    !event.thread_ts
  )
    return;

  const { thread_ts, channel } = event;
  const updateStatus = updateStatusUtil(bot.slack, channel, thread_ts);
  const runtimeContext = runtimeContextFromEvent({ channel, user: event.user });
  await updateStatus("is thinking...");
  try {
    const messages = await getThread(bot.slack, channel, thread_ts, botUserId);
    const result = await generateResponse(bot, messages, runtimeContext, updateStatus);

    await bot.slack.chat.postMessage({
      channel: channel,
      thread_ts: thread_ts,
      text: result,
      unfurl_links: false,
      blocks: [
        {
          type: "section",
          text: {
            type: "mrkdwn",
            text: result,
          },
        },
      ],
    });
  } catch (error) {
    console.error("Error handling assistant message", error);
    await bot.slack.chat.postMessage({
      channel,
      thread_ts,
      text: "⚠️ Something went wrong handling that — check the bot logs (a missing Slack scope is the usual cause).",
    });
  } finally {
    // Always clear the "is thinking..." status, even on failure.
    await updateStatus("");
  }
}
