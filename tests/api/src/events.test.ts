import { afterEach, describe, expect, it } from "vitest";
import app from "@/index";
import { API_NAME } from "@/identity";
import { aiStandIn, executionCtx, signed, slackStandIn, SECRET, TOKEN } from "./helpers";

// The router as the Worker runs it (Hono's app.request with the Worker's env
// and an ExecutionContext whose waitUntil is kept and awaited), against an
// in-process Slack Web API and AI binding. The real AI SDK, workers-ai-provider,
// OPA policy and just-bash run; only the network ends are stood in for.

let closeSlack: (() => Promise<void>) | undefined;
afterEach(async () => {
  await closeSlack?.();
  closeSlack = undefined;
});

const mention = (text: string, ts = "1700000000.000001") =>
  JSON.stringify({ type: "event_callback", event: { type: "app_mention", channel: "C123", user: "U1", text: `<@UBOT> ${text}`, ts } });

async function connected(threads: Record<string, unknown[]> = {}) {
  const slack = await slackStandIn(threads);
  closeSlack = slack.close;
  const ai = aiStandIn();
  const env = { AI: ai.AI, ENVIRONMENT: "test", SLACK_SIGNING_SECRET: SECRET, SLACK_BOT_TOKEN: TOKEN, SLACK_API_URL: slack.url };
  return { slack, ai, env };
}

describe("GET /health and GET /", () => {
  it("names the bot and the environment, and what it is connected to — never a value", async () => {
    const { AI } = aiStandIn();
    const res = await app.request("/health", {}, { AI, ENVIRONMENT: "stage" });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({
      status: "ok",
      name: API_NAME,
      environment: "stage",
      slack: "not connected",
      model: { provider: "workers-ai", id: "@cf/moonshotai/kimi-k2.6" },
      tools: ["getWeather", "throwDice", "bash", "readFile", "writeFile"],
    });
  });

  it("reports Slack connected, OpenAI and web search once their keys are stored", async () => {
    const { AI } = aiStandIn();
    const env = { AI, SLACK_SIGNING_SECRET: "s", SLACK_BOT_TOKEN: "t", OPENAI_API_KEY: "sk-test", EXA_API_KEY: "exa-test" };
    const body = (await (await app.request("/health", {}, env)).json()) as Record<string, unknown>;
    expect(body.slack).toBe("connected");
    expect(body.model).toEqual({ provider: "openai", id: "gpt-4o" });
    expect(body.tools).toContain("searchWeb");
    expect(JSON.stringify(body)).not.toMatch(/sk-test|exa-test|"t"|"s"/);
  });

  it("answers / with the bot and where Slack talks to it", async () => {
    const { AI } = aiStandIn();
    const res = await app.request("/", {}, { AI });
    expect(await res.json()).toEqual({
      message: `${API_NAME} — an AI chatbot for Slack`,
      endpoints: { events: "/api/events", health: "/health" },
      slack: "not connected",
    });
  });
});

describe("POST /api/events — before Slack is connected", () => {
  it("says so with a 503 and does no work", async () => {
    const { AI, asked } = aiStandIn();
    const { ctx, pending } = executionCtx();
    const res = await app.request("/api/events", signed(mention("hi")), { AI }, ctx);
    expect(res.status).toBe(503);
    expect(await res.json()).toMatchObject({ ok: false, error: "slack_not_connected" });
    expect(pending).toHaveLength(0);
    expect(asked).toHaveLength(0);
  });
});

describe("POST /api/events — what is refused before any work", () => {
  it("refuses unsigned, forged, stale and wrongly-keyed requests with a 400", async () => {
    const { slack, ai, env } = await connected();
    const challenge = JSON.stringify({ type: "url_verification", challenge: "abc" });
    const cases = [
      { method: "POST", body: challenge, headers: { "content-type": "application/json" } },
      { ...signed(challenge), headers: { ...signed(challenge).headers, "x-slack-signature": "v0=" + "0".repeat(64) } },
      signed(challenge, { ts: Math.floor(Date.now() / 1000) - 600 }),
      signed(challenge, { secret: "another-apps-secret" }),
      signed(mention("hi"), { secret: "another-apps-secret" }),
    ];
    for (const req of cases) {
      const { ctx, pending } = executionCtx();
      const res = await app.request("/api/events", req, env, ctx);
      expect(res.status).toBe(400);
      expect(await res.text()).toBe("Invalid request");
      expect(pending).toHaveLength(0);
    }
    expect(slack.calls).toHaveLength(0);
    expect(ai.asked).toHaveLength(0);
  });

  it("answers Slack's URL verification with its challenge, once signed", async () => {
    const { env } = await connected();
    const res = await app.request("/api/events", signed(JSON.stringify({ type: "url_verification", challenge: "3eZbrw1aBm2rZgRNFdxV2595E9CY3gmdALWMmHkvFXO7tYXAYM8P" })), env);
    expect(res.status).toBe(200);
    expect(await res.text()).toBe("3eZbrw1aBm2rZgRNFdxV2595E9CY3gmdALWMmHkvFXO7tYXAYM8P");
  });

  it("refuses a signed body that is not JSON, and a payload type it does not handle", async () => {
    const { env } = await connected();
    expect((await app.request("/api/events", signed("not json"), env)).status).toBe(400);
    expect((await app.request("/api/events", signed(JSON.stringify({ type: "app_rate_limited" })), env)).status).toBe(400);
  });

  it("acknowledges a retry without answering it twice", async () => {
    const { slack, ai, env } = await connected();
    const { ctx, pending } = executionCtx();
    const res = await app.request("/api/events", signed(mention("hi"), { headers: { "x-slack-retry-num": "1", "x-slack-retry-reason": "http_timeout" } }), env, ctx);
    expect(res.status).toBe(200);
    expect(res.headers.get("x-slack-no-retry")).toBe("1");
    expect(pending).toHaveLength(0);
    expect(slack.calls).toHaveLength(0);
    expect(ai.asked).toHaveLength(0);
  });
});

