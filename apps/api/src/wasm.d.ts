// A `.wasm` import is a WebAssembly.Module, compiled by wrangler at upload.
declare module "*.wasm" {
  const module: WebAssembly.Module;
  export default module;
}
