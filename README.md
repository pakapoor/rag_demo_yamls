# Engineering Debug Assistant — RAG-powered Bug Fix Search

An on-premises RAG system that helps engineers diagnose bugs faster by searching historical fixes using natural language. Describe a crash, hang, or error in plain English and the system retrieves the most relevant historical bug fixes, root causes, and actual code patches — then synthesizes a grounded, cited answer using an LLM. No data leaves your infrastructure unless you choose a cloud LLM provider.

## TL;DR

- **What it does:** Type a bug description → get a cited answer with root cause, explanation, and code fix
- **How it works:** Hybrid BM25 + vector search over your git history, answered by an LLM
- **What it needs:** Docker, Python 3.11+, Node.js 18+, a free Google Gemini API key
- **How to run:** `cp .env.example .env` → add API key → `./start_all.sh` → open [http://localhost:3000](http://localhost:3000)
- **Bring your own repo:** Point the ingest scripts at any git repository, not just the included pandas demo

---

## Quickstart

Follow these three steps to get a local instance running for development or evaluation.

1. Copy the environment template and set secrets:

```bash
cp .env.example .env
# Edit .env and set your API key(s). Example:
# GOOGLE_API_KEY=your_key_here
# GOOGLE_MODEL=gemini-3.1-flash-lite
```

2. Start services:

```bash
./start_all.sh
```

3. Open the UI in your browser:

[http://localhost:3000](http://localhost:3000)

## Environment

Key environment variables used by the project. Put these in `.env` or export them in your shell for local runs.

- `POSTGRES_URL` — Postgres connection string (e.g. `postgresql://user:pass@localhost:5432/dbname`)
- `GOOGLE_API_KEY` — Google Gemini API key (optional if using another LLM provider)
- `GOOGLE_MODEL` — e.g. `gemini-3.1-flash-lite` (provider-specific model id)
- `FLAG_EMBEDDING_MODEL` — embedding model id (default: `BAAI/bge-small-en-v1.5`)
- `PGVECTOR_DIM` — embedding dimension (must match the model, default `384`)
- `PROJECT` — project name used by ingestion scripts (set before running ingestion)

Example `.env` snippet:

```text
# PostgreSQL
POSTGRES_URL=postgresql://postgres:postgres@localhost:5432/debugdb

# LLM
GOOGLE_API_KEY=your_key_here
GOOGLE_MODEL=gemini-3.1-flash-lite

# Embeddings
FLAG_EMBEDDING_MODEL=BAAI/bge-small-en-v1.5
PGVECTOR_DIM=384

# Ingest
PROJECT=pandas
```


## Demo

<video src="https://github.com/user-attachments/assets/cf2fd47e-c705-49d4-9d5e-13940619d0fc" controls width="100%"></video>

---

## Usage

Open [http://localhost:3000](http://localhost:3000) and describe your bug in plain English.

**Example queries:**

```text
crash in generic.py around line 2393 not related to scheduler
DataFrame groupby aggregate memory error
BUG duplicated loses index
hang in the dispatcher not a.cpp
```

**What you get back:**

| Panel | Content |
| ----- | ------- |
| TL;DR | One-sentence summary of the root cause and fix |
| Explanation | 2–3 paragraph analysis grounded in the historical commit |
| Code Fix | The actual diff from the fix, syntax-highlighted |
| Citations | Commit SHAs linking back to the source |

**Query tips:**

- Include a **signal word**: crash, hang, segfault, memory error, assertion, timeout
- Name a **file or function** if you know it: `groupby`, `generic.py`, `DataFrame`
- Use **negations** to exclude irrelevant matches: `not scheduler`, `not a.cpp`
- Vague queries like `"it crashed"` trigger a clarifying follow-up — add more detail and resubmit

---

## Deployment

### System Requirements

| Requirement | Version |
| ----------- | ------- |
| Python | 3.11+ |
| Node.js | 18+ |
| Docker | 24+ with Docker Compose |
| RAM | 8 GB minimum (16 GB recommended for embedding generation) |
| API key | Google Gemini — free tier sufficient for single-engineer use |

### Step 1 — Clone the repository

```bash
git clone https://github.com/pakapoor/ai_enabled_debug_assistant.git
cd ai_enabled_debug_assistant
```

### Step 2 — Configure environment

```bash
cp .env.example .env
```

Open `.env` and set your Gemini API key:

```bash
GOOGLE_API_KEY=your_key_here
GOOGLE_MODEL=gemini-3.1-flash-lite
```

Get a free key at [aistudio.google.com](https://aistudio.google.com). All other values in `.env.example` work as-is for a local deployment.

### Step 3 — Install dependencies

Dependencies are installed automatically when you run `./start_all.sh`.

If you prefer to install manually first, run:

```bash
bash setup_dependencies.sh
```

### Step 4 — Point to your repository and ingest

**To use your own repo:**

1. Clone the target repository:

   ```bash
   git clone https://github.com/your-org/your-repo.git ~/rag_data/your-repo
   ```

2. Open `ingest_commits.py` and `create_patch_child_chunks.py` and set the `PROJECT` variable at the top of each file:

   ```python
   PROJECT = "your-repo"   # must match in both files
   ```

3. Optionally adjust `LIMIT = 500` in `ingest_commits.py` to control how many commits to ingest.

**To try the included pandas demo**, clone pandas first:

```bash
git clone https://github.com/pandas-dev/pandas.git ~/rag_data/pandas
# then set PROJECT = "pandas" in both ingest files
```

Then run the three ingestion stages:

```bash
# Stage 1: ingest commits with full patches
python3 ingest_commits.py

# Stage 2: generate AST-enriched per-file child chunks
python3 create_patch_child_chunks.py

# Stage 3: compute BGE-small-en-v1.5 embeddings
python3 app/compute_embeddings.py
```

Expected result: ~2,037 chunks with embeddings in Postgres.

### Step 5 — Start everything

```bash
./start_all.sh
```

This starts all services automatically:

| Service | URL |
| ------- | --- |
| Hybrid search API | [http://localhost:8001](http://localhost:8001) |
| Answer API | [http://localhost:8002](http://localhost:8002) |
| React UI | [http://localhost:3000](http://localhost:3000) |

### Step 6 — Open the UI

Open [http://localhost:3000](http://localhost:3000). The system is ready. See the **Usage** section above for example queries and tips.

---

## How It Works

```text
Engineer types query
        │
        ▼
query_understanding.py ──► LLM extracts structured JSON
  { signal, file, function, negations, confidence }
        │
        ├── confidence = "low" ──► Return follow-up question (no LLM inference wasted)
        │
        ▼
hybrid_api.py  (port 8001)
  ├── BM25 full-text search  (PostgreSQL tsvector)
  ├── Vector cosine search   (pgvector, BGE-small-en-v1.5, 384-dim)
  └── Merge via custom RRF scoring
        │  + bug boost (+50)
        │  - doc penalty (-30)
        ▼
answer_api.py  (port 8002)
  ├── prompt_builder.py  (grounded context injection)
  ├── llm_client.py      (provider-agnostic LLM call)
  └── parse structured response → { tldr, explanation, code, citations }
        │
        ▼
React UI  (port 3000)
  TL;DR panel │ Explanation panel │ Code Fix (diff, syntax-highlighted) │ Citations
```

![System Architecture](docs/system_design.svg)

### Ingestion Flow

![Ingestion Flow](docs/debug_assistant_ingestion_flow.svg)

### Retrieval Flow

![Retrieval Flow](docs/debug_assistant_retrieval_flow.svg)

---

## Coming Soon

- [ ] **One-click onboarding** — paste a Git URL and the system clones, ingests, and indexes your repo automatically, no manual scripts needed
- [ ] **Recency-weighted blame search** — ask "what changed recently that broke this?" and the system surfaces commits from the past 30/60/90 days weighted by recency, not just historical fixes
- [ ] **Search your whole codebase** — opt in to index all source files, not just changed files, so you can ask questions about any function or class even if it was never in a bug fix commit
- [ ] **Answers as they stream** — results appear word by word as the LLM generates them, no waiting for the full response
- [ ] **Smarter result ranking** — a second-pass reranker filters candidates for relevance before presenting results, reducing noise in the top 3
- [ ] **Repeat queries answered instantly** — results are cached for 24 hours so the same query returns immediately on second ask
- [ ] **Multi-agent reasoning** — separate specialized agents for query understanding, retrieval, and fix suggestion work in parallel for richer answers
- [ ] **Team-scale deployment** — authentication layer and multi-user support for shared team access
- [ ] **Fast vector search at scale** — HNSW approximate nearest-neighbor index enabled for sub-millisecond search as your corpus grows beyond thousands of chunks
- [ ] **Automated test suite** — integration tests for the full pipeline against a fixed fixture corpus so contributors can validate changes confidently

---

## Tech Stack

| Layer | Technology |
| ----- | ---------- |
| Vector store | PostgreSQL 16 + pgvector |
| Embeddings | BGE-small-en-v1.5 (384-dim, FlagEmbedding) |
| Full-text search | PostgreSQL `tsvector` / `ts_rank_cd` |
| Backend APIs | FastAPI + Uvicorn |
| LLM interface | Google Gemini (default), Groq, Ollama |
| Frontend | React 19, Axios, react-syntax-highlighter |
| Infrastructure | Docker Compose |
| Language | Python 3.11, JavaScript (React) |
| Data source | pandas GitHub repository (500 commits, ~2,037 chunks) |

---

## Key Technical Decisions

### Storage: PostgreSQL + pgvector over Pinecone / Qdrant

Pinecone and Qdrant are purpose-built vector stores but they split your data across two systems — a vector index and a relational database for metadata. Keeping everything in PostgreSQL gives transactional atomicity (embeddings and metadata update together or not at all), full SQL expressiveness for filtering, and keeps all engineer data on-premises. pgvector's HNSW index handles the vector search with comparable latency at this scale.

### Hybrid Search with Custom Scoring

Pure vector search struggles with exact technical terms (function names, error codes, file paths). Pure keyword search misses semantic similarity. The system runs both in parallel and merges results with a custom Reciprocal Rank Fusion variant:

```text
base_score = 100 - (rank × 5)
final_score = base_score + bug_boost - doc_penalty
```

- **Bug boost (+50):** Commits prefixed `BUG:` are surfaced above general refactors
- **Documentation penalty (-30):** `.rst`, `.md`, and `whatsnew/` files are deprioritized — engineers want code, not changelog entries

### Two-Tier Chunking

Git commits are ingested at two levels:

1. **Parent chunk** — full commit: subject, body, author, date, files changed, and truncated patch (20,000 char cap). Ingested by `ingest_commits.py`.
2. **Child chunks** — one chunk per changed file within the patch, extracted by `create_patch_child_chunks.py`. Each child chunk adds:
   - Python AST parsing to identify the enclosing class and function for every hunk start line
   - Full function source (up to 120 lines) injected as `FUNCTION CONTEXT`
   - Hunk headers extracted for structural context

This means a query about `DataFrame.groupby()` can hit the exact function body rather than a 500-line commit blob.

### Query Understanding as a Sufficiency Gate

Before touching the search index, `query_understanding.py` sends the raw query to the LLM and asks for structured JSON:

```json
{
  "signal": "crash",
  "file": "generic.py",
  "function": "groupby",
  "line": 2393,
  "stack_trace": false,
  "keywords": ["groupby", "aggregate", "crash"],
  "negations": ["scheduler"],
  "confidence": "high",
  "follow_up": null
}
```

If `confidence` is `"low"` (fewer than two qualifying signals present), the API returns a follow-up question immediately — no search, no LLM generation call, no latency. Negations like `"not scheduler"` are extracted and surfaced in the UI so the engineer knows what was excluded.

### Structured LLM Output

The answer API instructs the LLM to respond in a fixed three-section format:

```text
TLDR:
<one sentence>

EXPLANATION:
<2-3 paragraphs>

CODE:
<raw diff lines, no fences>
```

`answer_api.py` parses this deterministically into separate fields. The React frontend renders each section in its own panel, with the `CODE` section piped through `react-syntax-highlighter` using the `diff` language and VSCode Dark+ theme.

### LLM-Agnostic Design

`llm_client.py` is a single-function interface:

```python
def ask_llm(prompt: str, timeout: int = 60) -> str: ...
```

Swapping providers is a one-file change. Tested with:

- **Ollama phi3:3.8b** — local CPU inference (slow, inconsistent instruction following)
- **Groq llama-3.3-70b** — fast cloud inference, good quality
- **Google Gemini 1.5 Flash / 2.0 Flash** — current default, best quality/cost ratio

---

## Project Structure

```text
.
├── answer_api.py                       # FastAPI port 8002 — full pipeline endpoint
├── hybrid_api.py                       # FastAPI port 8001 — hybrid search endpoint
├── query_understanding.py              # LLM-based structured query extraction
├── llm_client.py                       # Provider-agnostic LLM interface
├── prompt_builder.py                   # Grounded prompt construction
├── config.py                           # Env-var configuration
│
├── ingest_commits.py                   # Stage 1: commit ingestion with patches
├── ingest_commits_legacy.py            # Stage 1 (legacy, no patch content)
├── create_patch_child_chunks.py        # Stage 2: AST-enriched per-file chunks
├── app/compute_embeddings.py           # Stage 3: BGE embeddings → DB
│
├── debug-assistant-ui/                 # React frontend
│   └── src/App.js                      # TL;DR / Explanation / Code Fix / Citations
│
├── app/
│   ├── main.py                         # Legacy FastAPI (keyword search only)
│   ├── load_db.py                      # Legacy YAML bug loader
│   ├── ingest.py                       # Legacy ingestion
│   └── search.py                       # Legacy search
│
├── tests/
│   ├── test_query_understanding.py
│   ├── test_function_context.py
│   ├── test_function_locator.py
│   └── test_ask_model.py
│
├── bugs/                               # Synthetic YAML bug reports (dev/testing)
├── config/projects.yml                 # Project registry
├── init.sql                            # PostgreSQL schema + indexes
├── docker-compose.yml                  # Postgres + pgvector
├── .env.example                        # Environment variable template
│
├── start_all.sh                        # Starts all services (Postgres, APIs, React UI)
├── setup_dependencies.sh               # Auto-installs Python packages and React dependencies
├── stop_all.sh                         # Stops all running services cleanly
│
├── hybrid_search_cli.py                # CLI: run hybrid search interactively
├── delete_commits.py                   # Dev utility: wipe chunks table
├── prompt_from_search.py               # Test harness: print built prompt
├── search_ui.py                        # Tkinter debug UI (legacy)
│
└── generate_bugs.py / generate_custom_bugs.py / generate_detailed_bugs.py
                                        # Synthetic bug YAML generators
```

---

## Database Schema

```sql
CREATE TABLE chunks (
  id           TEXT PRIMARY KEY,   -- e.g. "my-repo-commit-abc123-patch-002"
  project      TEXT NOT NULL,      -- your PROJECT name, e.g. "my-repo"
  source_type  TEXT NOT NULL,      -- "git_commit" | "git_patch_file"
  source_id    TEXT NOT NULL,      -- commit SHA
  parent_id    TEXT,               -- set on child chunks
  chunk_index  INT NOT NULL,
  chunk_text   TEXT NOT NULL,
  metadata     JSONB NOT NULL,     -- commit, author, date, files, is_bug, function_names...
  embedding    vector(384),        -- BGE-small-en-v1.5
  created_at   TIMESTAMPTZ,
  updated_at   TIMESTAMPTZ
);

-- GIN index for full-text search
CREATE INDEX ON chunks USING GIN(to_tsvector('english', chunk_text));
-- GIN index for JSONB metadata filtering
CREATE INDEX ON chunks USING GIN(metadata);
-- HNSW vector index (enable after bulk load — commented out in init.sql)
-- CREATE INDEX ON chunks USING hnsw (embedding vector_cosine_ops);
```

---

## Design Decisions & Deep Dives

### Q1: Chunking strategy

**Two-tier, source-aware chunking:**
- Commit messages + file lists → parent chunks (`git_commit` source type)
- Per-file patches → child chunks (`git_patch_file` source type)

For code chunks, Python's built-in `ast` module parses each changed file to identify the enclosing class and function for every hunk start line. The full function source (up to 120 lines) is injected as `FUNCTION CONTEXT` into each child chunk. This means retrieval hits the exact function body, not an arbitrary 500-token window.

For oversized functions (>120 lines), the function source is truncated with a note — a windowed-diff fallback is on the V2 roadmap.

**Why not fixed-size chunking?** Fixed-size chunking splits functions mid-logic. A query about `DataFrame.groupby()` would get a random 500-token window rather than the complete function, destroying retrieval quality.

---

### Q2: Vector DB choice — pgvector over Pinecone/Qdrant

pgvector was chosen because one row holds vector + text + metadata atomically. A single query can do semantic search, keyword search, and metadata filtering together without joining across two systems.

| Option | Verdict | Reason |
|--------|---------|--------|
| pgvector | Chosen | Atomic row, hybrid search native, self-hostable |
| Pinecone | Rejected | Data leaves perimeter, managed only |
| Qdrant | Close alternative | Loses one-row atomicity |
| Weaviate | Rejected | JVM overhead for capability Postgres already provides |
| Milvus | Rejected | Billion-vector scale — overkill at 2K chunks |

Past ~5M chunks, pgvector has no native sharding — path would be Citus extension or app-level partitioning by project.

---

### Q3: Hybrid search design

Pure vector search blurs exact technical terms (function names, file paths, error codes). Pure BM25 misses semantic paraphrases ("SIGABRT" ≈ "SIGSEGV" ≈ "program crashed"). The system runs both in parallel:

```text
BM25 top-10 + vector top-10 → custom RRF scoring → top-3
```

Custom scoring formula:

```text
base_score  = 100 - (rank × 5)
final_score = base_score + bug_boost - doc_penalty

bug_boost   = +50   (chunks where is_bug = True)
doc_penalty = -30   (chunks from .rst, .md, whatsnew/ files)
```

The bug boost ensures actual fix commits surface above general refactors. The doc penalty ensures engineers get code patches, not changelog entries.

---

### Q4: Metadata storage — JSONB over a separate document store

Metadata lives in Postgres JSONB alongside the vector and text, not in a separate MongoDB instance. MongoDB's "schemaless" flexibility is a property of the JSON data model, not MongoDB-exclusive — JSONB provides identical flexibility. Keeping everything in one row preserves atomicity: vector, text, and metadata update together or not at all.

| Option | Verdict | Reason |
|--------|---------|--------|
| Postgres JSONB | Chosen | Same schema flexibility, zero extra system, atomicity preserved |
| MongoDB (separate) | Rejected | Breaks atomicity — vector and metadata would need to be joined across two systems |

---

### Q5: Embedding model choice

**bge-small-en-v1.5** (384-dim, BAAI) was chosen for V1 based on hardware constraints — developed and tested on a Snapdragon X laptop (16GB RAM, WSL2 Ubuntu) and Mac M2 mini (8GB RAM, macOS). Larger models (bge-large-en-v1.5, 1024-dim) would produce higher-quality embeddings but were too slow for iterative development on these machines.

The model runs fully self-hosted via FlagEmbedding — no API calls, no data leaving the machine.

| Option | Verdict | Reason |
|--------|---------|--------|
| bge-small-en-v1.5 (384-dim) | Chosen | Fast on CPU, self-hostable, fits V1 hardware |
| bge-large-en-v1.5 (1024-dim) | V2 candidate | Higher quality but too slow for CPU-only iteration |
| bge-m3 (multilingual, 1024-dim) | V2 candidate | Multilingual not needed for English-only corpus |
| OpenAI / Cohere (API-based) | Rejected | Data leaves perimeter for any on-prem deployment |

---

### Q6: Indexing — cosine similarity, HNSW, GIN

Cosine similarity measures the angle between vectors, ignoring magnitude. This matters for text because chunk length inflates vector magnitude arbitrarily — a short query and a long commit message about the same bug shouldn't appear "far apart" just because one is longer.

In practice, V1 uses **dot product on pre-normalized vectors** — normalization happens once at ingestion, so every query gets cosine correctness at dot product speed.

The HNSW (Hierarchical Navigable Small World) index is commented out in `init.sql` and should be enabled after bulk load in production. Without it, pgvector falls back to exact sequential scan — acceptable at 2K chunks, does not scale.

Three index types in use:

| Index | Column | Purpose |
|-------|--------|---------|
| HNSW | `embedding` | Approximate nearest-neighbor vector search |
| GIN | `to_tsvector(chunk_text)` | BM25-equivalent full-text search |
| GIN | `metadata` | Fast JSONB filtering (`is_bug`, `file`, `source_type`) |

HNSW is approximate — may occasionally miss the single true closest match. Acceptable because the system retrieves top-20 candidates before scoring, not just top-1.

---

### Q7: Query understanding — structured extraction and sufficiency gate

Before touching the search index, every query passes through `query_understanding.py`, which makes a fast LLM call to extract structured JSON:

```json
{
  "signal": "crash",
  "file": "generic.py",
  "function": "groupby",
  "line": 2393,
  "stack_trace": false,
  "keywords": ["groupby", "aggregate"],
  "negations": ["scheduler"],
  "confidence": "high",
  "follow_up": null
}
```

If `confidence` is `"low"` (fewer than two qualifying signals — signal word, file name, function name, or technical keywords), the API returns a follow-up question immediately — no search, no LLM generation, no latency wasted. A bare query like `"it crashed"` or `"hang"` alone triggers this gate.

Negations (`"not scheduler"`, `"not a.cpp"`) are extracted and surfaced in the UI so the engineer knows what was excluded. Spelling correction runs in the same call — `"datafrme"` → `"DataFrame"`, `"gruopby"` → `"groupby"`.

---

### Q8: LLM choice — provider-agnostic design

`llm_client.py` is a single-function interface — swapping providers is a one-file change:

```python
def ask_llm(prompt: str, timeout: int = 60) -> str: ...
```

Providers tested:

| Provider | Model | Latency | Quality | Notes |
|----------|-------|---------|---------|-------|
| Ollama (local) | phi3:3.8b | ~90s | Inconsistent | CPU-only on Snapdragon X, ignores format instructions |
| Groq | llama-3.3-70b-versatile | ~2s | Excellent | Free tier: 100K tokens/day |
| Google Gemini | gemini-3.1-flash-lite | ~3s | Good | Current default |

For a production deployment with on-prem data sovereignty requirements, **Llama 3 70B via vLLM on a GPU server** is the right choice — Apache license, Western origin (no procurement friction in regulated industries), mature self-hosting tooling.

---

### Q9: Prompt design — structured output and grounding

The answer API instructs the LLM to respond in a fixed three-section format:

```text
TLDR:
<one sentence>

EXPLANATION:
<2-3 paragraphs>

CODE:
<raw diff lines, no markdown fences>
```

`answer_api.py` parses this deterministically by scanning for the exact section headers. Fallbacks handle non-compliant model output:

- If `TLDR:` is missing → first sentence of `EXPLANATION` is used
- If `CODE:` contains markdown fences → stripped before rendering
- If `CODE:` bleeds into citations (lines starting with `[commit:`) → truncated at that boundary
- If `negations` are present → matching results are filtered out before LLM generation (applied in `answer_api.py` before prompt assembly)

The system prompt includes: *"If the answer is not supported by the context, say I don't know."* For a debugging tool, a confidently wrong answer is worse than no answer — an engineer might spend hours chasing a fabricated root cause.

---

### Q10: Why no agent framework in V1?

V1's pipeline is fully linear and determined before the LLM is called:

```text
query understanding → sufficiency check → hybrid search → prompt assembly → generate
```

Agent orchestration (LangGraph, LangChain agents) solves the problem of *deciding what to do next* — branching mid-flow, calling tools, multi-step reasoning. V1 doesn't have that problem. Adding an agent framework would be unjustified complexity with no payoff.

The closest V1 has to agentic behavior is the sufficiency gate in `query_understanding.py` — a fast LLM call that classifies query intent and decides whether to proceed to search or ask the user for more detail. This is a deliberate, lightweight form of conditional branching without the overhead of a full agent framework.

V2 roadmap includes a multi-agent architecture: a **Triage Agent** (query classification), **Root Cause Agent** (retrieval + synthesis), and **Fix Suggester Agent** (patch recommendation), coordinated by a LangGraph orchestrator. That's when the framework investment becomes justified.

---

### Q11: Logging and observability in V1

Structured JSON logging is built into `answer_api.py` using Python's standard `logging` module. Every request writes a newline-delimited JSON entry to `~/rag_logs/answer_api.log`:

```json
{
  "timestamp": "2026-06-22T10:45:23.112000",
  "endpoint": "/ask",
  "query": "crash in groupby.pyx when NA values",
  "response_time_seconds": 3.247,
  "status": "ok",
  "model": "gemini-3.1-flash-lite",
  "results_used": 3,
  "citations": 2,
  "negations": []
}
```

Low-confidence queries that triggered a follow-up are logged with `"status": "low_confidence"` — making it easy to measure the sufficiency gate's false-positive rate and tune the confidence threshold over time.

Logs are written to `~/rag_logs/` (outside the project folder) to avoid Google Drive sync corruption — the same pattern used for Python virtual environments on this development setup.

Full LLM pipeline observability (per-step tracing, hallucination detection, retrieval drift monitoring) is planned for V2 via Langfuse — a self-hosted, MIT-licensed LLM observability platform that plugs directly into the existing FastAPI backend.

---

## Known Limitations

**Local inference is slow on this hardware.** The development machine is a Snapdragon X laptop running WSL2. Ollama runs CPU-only because the Adreno GPU is not yet supported — phi3:3.8B takes 2–4 minutes per query. Cloud providers (Groq, Gemini) respond in under 5 seconds and produce significantly better output.

**Small local models are inconsistent.** phi3:3.8B occasionally ignores the `TLDR: / EXPLANATION: / CODE:` format constraints, requiring fallback parsing logic in `answer_api.py`. Models at 30B+ (Groq llama-3.3-70b, Gemini) follow structured output instructions reliably.

**Free-tier rate limits apply.** Groq and Google Gemini free tiers have RPM/TPM caps. Under heavy testing this surfaces as 429 errors. Acceptable for single-engineer use; a paid tier or self-hosted 30B+ model would be needed for team deployment.

**500-commit corpus is a proof of concept.** The pandas dataset was chosen for its dense, well-labelled bug history (`BUG:` prefixes, clean patches). Real deployment requires ingesting your own repository and potentially tuning the bug-detection heuristics for your team's commit conventions.

**No authentication.** The APIs bind to `0.0.0.0` on localhost. Not suitable for networked or multi-user deployment without adding an auth layer.

---

## Development Utilities

```bash
# Reset the chunks table during development
python3 delete_commits.py

# Run hybrid search from the command line (no UI needed)
python3 hybrid_search_cli.py

# Print the full grounded prompt for a query (useful for debugging retrieval)
python3 prompt_from_search.py

# Check row and embedding counts
bash count_rows.sh

# Generate synthetic YAML bugs for testing ingestion
python3 generate_detailed_bugs.py
```

---

## Logging

All services write structured JSON logs to `~/rag_logs/` (outside the project folder to avoid Google Drive sync issues).

| Log file | Service | What it captures |
|----------|---------|-----------------|
| `~/rag_logs/answer_api.log` | Answer API (port 8002) | Every query, response time, model used, citation count, negations applied |
| `~/rag_logs/hybrid_api.log` | Hybrid search API (port 8001) | Search requests, result counts, BM25/vector scores |
| `~/rag_logs/react_ui.log` | React UI (port 3000) | npm start output, compilation errors |

### Log format

Each entry is a single JSON line (newline-delimited JSON):

```json
{
  "timestamp": "2026-06-22T10:45:23.112000",
  "endpoint": "/ask",
  "query": "crash in groupby.pyx when group key contains NA values",
  "response_time_seconds": 3.247,
  "status": "ok",
  "model": "gemini-3.1-flash-lite",
  "results_used": 3,
  "citations": 2,
  "negations": []
}
```

Low-confidence queries that triggered a follow-up question are logged separately:

```json
{
  "timestamp": "2026-06-22T10:46:01.334000",
  "endpoint": "/ask",
  "query": "it crashed",
  "response_time_seconds": 1.12,
  "status": "low_confidence"
}
```

### Useful log commands

```bash
# Watch live query activity
tail -f ~/rag_logs/answer_api.log

# Pretty-print the last 10 queries
tail -10 ~/rag_logs/answer_api.log | python3 -m json.tool

# Find all slow queries (over 5 seconds)
grep -h "" ~/rag_logs/answer_api.log | python3 -c "
import sys, json
for line in sys.stdin:
    try:
        entry = json.loads(line)
        if entry.get('response_time_seconds', 0) > 5:
            print(f\"{entry['timestamp']} | {entry['response_time_seconds']}s | {entry['query']}\")
    except: pass
"

# Count queries by status (ok vs low_confidence)
grep -h "" ~/rag_logs/answer_api.log | python3 -c "
import sys, json
from collections import Counter
counts = Counter()
for line in sys.stdin:
    try:
        counts[json.loads(line).get('status', 'unknown')] += 1
    except: pass
for status, count in counts.items():
    print(f'{status}: {count}')
"

# Find all queries that used negations
grep -h "" ~/rag_logs/answer_api.log | python3 -c "
import sys, json
for line in sys.stdin:
    try:
        entry = json.loads(line)
        if entry.get('negations'):
            print(f\"{entry['timestamp']} | negations={entry['negations']} | {entry['query']}\")
    except: pass
"
```

### Viewing logs from start_all.sh

When started via `./start_all.sh`, service logs are also written to `logs/` inside the project folder:

```bash
# View hybrid search API startup and request logs
tail -f logs/hybrid_api.log

# View answer API logs
tail -f logs/answer_api.log

# View React UI compilation output
tail -f logs/react_ui.log
```

## Ingestion checklist

Use this quick checklist when ingesting a repo to ensure all stages completed successfully.

- Set `PROJECT` consistently in `ingest_commits.py` and `create_patch_child_chunks.py`.
- Run ingestion stages in order:

```bash
python3 ingest_commits.py
python3 create_patch_child_chunks.py
python3 app/compute_embeddings.py
```

- Verify DB rows and embeddings:

```sql
SELECT count(*) FROM chunks WHERE project='your-project-name';
SELECT count(*) FROM chunks WHERE project='your-project-name' AND embedding IS NOT NULL;
```

- If embeddings are missing, re-run `app/compute_embeddings.py` and inspect console logs for provider errors or rate limiting.
- For very large repositories, ingest in smaller `LIMIT` batches and monitor Postgres disk usage.

## Troubleshooting & FAQ

- UI shows no results: verify `hybrid_api.py` and `answer_api.py` are running and `POSTGRES_URL` points at the right DB.
- Embedding dimension mismatch: ensure `PGVECTOR_DIM` matches the model (default `384`). If wrong, reinitialize the DB schema on a fresh database.
- `pgvector` extension errors: enable extension with `CREATE EXTENSION IF NOT EXISTS vector;` as a superuser.
- LLM errors or rate limits: check `GOOGLE_API_KEY` and `GOOGLE_MODEL`. Reduce concurrency or switch to a local test model (Ollama) for development.
- Query parser keeps asking follow-ups: provide more context (file or function) or tune the `EXTRACTION_PROMPT` examples in `query_understanding.py`.
- AST parsing failures during chunking: some files may use syntax unsupported by the parser; inspect `create_patch_child_chunks.py` logs and skip problematic files temporarily.

- Want to run services individually for debugging? Examples:

```bash
# Start Postgres via docker-compose
docker compose up -d postgres

# Run hybrid API locally
python3 hybrid_api.py

# Run answer API locally
python3 answer_api.py
```

## Contributing & Tests

We welcome contributions. Quick guide:

- Run tests locally with `pytest`.
- Tests are in the `tests/` folder. To run a single test file:

```bash
pytest tests/test_query_understanding.py -q
```

- Add a unit test for any behavior you change. Keep tests small and focused.
- Format Python with `black .` and run `flake8` if installed.
- To propose a change: fork, create a topic branch, add tests, open a PR with a short description and the failing case if applicable.

If you'd like, I can also add CI workflow examples (`.github/workflows/python-app.yml`) for running tests on PRs.
