# Engineering Debug Assistant — RAG-powered Bug Fix Search

An on-premises RAG system that helps engineers diagnose bugs faster by searching historical fixes using natural language. Describe a crash, hang, or error in plain English and the system retrieves the most relevant historical bug fixes, root causes, and actual code patches — then synthesizes a grounded, cited answer using an LLM. No data leaves your infrastructure unless you choose a cloud LLM provider.

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
GOOGLE_MODEL=gemini-2.0-flash
```

Get a free key at [aistudio.google.com](https://aistudio.google.com). All other values in `.env.example` work as-is for a local deployment.

### Step 3 — Install dependencies

```bash
# Python (run from repo root with venv active)
python3 -m venv .venv
source .venv/bin/activate
pip install fastapi uvicorn psycopg[binary] psycopg2-binary python-dotenv \
            FlagEmbedding requests google-genai

# React UI
cd debug-assistant-ui && npm install && cd ..
```

### Step 4 — Point to your repository and ingest

**To use your own repo** (replace the demo pandas dataset):

1. Clone the target repository anywhere on your machine:

   ```bash
   git clone https://github.com/your-org/your-repo.git ~/rag_data/your-repo
   ```

2. Open `ingest_panda_commits_with_patch.py` and `create_patch_child_chunks.py` and update these two lines at the top of each file:

   ```python
   REPO = Path.home() / "rag_data" / "your-repo"   # path to your cloned repo
   ```

   Also update the project name string (search for `"pandas"` in both files and replace with your project name, e.g. `"my-repo"`).

3. Optionally adjust `LIMIT = 500` in `ingest_panda_commits_with_patch.py` to control how many commits to ingest.

**To try the system with the included pandas demo**, clone pandas first:

```bash
git clone https://github.com/pandas-dev/pandas.git ~/rag_data/pandas
```

Then run the three ingestion stages:

```bash
# Stage 1: ingest commits with full patches
python3 ingest_panda_commits_with_patch.py

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

![System Architecture](docs/debug_assistant_architecture.png)

### Ingestion Flow

![Ingestion Flow](docs/debug_assistant_ingestion_flow.png)

### Retrieval Flow

![Retrieval Flow](docs/debug_assistant_retrieval_flow.png)

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

1. **Parent chunk** — full commit: subject, body, author, date, files changed, and truncated patch (20,000 char cap). Ingested by `ingest_panda_commits_with_patch.py`.
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
├── ingest_panda_commits_with_patch.py  # Stage 1: commit ingestion with patches
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
  id           TEXT PRIMARY KEY,   -- e.g. "pandas-commit-abc123-patch-002"
  project      TEXT NOT NULL,      -- "pandas"
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

**bge-small-en-v1.5** (384-dim, BAAI) was chosen for V1 based on hardware constraints — the development machine is a Snapdragon X laptop with 16GB RAM running WSL2. Larger models (bge-large-en-v1.5, 1024-dim) would produce higher-quality embeddings but were too slow for iterative development on this hardware.

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

The system prompt includes: *"If the answer is not supported by the context, say I don't know."* For a debugging tool, a confidently wrong answer is worse than no answer — an engineer might spend hours chasing a fabricated root cause.

---

### Q10: Why no agent framework in V1?

V1's pipeline is fully linear and determined before the LLM is called:

```text
query understanding → sufficiency check → hybrid search → prompt assembly → generate
```

Agent orchestration (LangGraph, LangChain agents) solves the problem of *deciding what to do next* — branching mid-flow, calling tools, multi-step reasoning. V1 doesn't have that problem. Adding an agent framework would be unjustified complexity with no payoff.

V2 roadmap includes a multi-agent architecture: a **Triage Agent** (query classification), **Root Cause Agent** (retrieval + synthesis), and **Fix Suggester Agent** (patch recommendation), coordinated by a LangGraph orchestrator. That's when the framework investment becomes justified.

---

## Known Limitations

**Local inference is slow on this hardware.** The development machine is a Snapdragon X Elite laptop running WSL2. Ollama runs CPU-only because the Adreno GPU is not yet supported — phi3:3.8B takes 2–4 minutes per query. Cloud providers (Groq, Gemini) respond in under 5 seconds and produce significantly better output.

**Small local models are inconsistent.** phi3:3.8B occasionally ignores the `TLDR: / EXPLANATION: / CODE:` format constraints, requiring fallback parsing logic in `answer_api.py`. Models at 30B+ (Groq llama-3.3-70b, Gemini) follow structured output instructions reliably.

**Free-tier rate limits apply.** Groq and Google Gemini free tiers have RPM/TPM caps. Under heavy testing this surfaces as 429 errors. Acceptable for single-engineer use; a paid tier or self-hosted 30B+ model would be needed for team deployment.

**500-commit corpus is a proof of concept.** The pandas dataset was chosen for its dense, well-labelled bug history (`BUG:` prefixes, clean patches). Real deployment requires ingesting your own repository and potentially tuning the bug-detection heuristics for your team's commit conventions.

**No authentication.** The APIs bind to `0.0.0.0` on localhost. Not suitable for networked or multi-user deployment without adding an auth layer.

---

## V2 Roadmap

- [ ] **Redis caching** — 24-hour TTL on search results and LLM answers for repeated queries
- [ ] **Cross-encoder reranker** — `bge-reranker-large` as a second-pass step after hybrid fusion, replacing the current heuristic score formula
- [ ] **LangGraph multi-agent orchestration** — separate agents for query understanding, retrieval, reranking, and generation; enables parallel retrieval strategies and richer reasoning traces
- [ ] **Repo onboarding UI** — paste a Git URL, the system clones, ingests, and chunks automatically with no manual script execution
- [ ] **HNSW index at scale** — currently commented out in `init.sql`; enable after bulk load for sub-millisecond approximate nearest-neighbor search
- [ ] **Automated test suite** — property-based tests for query extraction; integration tests for the full pipeline against a fixed fixture corpus
- [ ] **Streaming responses** — stream LLM tokens to the React UI to reduce perceived latency on slower providers
- [ ] **Recency-weighted ranking (blame-search mode)** — introduce a query intent classifier that distinguishes between two fundamentally different search modes:

  | Mode | Question being asked | Recency matters? |
  |------|----------------------|-----------------|
  | **Fix-search** *(current default)* | "What historical fix exists for this bug pattern?" | No — a 3-year-old fix for the same root cause is equally valuable |
  | **Blame-search** *(new)* | "What changed recently that caused this regression?" | Yes — surface commits from the last 30/60/90 days touching relevant files/functions |

  **Implementation approach:**
  - Query understanding step extracts intent signals (`"regression"`, `"worked before"`, `"recent change"`, `"what broke"`) to classify the mode
  - Blame-search applies a recency boost: `score += (days_since_epoch / max_days) * weight`
  - Fix-search scoring remains unchanged
  - UI labels which mode was used so the engineer understands why results are ranked as shown

  > *Triggered by LinkedIn post engagement — real engineer feedback that recency weighting is a legitimate use case for regression debugging, distinct from fix-search intent.*

- [ ] **Full codebase ingestion (optional mode)** — index the entire source tree alongside commit history, not just changed files. Enables retrieval to answer questions about code that was never modified in a bug fix commit (e.g. "how does function X work", "what does this class do"). Implemented as an opt-in per-project config flag since full codebase indexing significantly increases chunk count and retrieval latency. Uses the same AST chunking strategy as patch chunks — function-level granularity, not file-level.

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
