// A DETERMINISTIC STAND-IN FOR WORKERS AI, for testing/e2e.test.sh only.
//
// The bot's model is Workers AI through the Worker's `AI` binding
// (apps/api/src/lib/model.ts, via workers-ai-provider): `env.AI.run(model,
// inputs)`. Workers AI has no local mode, so under `wrangler dev` the e2e binds
// `AI` to THIS Worker instead — a service binding to its `FakeAI` entrypoint,
// an RPC method with the binding's own shape — and the bot's code (the real AI
// SDK, the real provider, the real OPA policy) cannot tell the difference.
//
// It answers in the OpenAI-compatible chat shape the provider reads:
//   - the last message is a tool result     → text that quotes it
//   - the user wrote  run `<command>`       → a `bash` tool call with it
//   - anything else                          → "Echo: <the user's text>"
// so the e2e can drive the agent loop through a tool the policy allows
// (`ls`), one it refuses (`rm`), and a plain answer, with no network. Each call
// is logged as one `fake-workers-ai {…}` line the e2e reads back.
import { WorkerEntrypoint } from "cloudflare:workers";

const text = (content) =>
  typeof content === "string"
    ? content
    : Array.isArray(content)
      ? content.map((p) => (typeof p === "string" ? p : (p?.text ?? ""))).join("")
      : "";

export class FakeAI extends WorkerEntrypoint {
  async run(model, inputs) {
    const messages = Array.isArray(inputs?.messages) ? inputs.messages : [];
    const tools = Array.isArray(inputs?.tools) ? inputs.tools.map((t) => t?.function?.name ?? t?.name).filter(Boolean) : [];
    const last = messages[messages.length - 1] ?? {};
    const lastUser = [...messages].reverse().find((m) => m.role === "user");
    let choice;
    if (last.role === "tool") {
      choice = { message: { role: "assistant", content: `Tool said: ${text(last.content)}` }, finish_reason: "stop" };
    } else {
      const ask = /run `([^`]+)`/.exec(text(lastUser?.content));
      if (ask && tools.includes("bash")) {
        choice = {
          message: {
            role: "assistant",
            content: "",
            tool_calls: [{ id: `call_${messages.length}`, type: "function", function: { name: "bash", arguments: JSON.stringify({ command: ask[1] }) } }],
          },
          finish_reason: "tool_calls",
        };
      } else {
        choice = { message: { role: "assistant", content: `Echo: ${text(lastUser?.content)}` }, finish_reason: "stop" };
      }
    }
    console.log(`fake-workers-ai ${JSON.stringify({ model, tools, roles: messages.map((m) => m.role), reply: choice.finish_reason })}`);
    return { choices: [choice], usage: { prompt_tokens: 7, completion_tokens: 5, total_tokens: 12 } };
  }
}

export default {
  fetch() {
    return new Response("fake-workers-ai: reached only through the bot's AI service binding\n");
  },
};
