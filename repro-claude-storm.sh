#!/bin/bash
# repro-claude-storm.sh - spawn fresh `claude -p` sessions to faithfully
# reproduce Ralph's session-spawn pattern, with the SAME claude flags Ralph
# uses (--output-format stream-json --verbose) so each session's JSONL is
# captured for forensic inspection.
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
#   FAST_MODE=--fast ./repro-claude-storm.sh   # match Ralph's --fast (premium)
#
# Output:
#   logs/storm-<timestamp>/session-NNN.jsonl   # full stream-json per session
#   logs/storm-<timestamp>/summary.txt         # roll-up of cascade signals
#
# Inspect afterwards with jq, e.g.:
#   jq -c 'select(.type == "system" and (.subtype // "") | test("hook"))' \
#     logs/storm-*/session-*.jsonl
#   jq -c 'select(.type == "user" and (.message.content[]?.is_error == true))' \
#     logs/storm-*/session-*.jsonl
#
# Recovery: ./cleanup.sh

set -uo pipefail
cd "$(dirname "$0")"

SESSIONS=${SESSIONS:-20}
PARALLEL=${PARALLEL:-4}
PROMPT=${PROMPT:-"reply with the single word: done"}
FAST_MODE=${FAST_MODE:-""}            # set to "--fast" to mirror Ralph --fast
LOG_DIR=${LOG_DIR:-"logs/storm-$(date '+%Y%m%d-%H%M%S')"}

if ! command -v claude >/dev/null 2>&1; then
  echo "ERROR: 'claude' not on PATH. Install Claude Code first." >&2
  exit 1
fi

mkdir -p "$LOG_DIR"
SUMMARY="$LOG_DIR/summary.txt"
exec 3>"$SUMMARY"
say() { echo "$@"; echo "$@" >&3; }

# Pre-existing dolt cleanup for clean baseline.
pre_existing="$(pgrep -f 'dolt sql-server' 2>/dev/null | wc -l)"
if [ "$pre_existing" -gt 0 ]; then
  say "Killing $pre_existing pre-existing dolt sql-server process(es) for clean baseline."
  pkill -KILL -f 'dolt sql-server' 2>/dev/null || true
  sleep 1
fi

# Mirror Ralph's claude invocation. Stream-json + verbose lets us grep the
# logs for hook firings, bd errors, tool calls — same shape as Ralph's logs.
CLAUDE_FLAGS=(--output-format stream-json --verbose --dangerously-skip-permissions)
if [ -n "$FAST_MODE" ]; then
  CLAUDE_FLAGS+=("$FAST_MODE")
fi

say "Storming: $SESSIONS sessions, $PARALLEL in parallel."
say "Per-session invocation: claude -p '<prompt>' ${CLAUDE_FLAGS[*]}"
say "Logs: $LOG_DIR/session-NNN.jsonl"
say "Recovery: ./cleanup.sh"
say ""

start="$(date +%s)"
batches=$(( (SESSIONS + PARALLEL - 1) / PARALLEL ))
session=0
for batch in $(seq 1 "$batches"); do
  alive="$(pgrep -f 'dolt sql-server' 2>/dev/null | wc -l)"
  pid_present="$( [ -f .beads/dolt-server.pid ] && echo Y || echo N )"
  port_present="$( [ -f .beads/dolt-server.port ] && echo Y || echo N )"
  zombies="$(ps -eo stat,comm | awk '$2 == "bd" && $1 ~ /^Z/' | wc -l)"
  say "$(printf 'batch %2d  dolts=%s  pid=%s  port=%s  bd-zombies=%s' \
    "$batch" "$alive" "$pid_present" "$port_present" "$zombies")"

  for _ in $(seq 1 "$PARALLEL"); do
    session=$((session + 1))
    if [ "$session" -gt "$SESSIONS" ]; then break; fi
    log_file="$LOG_DIR/session-$(printf '%03d' "$session").jsonl"
    timeout 60 claude -p "$PROMPT" "${CLAUDE_FLAGS[@]}" </dev/null \
      >"$log_file" 2>&1 &
  done
  wait

  if [ "$alive" -gt 3 ]; then
    elapsed=$(( $(date +%s) - start ))
    say ""
    say "CASCADE DETECTED after ${elapsed}s — ${alive} dolts alive."
    say "Logs: $LOG_DIR/"
    say "Run ./dump-state.sh for full picture, then ./cleanup.sh to recover."
    exit 0
  fi
done

elapsed=$(( $(date +%s) - start ))
final="$(pgrep -f 'dolt sql-server' 2>/dev/null | wc -l)"
final_zombies="$(ps -eo stat,comm | awk '$2 == "bd" && $1 ~ /^Z/' | wc -l)"
say ""
say "Done. ${SESSIONS} sessions completed in ${elapsed}s."
say "Final dolt count: ${final}, bd zombies: ${final_zombies}"
say "Logs: $LOG_DIR/"
if [ "$final" -gt 1 ]; then
  say "WARNING: more than 1 dolt alive — possible orphan accumulation."
  say "Run ./dump-state.sh, then ./cleanup.sh if needed."
fi
if [ "$final_zombies" -gt 0 ]; then
  say "WARNING: $final_zombies bd zombies left over — likely from sessions"
  say "         whose parents got SIGSTOP'd or died ungracefully."
fi
