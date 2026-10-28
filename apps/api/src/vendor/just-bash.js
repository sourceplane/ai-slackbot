// What `import … from "just-bash"` resolves to inside the Worker
// (wrangler.jsonc → alias). just-bash ships two builds: a Node one, whose
// python3 and js commands need node:worker_threads and whose decompressors
// load native addons — none of which a Worker can run — and a browser one,
// which is the same in-memory bash without them. The Worker takes the browser
// build. bash-tool imports two more classes from the package root,
// BashTransformPipeline and TeePlugin; the browser build has neither, and
// bash-tool uses them only for its opt-in `experimentalTeeTransform`, which
// this bot never turns on — so they are stubs that refuse, loudly, if it is.
// (The tests run under Node, where the package's Node build is the one used.)
export * from "../../node_modules/just-bash/dist/bundle/browser.js";

class NotInTheBrowserBuild {
  constructor() {
    throw new Error(
      "just-bash's transform plugins are not in its browser build, the one a Worker runs: bash-tool's experimentalTeeTransform is not available here",
    );
  }
}
export class BashTransformPipeline extends NotInTheBrowserBuild {}
export class TeePlugin extends NotInTheBrowserBuild {}
