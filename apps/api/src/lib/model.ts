import { createOpenAI } from '@ai-sdk/openai'
import type { LanguageModel } from 'ai'
import { createWorkersAI } from 'workers-ai-provider'
import type { Env } from '../env'

// THE MODEL THE BOT USES. Upstream defaulted to OpenAI (`gpt-4o`), which
// needs a key nobody brokers, or a local Ollama, which a Worker cannot reach
// (it serves on localhost). Here the default is Workers AI through the
// Worker's own `AI` binding — no key, so a fresh deployment answers with
// nothing configured — with a model that calls tools. Upstream's OpenAI is
// used, direct (never through an AI gateway), once OPENAI_API_KEY is stored
// as a Worker secret; OPENAI_MODEL picks its model, as upstream.
export const WORKERS_AI_MODEL = '@cf/moonshotai/kimi-k2.6'
export const OPENAI_DEFAULT_MODEL = 'gpt-4o'

export type ModelChoice = {
  model: LanguageModel
  provider: 'workers-ai' | 'openai'
  id: string
}

export function modelFor(env: Env): ModelChoice {
  if (env.OPENAI_API_KEY) {
    const id = env.OPENAI_MODEL || OPENAI_DEFAULT_MODEL
    return { model: createOpenAI({ apiKey: env.OPENAI_API_KEY })(id), provider: 'openai', id }
  }
  return {
    model: createWorkersAI({ binding: env.AI })(WORKERS_AI_MODEL),
    provider: 'workers-ai',
    id: WORKERS_AI_MODEL,
  }
}
