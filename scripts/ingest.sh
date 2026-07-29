#!/bin/bash
# Run on demand, any time — no rebuild needed:
#   docker compose exec epas /opt/scripts/ingest.sh          # scan + ingest pending docs
#   docker compose exec epas /opt/scripts/ingest.sh status   # just show counts, don't ingest
#
# Drop .md, .txt, or .html files into the docs/ folder on your host
# (mounted read-only into the container at /docs). Each run:
#   1. splits any file not already known into chunks (long documents
#      must be chunked -- the default local embedding model, bert_local /
#      all-MiniLM-L6-v2, truncates well before a whole policy page's worth
#      of text; see scripts/chunk.py)
#   2. registers each chunk as a row, status 'pending'
#   3. embeds all 'pending' chunks via the aidb KnowledgeBase pipeline
#   4. marks them 'ingested'
#   5. prints a per-document X of Y chunks ingested summary
set -euo pipefail

DB="mydb"
MODE="run"
if [ "${1:-}" = "status" ]; then
  MODE="status"
fi

PSQL="psql -U postgres -d $DB -v ON_ERROR_STOP=1"

echo "==> Ensuring policies table exists"
$PSQL -q <<'SQL'
CREATE TABLE IF NOT EXISTS policies (
    id SERIAL PRIMARY KEY,
    filename TEXT,
    chunk_index INT,
    title TEXT,
    content TEXT,
    status TEXT NOT NULL DEFAULT 'pending',
    ingested_at TIMESTAMPTZ,
    UNIQUE (filename, chunk_index)
);
SQL

print_summary() {
  echo "==> Per-document status:"
  $PSQL -q -c "
    SELECT
      filename,
      count(*) FILTER (WHERE status = 'ingested') AS chunks_ingested,
      count(*) AS total_chunks,
      CASE WHEN count(*) FILTER (WHERE status = 'pending') = 0
           THEN 'ingested' ELSE 'pending' END AS doc_status
    FROM policies
    GROUP BY filename
    ORDER BY filename;"
  echo "==> Overall:"
  $PSQL -q -c "
    SELECT
      count(*) FILTER (WHERE status = 'ingested') AS chunks_ingested,
      count(*) FILTER (WHERE status = 'pending')  AS chunks_pending,
      count(*) AS total_chunks
    FROM policies;"
}

if [ "$MODE" = "status" ]; then
  print_summary
  exit 0
fi

echo "==> Scanning /docs for new files"
shopt -s nullglob
found_any=0
for f in /docs/*.md /docs/*.txt /docs/*.html; do
  [ -e "$f" ] || continue
  found_any=1
  fname="$(basename "$f")"
  title="${fname%.*}"

  already_known=$($PSQL -t -A -c "SELECT EXISTS (SELECT 1 FROM policies WHERE filename = '$fname');")
  if [ "$already_known" = "t" ]; then
    continue
  fi

  echo "==> New file: $fname"

  case "$f" in
    *.html)
      if command -v python3 >/dev/null 2>&1; then
        extracted="$(python3 - "$f" <<'PYEOF'
import sys, re, html
from html.parser import HTMLParser

path = sys.argv[1]
with open(path, encoding="utf-8", errors="ignore") as fh:
    raw = fh.read()

m = re.search(r"<main[^>]*>(.*)</main>", raw, re.DOTALL | re.IGNORECASE)
fragment = m.group(1) if m else raw

class TextExtractor(HTMLParser):
    def __init__(self):
        super().__init__()
        self.parts = []
        self.skip = 0
    def handle_starttag(self, tag, attrs):
        if tag in ("script", "style", "nav"):
            self.skip += 1
    def handle_endtag(self, tag):
        if tag in ("script", "style", "nav"):
            self.skip = max(0, self.skip - 1)
    def handle_data(self, data):
        if not self.skip:
            self.parts.append(data)

parser = TextExtractor()
parser.feed(fragment)
text = html.unescape(" ".join(parser.parts))
text = re.sub(r"[ \t]+", " ", text)
text = re.sub(r"\n\s*\n+", "\n\n", text)
print(text.strip())
PYEOF
)"
      else
        echo "   (python3 not found — falling back to crude tag strip)"
        extracted="$(sed -e 's/<[^>]*>//g' "$f")"
      fi
      ;;
    *)
      extracted="$(cat "$f")"
      ;;
  esac

  chunk_dir="/tmp/_ingest_chunks"
  rm -rf "$chunk_dir"

  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$extracted" | python3 /opt/scripts/chunk.py "$chunk_dir" > /dev/null
  else
    echo "   (python3 not found — cannot chunk; loading whole file as one chunk,"
    echo "    which the embedding model will silently truncate if it's long)"
    mkdir -p "$chunk_dir"
    printf '%s' "$extracted" > "$chunk_dir/chunk_0000.txt"
  fi

  n=0
  for chunkfile in "$chunk_dir"/chunk_*.txt; do
    [ -e "$chunkfile" ] || continue
    cat > /tmp/_ingest_insert.sql <<'SQL'
INSERT INTO policies (filename, chunk_index, title, content, status)
VALUES (:'filename', :chunk_index, :'title', :'content', 'pending')
ON CONFLICT (filename, chunk_index) DO NOTHING;
SQL
    $PSQL -q \
      -v filename="$fname" \
      -v chunk_index="$n" \
      -v title="$title" \
      -v content="$(cat "$chunkfile")" \
      -f /tmp/_ingest_insert.sql
    n=$((n + 1))
  done
  rm -rf "$chunk_dir"
  echo "   -> split into $n chunk(s)"
done

if [ "$found_any" = "0" ]; then
  echo "   No files found in /docs (expected .md, .txt, or .html)."
fi

pending_count=$($PSQL -t -A -c "SELECT count(*) FROM policies WHERE status = 'pending';")

if [ "$pending_count" = "0" ]; then
  echo "==> Nothing pending, nothing to ingest."
  print_summary
  exit 0
fi

echo "==> $pending_count chunk(s) pending — building/refreshing aidb pipeline"

pipeline_exists=$($PSQL -t -A -c "
  SELECT EXISTS (
    SELECT 1 FROM aidb.pipeline_registry WHERE name = 'policies_kb'
  );")

if [ "$pipeline_exists" != "t" ]; then
  echo "==> Creating pipeline 'policies_kb' (first run)"
  $PSQL -q -c "
    SELECT aidb.create_pipeline(
        name => 'policies_kb',
        source => 'policies',
        source_key_column => 'id',
        source_data_column => 'content',
        step_1 => 'KnowledgeBase',
        step_1_options => aidb.knowledge_base_config('my_embedder', 'Text')
    );"
fi

echo "==> Running pipeline (embeds any new/changed rows)"
$PSQL -q -c "SELECT aidb.run_pipeline('policies_kb');"

echo "==> Marking previously-pending chunks as ingested"
$PSQL -q -c "
  UPDATE policies
  SET status = 'ingested', ingested_at = now()
  WHERE status = 'pending';"

print_summary

echo "==> Try a search:"
echo "    SELECT * FROM aidb.retrieve_text('policies_kb', 'how much vacation do I get', 3);"
