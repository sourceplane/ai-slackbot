import { describe, expect, it } from "vitest";
import { formatReply } from "@/lib/generate-response";
import { modelFor, OPENAI_DEFAULT_MODEL, WORKERS_AI_MODEL } from "@/lib/model";
import { systemPrompt, toolNames } from "@/lib/run-agent";

describe("formatReply (apps/api/src/lib/generate-response.ts)", () => {
  it("always ends with the tools footer, and converts markdown to Slack mrkdwn", () => {
    expect(formatReply("**Hi** see [docs](https://vercel.com/docs)", [])).toBe("*Hi* see <https://vercel.com/docs|docs>\n\n_🔧 none_");
    expect(formatReply("ok", [{ toolName: "getWeather", status: "used" }, { toolName: "getWeather", status: "used" }])).toBe("ok\n\n_🔧 getWeather_");
  });

  it("shows only the reasons when nothing ran, never the model's text", () => {
    expect(formatReply("London is sunny", [{ toolName: "getWeather", status: "denied", reason: "Not allowed." }])).toBe(
      "Not allowed.\n\n_🔧 getWeather (blocked by policy)_",
    );
  });

  it("keeps the answer and appends a refusal when another tool succeeded", () => {
    expect(
      formatReply("Rolled a 4.", [
        { toolName: "throwDice", status: "used" },
        { toolName: "bash", status: "failed", reason: "boom" },
      ]),
    ).toBe("Rolled a 4.\n\nboom\n\n_🔧 throwDice, bash (failed)_");
  });
});

describe("the model and the tools", () => {
  const AI = {} as Ai;
  it("is Workers AI with no key, and upstream's OpenAI once its key is stored", () => {
    expect(modelFor({ AI })).toMatchObject({ provider: "workers-ai", id: WORKERS_AI_MODEL });
    expect(modelFor({ AI, OPENAI_API_KEY: "sk-x" })).toMatchObject({ provider: "openai", id: OPENAI_DEFAULT_MODEL });
    expect(modelFor({ AI, OPENAI_API_KEY: "sk-x", OPENAI_MODEL: "gpt-4.1-mini" })).toMatchObject({ provider: "openai", id: "gpt-4.1-mini" });
  });

  it("offers web search, and names it in the prompt, only with Exa's key", () => {
    expect(toolNames({ search: false })).not.toContain("searchWeb");
    expect(toolNames({ search: true })).toContain("searchWeb");
    expect(systemPrompt({ search: false, today: "2026-10-28" })).not.toContain("searchWeb");
    const withSearch = systemPrompt({ search: true, today: "2026-10-28" });
    expect(withSearch).toContain("searchWeb");
    expect(withSearch).toContain("Current date is: 2026-10-28");
  });
});