describe("POST /api/events — answering after the acknowledgement", () => {
  it("acknowledges an app mention at once, then answers it in the thread through the policy-gated agent", async () => {
    const { slack, ai, env } = await connected();
    const { ctx, pending } = executionCtx();
    const res = await app.request("/api/events", signed(mention("please run `ls`")), env, ctx);
    expect(res.status).toBe(200);
    expect(await res.text()).toBe("Success!");
    // Nothing was asked of Slack or the model before the acknowledgement…
    expect(slack.calls).toHaveLength(0);
    expect(pending).toHaveLength(1);
    await Promise.all(pending);
    // …and afterwards: who the bot is, a status message, the answer in its place.
    expect(slack.calls.map((c) => c.method)).toEqual(["auth.test", "chat.postMessage", "chat.update"]);
    expect(slack.calls.every((c) => c.auth === `Bearer ${TOKEN}`)).toBe(true);
    expect(slack.calls[1]?.args).toMatchObject({ channel: "C123", thread_ts: "1700000000.000001", text: "is thinking..." });
    const answer = String(slack.calls[2]?.args.text);
    expect(answer).toContain("README.md");
    expect(answer).toContain("notes.txt");
    expect(answer.endsWith("_🔧 bash_")).toBe(true);
    expect(ai.asked.map((a) => a.roles.join(","))).toEqual(["system,user", "system,user,assistant,tool"]);
    expect(ai.asked[0]?.model).toBe("@cf/moonshotai/kimi-k2.6");
    expect(ai.asked[0]?.tools).not.toContain("searchWeb");
  });

  it("relays a policy refusal verbatim instead of the model's text", async () => {
    const { slack, env } = await connected();
    const { ctx, pending } = executionCtx();
    await app.request("/api/events", signed(mention("please run `rm notes.txt`")), env, ctx);
    await Promise.all(pending);
    const answer = String(slack.calls.at(-1)?.args.text);
    expect(answer).toMatch(/^`rm` is not an allowed command\. Allowed: /);
    expect(answer.endsWith("_🔧 bash (blocked by policy)_")).toBe(true);
  });

  it("answers a direct message in its assistant thread, from the thread's history", async () => {
    const { slack, ai, env } = await connected({
      "1700000000.000500": [
        { user: "U1", text: "first question", ts: "1700000000.000500" },
        { bot_id: "BBOT", text: "first answer", ts: "1700000000.000501" },
        { user: "U1", text: "hello there", ts: "1700000000.000502" },
      ],
    });
    const { ctx, pending } = executionCtx();
    const dm = JSON.stringify({
      type: "event_callback",
      event: { type: "message", channel_type: "im", channel: "D1", user: "U1", text: "hello there", ts: "1700000000.000502", thread_ts: "1700000000.000500" },
    });
    expect((await app.request("/api/events", signed(dm), env, ctx)).status).toBe(200);
    await Promise.all(pending);
    expect(slack.calls.map((c) => c.method)).toEqual(["auth.test", "assistant.threads.setStatus", "conversations.replies", "chat.postMessage", "assistant.threads.setStatus"]);
    expect(slack.calls[3]?.args).toMatchObject({ channel: "D1", thread_ts: "1700000000.000500", text: "Echo: hello there\n\n_🔧 none_" });
    expect(slack.calls[4]?.args.status).toBe("");
    expect(ai.asked[0]?.roles).toEqual(["system", "user", "assistant", "user"]);
  });

  it("greets a new assistant thread with the template's suggested prompts", async () => {
    const { slack, env } = await connected();
    const { ctx, pending } = executionCtx();
    const started = JSON.stringify({ type: "event_callback", event: { type: "assistant_thread_started", assistant_thread: { channel_id: "D1", thread_ts: "1700000000.000900" } } });
    await app.request("/api/events", signed(started), env, ctx);
    await Promise.all(pending);
    expect(slack.calls.map((c) => c.method)).toEqual(["auth.test", "chat.postMessage", "assistant.threads.setSuggestedPrompts"]);
    expect(slack.calls[2]?.args.prompts).toEqual([
      { title: "Get the weather", message: "What is the current weather in London?" },
      { title: "Get the news", message: "What is the latest Premier League news from the BBC?" },
    ]);
  });

  it("ignores the bot's own messages and other bots'", async () => {
    const { slack, ai, env } = await connected();
    const { ctx, pending } = executionCtx();
    const own = JSON.stringify({ type: "event_callback", event: { type: "message", channel_type: "im", channel: "D1", bot_id: "BBOT", text: "x", ts: "1", thread_ts: "1" } });
    await app.request("/api/events", signed(own), env, ctx);
    await Promise.all(pending);
    expect(slack.calls.map((c) => c.method)).toEqual(["auth.test"]);
    expect(ai.asked).toHaveLength(0);
  });
});
