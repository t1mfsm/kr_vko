#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TAIL_PID=""

cleanup() {
    if [[ -n "${TAIL_PID}" ]] && kill -0 "${TAIL_PID}" 2>/dev/null; then
        kill "${TAIL_PID}" 2>/dev/null || true
    fi
    "$SCRIPT_DIR/stop.sh" >/dev/null 2>&1 || true
    exit 0
}

trap cleanup SIGINT SIGTERM

mkdir -p "$SCRIPT_DIR/logs"
touch "$SCRIPT_DIR/logs/system_journal.log"

"$SCRIPT_DIR/start.sh"

tail -F "$SCRIPT_DIR/logs/system_journal.log" &
TAIL_PID=$!
wait "${TAIL_PID}"
