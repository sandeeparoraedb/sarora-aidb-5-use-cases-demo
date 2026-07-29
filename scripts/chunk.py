#!/usr/bin/env python3
"""
Reads text on stdin, splits it into chunks, and writes each chunk to its
own file in the output directory given as argv[1] (chunk_0000.txt,
chunk_0001.txt, ...).

Chunking strategy: pack whole paragraphs (blank-line separated) together
until adding the next one would exceed the target size; a single
paragraph longer than the limit gets hard-split.

Note: this repo's default embedding model (aidb's bert_local /
sentence-transformers/all-MiniLM-L6-v2) has its own much shorter internal
token limit (256 tokens) and will silently truncate anything longer --
these ~6000-character chunks are sized generously for readability/context
in the `content` column, not to fit the model's actual input window. Fine
for this demo's short work-order docs (each lands in a single chunk); if
you swap in longer source documents, consider chunking closer to the
embedding model's real limit for better retrieval quality. If you switch
sql/02-aidb-models.sql to the OpenAI-backed alternative, its 8192-token
limit gives much more headroom than the current MAX_CHARS setting uses.
"""
import sys
import os

MAX_CHARS = 6000

out_dir = sys.argv[1]
os.makedirs(out_dir, exist_ok=True)

text = sys.stdin.read()
paragraphs = [p.strip() for p in text.split("\n\n") if p.strip()]

chunks = []
buf = ""

def flush():
    global buf
    if buf.strip():
        chunks.append(buf.strip())
    buf = ""

for p in paragraphs:
    if len(p) > MAX_CHARS:
        flush()
        for i in range(0, len(p), MAX_CHARS):
            chunks.append(p[i:i + MAX_CHARS])
        continue
    candidate = (buf + "\n\n" + p) if buf else p
    if len(candidate) > MAX_CHARS:
        flush()
        buf = p
    else:
        buf = candidate

flush()

for i, chunk in enumerate(chunks):
    with open(os.path.join(out_dir, f"chunk_{i:04d}.txt"), "w", encoding="utf-8") as fh:
        fh.write(chunk)

print(len(chunks))
