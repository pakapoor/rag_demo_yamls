#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m' # No Color

ok()   { echo -e "  ${GREEN}✓${NC}  $1"; }
info() { echo -e "  ${CYAN}→${NC}  $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC}  $1"; }
err()  { echo -e "  ${RED}✗${NC}  $1"; }
step() { echo -e "\n${BOLD}$1${NC}"; }

# Resolve venv and uvicorn paths per OS
if [[ "$OSTYPE" == "darwin"* ]]; then
    VENV_DIR="$HOME/rag_venv_mac/venv"
else
    VENV_DIR="$HOME/rag_venv/venv"
fi

UVICORN="$VENV_DIR/bin/uvicorn"
PYTHON="$VENV_DIR/bin/python"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"

# Helper: get PID on a port (Mac and Linux compatible)
get_port_pid() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        lsof -ti tcp:$1 2>/dev/null
    else
        fuser $1/tcp 2>/dev/null
    fi
}

# Helper: check if port is in use (Mac and Linux compatible)
port_in_use() {
    get_port_pid $1 > /dev/null 2>&1
}

# Helper: wait until a port is listening, with a timeout
# Usage: wait_for_port <port> <timeout_seconds> <service_name>
wait_for_port() {
    local port=$1
    local timeout=$2
    local name=$3
    local elapsed=0
    while ! port_in_use $port; do
        sleep 1
        elapsed=$((elapsed + 1))
        if [[ $elapsed -ge $timeout ]]; then
            return 1
        fi
    done
    return 0
}

# Helper: abort on fatal error — stop all services and exit
fatal() {
    err "$1"
    echo ""
    warn "Shutting down all services due to error..."
    bash "$SCRIPT_DIR/stop_all.sh"
    exit 1
}

echo ""
echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
echo -e "${BOLD}║      Debug Assistant         ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"

# Stop any running services first
step "[0/4] Cleaning up existing services..."
bash "$SCRIPT_DIR/stop_all.sh"

# Run dependency setup
step "[·]   Checking dependencies..."
bash "$SCRIPT_DIR/setup_dependencies.sh"
if [[ $? -ne 0 ]]; then
    err "Dependency setup failed. Fix the errors above and try again."
    exit 1
fi
ok "Dependencies ready."

# Start Docker if not running
step "[·]   Checking Docker..."
if ! docker info > /dev/null 2>&1; then
    warn "Docker not running. Starting Docker..."
    if [[ "$OSTYPE" == "darwin"* ]]; then
        open -a Docker
        info "Waiting for Docker Desktop..."
        while ! docker info > /dev/null 2>&1; do
            sleep 2
        done
    else
        sudo service docker start
        sleep 3
    fi
    ok "Docker ready."
else
    ok "Docker already running."
fi

# Start Postgres
step "[1/4] Starting Postgres..."
cd "$SCRIPT_DIR"
docker compose up -d postgres > /dev/null 2>&1
info "Waiting for Postgres to be ready..."
until docker exec rag-demo-postgres pg_isready -U raguser -d ragdemo > /dev/null 2>&1; do
    sleep 1
done
ok "Postgres ready."

# Start hybrid search API on port 8001
step "[2/4] Starting hybrid search API..."
info "Loading BGE embedding model (this takes ~10s on first start)..."
cd "$SCRIPT_DIR"
"$UVICORN" hybrid_api:app --host 0.0.0.0 --port 8001 > "$LOG_DIR/hybrid_api.log" 2>&1 &
if wait_for_port 8001 30 "Hybrid search API"; then
    ok "Hybrid search API running on port 8001."
else
    err "Hybrid search API did not start within 30s."
    info "Last log output:"
    tail -10 "$LOG_DIR/hybrid_api.log" | sed 's/^/     /'
    fatal "Hybrid search API failed to start."
fi

# Start answer API on port 8002
step "[3/4] Starting answer API..."
"$UVICORN" answer_api:app --host 0.0.0.0 --port 8002 > "$LOG_DIR/answer_api.log" 2>&1 &
if wait_for_port 8002 20 "Answer API"; then
    ok "Answer API running on port 8002."
else
    err "Answer API did not start within 20s."
    info "Last log output:"
    tail -10 "$LOG_DIR/answer_api.log" | sed 's/^/     /'
    fatal "Answer API failed to start."
fi

# Start React UI
step "[4/4] Starting React UI..."
cd "$SCRIPT_DIR/debug-assistant-ui" && npm start > "$LOG_DIR/react_ui.log" 2>&1 &
if wait_for_port 3000 30 "React UI"; then
    ok "React UI running on port 3000."
else
    warn "React UI did not bind port 3000 within 30s — may still be compiling."
fi

echo ""
echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
echo -e "${BOLD}║         All services started!        ║${NC}"
echo -e "${BOLD}╠══════════════════════════════════════╣${NC}"
echo -e "${BOLD}║${NC}  Search API  →  ${CYAN}http://localhost:8001${NC} ${BOLD}║${NC}"
echo -e "${BOLD}║${NC}  Answer API  →  ${CYAN}http://localhost:8002${NC} ${BOLD}║${NC}"
echo -e "${BOLD}║${NC}  React UI    →  ${CYAN}http://localhost:3000${NC} ${BOLD}║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
echo ""
echo -e "${DIM}  Logs: $LOG_DIR/${NC}"
echo -e "${DIM}  Press Ctrl+C to stop all services.${NC}"
echo ""

wait
