# api

The AI SDK Slackbot — Slack's Events API at /api/events on a plain Cloudflare Worker, answering with Workers AI and policy-gated tools (per environment)

A Cloudflare Worker, deployed per environment by its CI lane.

|              |                                                                                                                    |
| ------------ | ------------------------------------------------------------------------------------------------------------------ |
| Type         | `cloudflare-worker-turbo`                                                                                          |
| Source       | `apps/api`                                                                                                         |
| Package      | `@app/api`                                                                                                         |
| Environments | `dev`: `verify` · `stage`: `verify`, `deploy` on a push to `main` · `prod`: `verify`, `deploy` on a push to `main` |

## Depends on

- (none)

## Depended on by

- (none)
