/** Secrets managed with `wrangler pages secret put`, not wrangler.toml. */
interface Env {
  OPENROUTER_API_KEY?: string;
  OPENROUTER_MODEL?: string;
  OPENROUTER_PREFERRED_MODEL?: string;
  OPENROUTER_BASE_URL?: string;

  GEMINI_API_KEY?: string;
  GEMINI_MODEL?: string;
  GEMINI_PREFERRED_MODEL?: string;
  GEMINI_BASE_URL?: string;

  GROQ_API_KEY?: string;
  GROQ_MODEL?: string;
  GROQ_PREFERRED_MODEL?: string;
  GROQ_BASE_URL?: string;

  SILICONFLOW_API_KEY?: string;
  SILICONFLOW_MODEL?: string;
  SILICONFLOW_PREFERRED_MODEL?: string;
  SILICONFLOW_BASE_URL?: string;

  POLYGLANCE_STATS?: KVNamespace;
}
