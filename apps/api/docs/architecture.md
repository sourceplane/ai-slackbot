# api — architecture

Built by the turbo pipeline from `apps/api` and deployed with wrangler.

|                     |                           |
| ------------------- | ------------------------- |
| Worker config       | `apps/api/wrangler.jsonc` |
| Entry               | `src/index.ts`            |
| Compatibility date  | `2026-10-01`              |
| Compatibility flags | `nodejs_compat`           |

## Bindings

| Binding | Kind       | Source                                  |
| ------- | ---------- | --------------------------------------- |
| `AI`    | Workers AI | account-level; no resource to provision |

## Variables

`ENVIRONMENT` — overridden per environment (`dev`, `prod`, `stage`).

## Secrets resolved by the lane (names only)

- `EXA_API_KEY` (optional)
- `OPENAI_API_KEY` (optional)
- `OPENAI_MODEL` (optional)
- `SLACK_BOT_TOKEN` (optional)
- `SLACK_SIGNING_SECRET` (optional)
