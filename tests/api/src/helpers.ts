import { createHmac } from "node:crypto";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";

export const SECRET = "test-signing-secret";
export const TOKEN = "xoxb-test-token";

/** A signed Slack request for `body`, as Slack signs it (v0:ts:body). */
export function signed(body: string, opts: { secret?: string; ts?: number; headers?: Record<string, string> } = {}) {
  const ts = String(opts.ts ?? Math.floor(Date.now() / 1000));
  const sig = "v0=" + createHmac("sha256", opts.secret ?? SECRET).update(`v0:${ts}:${body}`).digest("hex");
  return {
    method: "POST",
    headers: { "content-type": "application/json", "x-slack-request-timestamp": ts, "x-slack-signature": sig, ...(opts.headers ?? {}) },
    body,
  };
}

/** What a Worker's ExecutionContext is to a route: a waitUntil that is kept. */
export function executionCtx() {
  const pending: Promise<unknown>[] = [];
  return {
    pending,
    ctx: {
      waitUntil: (p: Promise<unknown>) => void pending.push(p),
      passThroughOnException: () => {},
      props: {},
    } as unknown as ExecutionContext,
  };
}

export type SlackCall = { method: string; args: Record<string, unknown>; auth: string };

/** The slice of Slack's Web API the bot calls, in process, recording every call and its token. */
export async function slackStandIn(threads: Record<string, unknown[]> = {}) {
  const calls: SlackCall[] = [];
  let ts = 1700000000;
  const server: Server = createServer((req, res) => {
    let raw = "";
    req.on("data", (c) => (raw += c));
    req.on("end", () => {
      const method = (req.url ?? "").replace(/^\/api\//, "").split("?")[0] ?? "";
      const form = new URLSearchParams(raw);
      const args: Record<string, unknown> = {};
      for (const [k, v] of form) {
        try {
          args[k] = v.startsWith("[") || v.startsWith("{") ? JSON.parse(v) : v;
        } catch {
          args[k] = v;
        }
      }
      calls.push({ method, args, auth: String(req.headers.authorization ?? "") });
      const reply = (body: unknown) => {
        res.setHeader("content-type", "application/json");
        res.end(JSON.stringify(body));
      };
      if (req.headers.authorization !== `Bearer ${TOKEN}`) return reply({ ok: false, error: "invalid_auth" });
      if (method === "auth.test") return reply({ ok: true, user_id: "UBOT" });
      if (method === "chat.postMessage" || method === "chat.update") return reply({ ok: true, ts: args.ts ?? `${++ts}.000100` });
      if (method === "conversations.replies") return reply({ ok: true, messages: threads[String(args.ts)] ?? [] });
      return reply({ ok: true });
    });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const { port } = server.address() as AddressInfo;
  return { url: `http://127.0.0.1:${port}/api/`, calls, close: () => new Promise<void>((r) => server.close(() => r())) };
}

const text = (c: unknown) => (typeof c === "string" ? c : Array.isArray(c) ? c.map((p) => (p as { text?: string })?.text ?? "").join("") : "");

/**
 * The Worker's AI binding, in process: workers-ai-provider calls
 * `AI.run(model, inputs)`. It answers deterministically, with no network:
 * a tool result is quoted, `run \`<cmd>\`` becomes a bash call, anything
 * else is echoed — and records what it was asked.
 */
export function aiStandIn() {
  const asked: { model: string; tools: string[]; roles: string[] }[] = [];
  const AI = {
    async run(model: string, inputs: { messages?: { role: string; content: unknown }[]; tools?: { function?: { name?: string } }[] }) {
      const messages = inputs.messages ?? [];
      const tools = (inputs.tools ?? []).map((t) => t.function?.name ?? "").filter(Boolean);
      asked.push({ model, tools, roles: messages.map((m) => m.role) });
      const last = messages[messages.length - 1];
      const lastUser = [...messages].reverse().find((m) => m.role === "user");
      if (last?.role === "tool") return { choices: [{ message: { role: "assistant", content: `Tool said: ${text(last.content)}` }, finish_reason: "stop" }] };
      const ask = /run `([^`]+)`/.exec(text(lastUser?.content));
      if (ask && tools.includes("bash")) {
        return {
          choices: [
            {
              message: { role: "assistant", content: "", tool_calls: [{ id: `call_${messages.length}`, type: "function", function: { name: "bash", arguments: JSON.stringify({ command: ask[1] }) } }] },
              finish_reason: "tool_calls",
            },
          ],
        };
      }
      return { choices: [{ message: { role: "assistant", content: `Echo: ${text(lastUser?.content)}` }, finish_reason: "stop" }] };
    },
  };
  return { AI: AI as unknown as Ai, asked };
}
