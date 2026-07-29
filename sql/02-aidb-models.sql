-- Runs once, on first cluster initialization only.
--
-- Registers 'my_embedder' and 'my_summarizer', both OpenRouter-backed --
-- no local model inference runs in this container at all. Originally both
-- ran on aidb's built-in local models (bert_local / TinyLlama), but that
-- was dropped for two reasons: TinyLlama proved unreliable at strict
-- instruction-following (returning prose/markdown instead of raw SQL or
-- DDL for demos 2 and 4, even when explicitly told not to), and running
-- local inference at all was consuming too much of the host Mac's CPU/RAM
-- alongside everything else running on it. Both models now make a live
-- API call to OpenRouter on every use -- no weight downloads, no local
-- inference, minimal resource footprint on the host.
--
-- Requires a real OPENROUTER_API_KEY in .env (get one at
-- https://openrouter.ai/keys). bring-up.sh reads it from ~/.openrouter_key,
-- the same pattern used for the EDB registry token.

\c mydb

-- Embedding model choice: openai/text-embedding-3-small -- solid quality,
-- cheap, widely supported. 1536-dim by default; the pgvector column this
-- feeds is sized from whatever this model actually returns, so this is
-- safe to change as long as you re-ingest afterward (a dimension change
-- isn't compatible with previously-stored vectors).
SELECT aidb.create_model(
    'my_embedder',
    'openrouter_embeddings',
    aidb.openrouter_embeddings_config(
        model   => 'openai/text-embedding-3-small',
        api_key => :'openrouter_api_key'
    ),
    '{}'::JSONB
);

-- Text-generation model choice: openai/gpt-4o-mini -- NOT gpt-5-mini.
-- gpt-5-mini (and other reasoning-tuned models) spend their max_tokens
-- budget on hidden internal "reasoning" content before writing the actual
-- answer -- tested directly against OpenRouter's API and confirmed that
-- with a modest token budget, gpt-5-mini returns content: null (finish
-- reason "max_output_tokens") because reasoning alone consumed the whole
-- budget. That's a real reliability risk for these demos' short, latency-
-- sensitive prompts, and aidb's openrouter_chat_config doesn't expose a
-- way to disable reasoning effort. gpt-4o-mini has no hidden reasoning
-- step -- confirmed it returns real content immediately even with
-- max_tokens as low as 50. Alternatives, same swap either way:
--   anthropic/claude-haiku-4.5  -- stronger on code/SQL benchmarks, ~4x the
--                                  cost; "extended thinking" is opt-in
--                                  rather than always-on, so likely safe,
--                                  but not directly tested here
--   openai/gpt-5-mini           -- do not use with a small/default
--                                  max_tokens -- see above
SELECT aidb.create_model(
    'my_summarizer',
    'openrouter_chat',
    aidb.openrouter_chat_config(
        model   => 'openai/gpt-4o-mini',
        api_key => :'openrouter_api_key'
    ),
    '{}'::JSONB
);

-- ─────────────────────────────────────────────────────────────────────────
-- Other options, kept for reference -- comment out the two blocks above and
-- use one of these instead:
--
-- Fully local (no API key, no per-token cost, nothing leaves the machine,
-- but consumes real CPU/RAM on the host, and TinyLlama is unreliable on
-- strict-format tasks like demos 2 and 4 -- fine for demo 1's free-text
-- summarization):
--
-- SELECT aidb.create_model(
--     'my_embedder',
--     'bert_local',
--     aidb.bert_config(model => 'sentence-transformers/all-MiniLM-L6-v2'),
--     '{}'::JSONB
-- );
-- SELECT aidb.create_model(
--     'my_summarizer',
--     'llama_instruct_local',
--     aidb.llama_config(model => 'TinyLlama/TinyLlama-1.1B-Chat-v1.0'),
--     '{}'::JSONB
-- );
--
-- Direct OpenAI instead of OpenRouter (requires a real OPENAI_API_KEY):
--
-- SELECT aidb.create_model(
--     'my_embedder',
--     'openai_embeddings',
--     '{"model": "text-embedding-3-small"}'::JSONB,
--     jsonb_build_object('api_key', :'openai_api_key')
-- );
-- SELECT aidb.create_model(
--     'my_summarizer',
--     'openai_completions',
--     '{"model": "gpt-4o-mini"}'::JSONB,
--     jsonb_build_object('api_key', :'openai_api_key')
-- );
-- ─────────────────────────────────────────────────────────────────────────

-- Sanity check
SELECT name, provider FROM aidb.list_models() WHERE name IN ('my_embedder', 'my_summarizer');
