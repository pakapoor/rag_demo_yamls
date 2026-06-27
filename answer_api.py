from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
import requests
import time
import logging
import json
from pathlib import Path
from config import SEARCH_URL, GOOGLE_MODEL
from query_understanding import extract_query
from prompt_builder import build_prompt
from llm_client import ask_llm

# Logs outside Google Drive sync
LOG_DIR = Path.home() / "rag_logs"
LOG_DIR.mkdir(parents=True, exist_ok=True)

log_file = LOG_DIR / "answer_api.log"

logging.basicConfig(
    level=logging.INFO,
    format="%(message)s",
    handlers=[
        logging.FileHandler(log_file),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)


def log_request(endpoint: str, query: str, response_time: float, status: str, extra: dict = {}):
    entry = {
        "timestamp": __import__("datetime").datetime.utcnow().isoformat(),
        "endpoint": endpoint,
        "query": query,
        "response_time_seconds": round(response_time, 3),
        "status": status,
        **extra
    }
    logger.info(json.dumps(entry))

app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

STRUCTURED_PROMPT_SUFFIX = """

You MUST respond using EXACTLY these three section headers in this exact order.
Do not skip any section. Do not add extra text before TLDR.

TLDR:
<one sentence: what was the bug and how was it fixed>

EXPLANATION:
<2-3 paragraphs: what caused the bug, why it happened, and what the fix does>

CODE:
<the actual diff lines from the patch. Must use diff format with - for removed lines and + for added lines. No markdown fences. Example:
- old line of code
+ new line of code
>
"""

def parse_structured_response(raw: str) -> dict:
    sections = {"tldr": "", "explanation": "", "code": ""}

    current = None
    buffer = []

    for line in raw.splitlines():
        if line.strip() == "TLDR:":
            current = "tldr"
            buffer = []
        elif line.strip() == "EXPLANATION:":
            if current:
                sections[current] = "\n".join(buffer).strip()
            current = "explanation"
            buffer = []
        elif line.strip() == "CODE:":
            if current:
                sections[current] = "\n".join(buffer).strip()
            current = "code"
            buffer = []
        elif current:
            buffer.append(line)

    if current:
        sections[current] = "\n".join(buffer).strip()

    # Strip markdown code fences from code section
    code = sections["code"]
    if code.startswith("```"):
        lines = code.splitlines()
        lines = [l for l in lines if not l.startswith("```")]
        code = "\n".join(lines).strip()

    # Strip citation bleed-in from code section
    clean_code_lines = []
    for line in code.splitlines():
        if line.startswith("[commit:"):
            break
        clean_code_lines.append(line)
    sections["code"] = "\n".join(clean_code_lines).strip()

    # Fallback: if TLDR is empty, extract first sentence from explanation
    if not sections["tldr"] and sections["explanation"]:
        first_sentence = sections["explanation"].split(".")[0].strip() + "."
        sections["tldr"] = first_sentence

    return sections


@app.get("/ask")
def ask(q: str):
    start_time = time.time()

    # Step 1: query understanding + sufficiency check
    parsed = extract_query(q)

    if parsed.get("confidence") == "low":
        log_request("/ask", q, time.time() - start_time, "low_confidence")
        return {
            "confidence": "low",
            "follow_up": parsed.get("follow_up", "Can you provide more details?"),
            "tldr": None,
            "explanation": None,
            "code": None,
            "citations": [],
            "negations": [],
            "time_taken": round(time.time() - start_time, 2)
        }

    # Step 2: hybrid search
    resp = requests.get(SEARCH_URL, params={"q": q}, timeout=30)
    resp.raise_for_status()
    results = resp.json()

    # Apply negation filtering: drop results whose text contains a negated term.
    negations = [n.lower() for n in parsed.get("negations", [])]
    if negations:
        results = [
            r for r in results
            if not any(neg in r.get("text", "").lower() for neg in negations)
        ]

    # Step 3: build prompt + ask LLM
    base_prompt = build_prompt(q, results)
    structured_prompt = base_prompt + STRUCTURED_PROMPT_SUFFIX
    raw_answer = ask_llm(structured_prompt, timeout=60)

    # Step 4: parse structured response
    sections = parse_structured_response(raw_answer)

    # Step 5: build citations
    citations = []
    seen = set()
    for r in results:
        commit = r.get("source_id", "unknown")
        if commit in seen:
            continue
        seen.add(commit)
        text = r.get("text", "")
        subject = ""
        for line in text.splitlines():
            if line.startswith("SUBJECT:"):
                subject = line.replace("SUBJECT:", "").strip()
                break
        citations.append({
            "commit": commit[:12],
            "subject": subject
        })

    response_time = time.time() - start_time
    log_request("/ask", q, response_time, "ok", {
        "model": GOOGLE_MODEL,
        "results_used": len(results),
        "citations": len(citations),
        "negations": parsed.get("negations", []),
    })

    return {
        "confidence": "high",
        "follow_up": None,
        "tldr": sections["tldr"],
        "explanation": sections["explanation"],
        "code": sections["code"],
        "citations": citations,
        "negations": parsed.get("negations", []),
        "time_taken": round(response_time, 3),
    }