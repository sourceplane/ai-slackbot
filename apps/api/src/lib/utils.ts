import type { SearchWeb } from "./run-agent";

// Exa's web search, built only when its key is stored (EXA_API_KEY). Upstream
// constructed the client at import from process.env; a Worker's secrets are
// the request's, so it is built per request, and exa-js is imported then.
export function exaSearch(apiKey: string | undefined): SearchWeb | undefined {
  if (!apiKey) return undefined;
  return async (query, specificDomain) => {
    const { default: Exa } = await import("exa-js");
    const exa = new Exa(apiKey);
    const { results } = await exa.searchAndContents(query, {
      livecrawl: "always",
      numResults: 3,
      includeDomains: specificDomain ? [specificDomain] : undefined,
    });
    return results.map((result) => ({
      title: result.title,
      url: result.url,
      snippet: result.text.slice(0, 1000),
    }));
  };
}
