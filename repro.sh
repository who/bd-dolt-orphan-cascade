#!/bin/bash
# repro.sh - trigger the dolt-orphan cascade by running many parallel bd calls.
#
# Each round fires N parallel bd calls and waits for them. Within a few rounds
# (depends on system load), pgrep/ps will have one transient hiccup, bd's
# IsRunning() will delete the state files, and the cascade starts.
#
# Watch progress in another terminal: watch -n 1 ./dump-state.sh
#
# Stop with ctrl-c. Recover with ./cleanup.sh.

set -uo pipefail

ROUNDS=${ROUNDS:-1000}
PARALLEL=${PARALLEL:-8}

if [ ! -f .beads/issues.jsonl ] || [ "$(wc -l < .beads/issues.jsonl 2>/dev/null || echo 0)" -lt 1 ]; then
  echo "ERROR: no bd issues found. Run './seed.sh' first." >&2
  exit 1
fi

echo "Starting repro: $ROUNDS rounds × $PARALLEL parallel bd calls."
echo "Press ctrl-c to stop. Run ./cleanup.sh to recover."
echo

# Capture an issue id once — we'll hammer 'bd show' against it.
TARGET_ID="$(bd ready --json 2>/dev/null | jq -r '.[0].id // empty')"
if [ -z "$TARGET_ID" ]; then
  echo "ERROR: bd ready returned no issues. Did seed.sh succeed?" >&2
  exit 1
fi
echo "Hammering with target id: $TARGET_ID"
echo

start="$(date +%s)"
for round in $(seq "$ROUNDS"); do
  alive="$(pgrep -cf 'dolt sql-server' 2>/dev/null || echo 0)"
  pid_present="$( [ -f .beads/dolt-server.pid ] && echo Y || echo N )"
  port_present="$( [ -f .beads/dolt-server.port ] && echo Y || echo N )"
  printf 'round %4d  dolts=%s  pid=%s  port=%s\n' \
    "$round" "$alive" "$pid_present" "$port_present"

  for _ in $(seq "$PARALLEL"); do
    bd ready >/dev/null 2>&1 &
    bd list  >/dev/null 2>&1 &
    bd show "$TARGET_ID" >/dev/null 2>&1 &
  done
  wait

  # Bail loudly if the cascade has clearly started.
  if [ "$alive" -gt 5 ]; then
    elapsed=$(( $(date +%s) - start ))
    echo
    echo "CASCADE DETECTED after ${elapsed}s — ${alive} dolts alive."
    echo "Run ./dump-state.sh for full picture, then ./cleanup.sh to recover."
    exit 0
  fi
done
