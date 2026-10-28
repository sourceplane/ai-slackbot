import { createHmac } from "node:crypto";
import { describe, expect, it } from "vitest";
import { isValidSlackRequest } from "@/lib/slack-utils";

// Slack's request signing (https://api.slack.com/authentication/verifying-requests-from-slack),
// checked with WebCrypto in the Worker. The expected signature is computed
// here with Node's own HMAC, so the two implementations are held to each other.
const secret = "8f742231b10e8888abcd99yyyzzz85a5";
const body = "token=xyzz0WbapA4vBCDEFasx0q6G&team_id=T1DC2JH3J&command=%2Fweather";
const now = 1531420618 * 1000;
const sign = (ts: string, b = body, s = secret) => "v0=" + createHmac("sha256", s).update(`v0:${ts}:${b}`).digest("hex");

describe("isValidSlackRequest (apps/api/src/lib/slack-utils.ts)", () => {
  it("accepts Slack's own signature", async () => {
    const ts = "1531420618";
    expect(await isValidSlackRequest({ signingSecret: secret, timestamp: ts, signature: sign(ts), rawBody: body, now })).toBe(true);
  });

  it("refuses a signature made with another secret, or over another body", async () => {
    const ts = "1531420618";
    expect(await isValidSlackRequest({ signingSecret: secret, timestamp: ts, signature: sign(ts, body, "other"), rawBody: body, now })).toBe(false);
    expect(await isValidSlackRequest({ signingSecret: secret, timestamp: ts, signature: sign(ts), rawBody: body + "&x=1", now })).toBe(false);
  });

  it("refuses a timestamp more than five minutes from now, either way", async () => {
    for (const offset of [-301, 301]) {
      const ts = String(1531420618 + offset);
      expect(await isValidSlackRequest({ signingSecret: secret, timestamp: ts, signature: sign(ts), rawBody: body, now })).toBe(false);
    }
    const edge = String(1531420618 - 300);
    expect(await isValidSlackRequest({ signingSecret: secret, timestamp: edge, signature: sign(edge), rawBody: body, now })).toBe(true);
  });

  it("refuses a missing header, a non-numeric timestamp and a truncated signature", async () => {
    const ts = "1531420618";
    expect(await isValidSlackRequest({ signingSecret: secret, timestamp: null, signature: sign(ts), rawBody: body, now })).toBe(false);
    expect(await isValidSlackRequest({ signingSecret: secret, timestamp: ts, signature: null, rawBody: body, now })).toBe(false);
    expect(await isValidSlackRequest({ signingSecret: secret, timestamp: "1531420618.5", signature: sign("1531420618.5"), rawBody: body, now })).toBe(false);
    expect(await isValidSlackRequest({ signingSecret: secret, timestamp: ts, signature: sign(ts).slice(0, -1), rawBody: body, now })).toBe(false);
  });
});
