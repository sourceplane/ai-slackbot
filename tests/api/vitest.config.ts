import { defineConfig, type Plugin } from "vitest/config";
import * as path from "node:path";
import { readFileSync } from "node:fs";

// The Worker imports its compiled policy as a WebAssembly.Module (wrangler
// compiles a `.wasm` import at upload). Under Node the same import becomes the
// same module, compiled from the same file, so the tests run the policy the
// Worker ships — not a copy of its rules.
const wasmModule = (): Plugin => ({
  name: "wasm-module",
  enforce: "pre",
  load(id) {
    if (!id.endsWith(".wasm")) return null;
    const b64 = readFileSync(id).toString("base64");
    return `export default new WebAssembly.Module(Buffer.from(${JSON.stringify(b64)}, "base64"));`;
  },
});

export default defineConfig({
  plugins: [wasmModule()],
  resolve: {
    alias: {
      "@": path.resolve(__dirname, "../../apps/api/src"),
    },
  },
  test: {
    include: ["src/**/*.test.ts"],
    environment: "node",
    testTimeout: 30_000,
  },
});
