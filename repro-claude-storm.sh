#!/bin/bash
# repro-claude-storm.sh - spawn fresh `claude -p` sessions to faithfully
# reproduce Ralph's session-spawn pattern.
#
# Each session does what every Ralph iteration does:
#   1. Boots a fresh Claude Code process (Node runtime + bwrap sandbox setup)
#   2. Loads .claude/settings.json
#   3. Fires the SessionStart hook → executes `bd prime`
#   4. `bd prime` calls EnsureRunning → IsRunning (the buggy code path)
#   5. Receives the prompt, responds in ~1-2 seconds, exits cleanly
#   6. Sandbox tears down
#
# Costs real Anthropic API tokens. Default 20 sessions × tiny prompt is
# pennies; tunable via env vars.
#
# Usage:
#   ./repro-claude-storm.sh                    # 20 sessions, 4 parallel
#   SESSIONS=50 PARALLEL=8 ./repro-claude-storm.sh
#
# Recovery: ./cleanup.sh

set -uo pipefail
cd "$(dirname "$0")"

SESSIONS=${SESSIONS:-20}
PARALLEL=${PARALLEL:-4}
PROMPT=${PROMPT:-"reply with the single word: done"}

if ! command -v claude >/dev/null 2>&1; then
  echo "ERROR: 'claude' not on PATH. Install Claude Code first." >&2
  exit 1
fi

# Pre-existing dolt cleanup for clean baseline.
pre_existing="$(pgrep -f 'dolt sql-server' 2>/dev/null | wc -l)"
if [ "$pre_existing" -gt 0 ]; then
  echo "Killing $pre_existing pre-existing dolt sql-server process(es) for clean baseline."
  pkill -KILL -f 'dolt sql-server' 2>/dev/null || true
  sleep 1
fi

echo "Storming: $SESSIONS sessions, $PARALLEL in parallel."
echo "Each session: claude -p '$PROMPT' --dangerously-skip-permissions"
echo "Recovery: ./cleanup.sh"
echo

start="$(date +%s)"
batches=$(( (SESSIONS + PARALLEL - 1) / PARALLEL ))
session=0
for batch in $(seq 1 "$batches"); do
  alive="$(pgrep -f 'dolt sql-server' 2>/dev/null | wc -l)"
  pid_present="$( [ -f .beads/dolt-server.pid ] && echo Y || echo N )"
  port_present="$( [ -f .beads/dolt-server.port ] && echo Y || echo N )"
  printf 'batch %2d  dolts=%s  pid=%s  port=%s\n' \
    "$batch" "$alive" "$pid_present" "$port_present"

  for _ in $(seq 1 "$PARALLEL"); do
    session=$((session + 1))
    if [ "$session" -gt "$SESSIONS" ]; then break; fi
    timeout 60 claude -p "$PROMPT" --dangerously-skip-permissions </dev/null >/dev/null 2>&1 &
  done
  wait

  if [ "$alive" -gt 3 ]; then
    elapsed=$(( $(date +%s) - start ))
    echo
    echo "CASCADE DETECTED after ${elapsed}s — ${alive} dolts alive."
    echo "Run ./dump-state.sh for full picture, then ./cleanup.sh to recover."
    exit 0
  fi
done

elapsed=$(( $(date +%s) - start ))
final="$(pgrep -f 'dolt sql-server' 2>/dev/null | wc -l)"
echo
echo "Done. ${SESSIONS} sessions completed in ${elapsed}s."
echo "Final dolt count: ${final}"
if [ "$final" -gt 1 ]; then
  echo "WARNING: more than 1 dolt alive — possible orphan accumulation."
  echo "Run ./dump-state.sh, then ./cleanup.sh if needed."
fi
