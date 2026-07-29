#!/bin/bash
# Ask a question against the ingested policies, RAG-style:
#   docker compose exec epas /opt/scripts/ask.sh "how much vacation do I get"
#
# Optional second arg: number of chunks to retrieve (default 5)
#   docker compose exec epas /opt/scripts/ask.sh "how much vacation do I get" 8
set -euo pipefail

QUESTION="${1:?Usage: ask.sh \"your question\" [num_chunks]}"
TOP_K="${2:-5}"
DB="${DB:-mydb}"

cat > /tmp/_ask.sql <<'SQL'
SELECT aidb.decode_text('my_summarizer',
    'Answer the question using only the context below. If the context does not contain the answer, say so.

Question: ' || :'question' || '

Context:
' ||
    (SELECT string_agg(value, E'\n---\n')
     FROM aidb.retrieve_text('policies_kb', :'question', :top_k::int))
);
SQL

psql -U postgres -d "$DB" -v ON_ERROR_STOP=1 -q \
     -v question="$QUESTION" \
     -v top_k="$TOP_K" \
     -f /tmp/_ask.sql
