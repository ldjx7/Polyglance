/** Secrets managed with `wrangler pages secret put`, not wrangler.toml. */
interface Env {
  OPENROUTER_API_KEY?: string;
  GEMINI_API_KEY?: string;
  GROQ_API_KEY?: string;
  SILICONFLOW_API_KEY?: string;
  POLYGLANCE_STATS?: KVNamespace;
}
