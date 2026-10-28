import {
  opaPolicy,
  httpPolicyClient,
  wasmPolicyClient,
  type PolicyClient,
} from "@ai-sdk/policy-opa";
// The compiled policy, bundled with the Worker as a WebAssembly.Module:
// wrangler turns a `.wasm` import into a module compiled at upload, which is
// the only way a Worker may run WebAssembly (it refuses to compile bytes at
// runtime). Upstream read the same file from disk with node:fs. Rebuild it
// with `pnpm --filter @app/api policy:build` after editing decision.rego.
import policyWasm from "../../../policies/policy.wasm";

const POLICY_PATH = "agent/call/decision";

const cached = new Map<string, Promise<any>>();

/**
 * The tool-approval function every tool call goes through: the bundled WASM
 * by default, or a running OPA server when POLICY_MODE=http and OPA_URL are
 * set (live policy reloads while iterating, as upstream). One per isolate
 * and mode; a rejected load is not cached, so the next request retries.
 */
export function loadToolApproval(opts: { mode?: string; opaUrl?: string } = {}): Promise<any> {
  const mode = opts.mode === "http" && opts.opaUrl ? "http" : "wasm";
  const key = mode === "http" ? `http:${opts.opaUrl}` : "wasm";
  let p = cached.get(key);
  if (!p) {
    p = build(mode, opts.opaUrl);
    cached.set(key, p);
    p.catch(() => cached.delete(key));
  }
  return p;
}

/** The policy client itself: what every tool call's input is evaluated by. */
export async function policyClient(mode: "wasm" | "http" = "wasm", opaUrl?: string): Promise<PolicyClient> {
  if (mode === "http") return httpPolicyClient({ url: opaUrl as string });
  // Typed as bytes, but handed unchanged to opa-wasm's loadPolicy, which
  // takes a compiled WebAssembly.Module too — the only form a Worker runs.
  return wasmPolicyClient({ wasm: policyWasm as unknown as ArrayBuffer });
}

async function build(mode: "wasm" | "http", opaUrl?: string): Promise<any> {
  const client = await policyClient(mode, opaUrl);
  return opaPolicy({ client, path: POLICY_PATH, toInput });
}

// Shell operators (and newlines) that let one call run a second command. Their
// presence means we can't reason about the call from its first token alone, so
// we flag it and let the policy reject it wholesale.
const SHELL_OPERATORS = /[;&|`\n\r]|\|\||&&|\$\(|[<>]/;
const LEADING_ENV_ASSIGNMENT = /^\s*\w+=/;

// Default OPA input shape (mirrors @ai-sdk/policy-opa's DefaultOpaInput). For
// the bash tool we additionally tokenize the command into { program, argv,
// suspicious } so the Rego allowlist can gate it without parsing strings.
export function toInput(args: {
  toolCall: { toolName: string; input: unknown };
  runtimeContext: unknown;
  messages: unknown;
}) {
  const { toolCall, runtimeContext, messages } = args;
  const base = {
    tool: { name: toolCall.toolName },
    args: toolCall.input,
    messages,
    runtimeContext,
  };

  if (toolCall.toolName !== "bash") return base;

  const command = String((toolCall.input as { command?: unknown })?.command ?? "");
  const suspicious =
    SHELL_OPERATORS.test(command) || LEADING_ENV_ASSIGNMENT.test(command);
  const argv = command.trim().split(/\s+/).filter(Boolean);

  return { ...base, bash: { program: argv[0] ?? "", argv, suspicious } };
}
