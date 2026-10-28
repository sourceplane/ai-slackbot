import { describe, expect, it } from "vitest";
import { policyClient, toInput } from "@/lib/policy/load";

// The compiled policy the Worker ships (apps/api/policies/policy.wasm, built
// from decision.rego), evaluated on the input the bot hands it (toInput) —
// every rule of the template's policy, allow and deny.
const client = await policyClient();
const decide = async (toolName: string, input: unknown, channelId = "C0OTHER") =>
  (await client.evaluate("agent/call/decision", toInput({ toolCall: { toolName, input }, runtimeContext: { channelId, userId: "U1" }, messages: [] }))) as {
    decision: string;
    reason?: string;
  };

describe("the tool-call policy (apps/api/policies/decision.rego → policy.wasm)", () => {
  it("allows the weather for an allowed city only", async () => {
    expect((await decide("getWeather", { city: " London " })).decision).toBe("allow");
    const paris = await decide("getWeather", { city: "Paris" });
    expect(paris.decision).toBe("deny");
    expect(paris.reason).toContain("Paris");
  });

  it("allows a web search on vercel.com only", async () => {
    expect((await decide("searchWeb", { query: "x", specificDomain: "vercel.com" })).decision).toBe("allow");
    expect((await decide("searchWeb", { query: "x", specificDomain: "bbc.com" })).reason).toBe("I can only search vercel.com per policy.");
    expect((await decide("searchWeb", { query: "x", specificDomain: null })).decision).toBe("deny");
  });

  it("allows the dice in the designated channel only", async () => {
    expect((await decide("throwDice", {}, "C0B6YBUHMME")).decision).toBe("allow");
    expect((await decide("throwDice", {})).decision).toBe("deny");
  });

  it("allows one simple, allow-listed, workspace-relative bash command", async () => {
    expect((await decide("bash", { command: "ls" })).decision).toBe("allow");
    expect((await decide("bash", { command: "cat notes.txt" })).decision).toBe("allow");
    expect((await decide("bash", { command: "rm notes.txt" })).reason).toMatch(/^`rm` is not an allowed command/);
    for (const command of ["ls; rm notes.txt", "ls | wc", "echo $(id)", "X=1 ls", "ls > out"]) {
      expect((await decide("bash", { command })).reason, command).toMatch(/^Only a single, simple command/);
    }
    expect((await decide("bash", { command: "cat /etc/passwd" })).reason).toMatch(/relative paths within the workspace/);
    expect((await decide("bash", { command: "cat ../x" })).decision).toBe("deny");
  });

  it("refuses every write, and reads outside the workspace", async () => {
    expect((await decide("writeFile", { path: "a.txt", content: "x" })).decision).toBe("deny");
    expect((await decide("readFile", { path: "notes.txt" })).decision).toBe("allow");
    expect((await decide("readFile", { path: "/etc/passwd" })).decision).toBe("deny");
    expect((await decide("readFile", { path: "../secret" })).decision).toBe("deny");
  });

  it("denies a tool the policy does not name", async () => {
    expect(await decide("deleteEverything", {})).toEqual({ decision: "deny", reason: "This tool is not permitted by policy." });
  });
});
