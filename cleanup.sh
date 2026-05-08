#!/bin/bash
# cleanup.sh - recover from the dolt-orphan cascade.
#
# Identical in spirit to ortus's recover-dolt.sh. Copied here so this
# repro repo is self-contained.
#
# Steps:
#   1. SIGKILL all dolt sql-server processes visible to this shell.
#   2. Remove bd-owned state files (.beads/dolt-server.{lock,pid,port}).
#   3. Clear stale /tmp/beads-circuit/*.json files.
#   4. NEVER touch .beads/dolt/.dolt/noms/LOCK or any other dolt-internal
#      file (gastownhall/beads#2933).
#   5. In server mode: run `bd dolt start` and verify.
#      In embedded mode: skip — `bd dolt start` errors with
#      "not supported in embedded mode (no Dolt server)".

set -e
cd "$(dirname "$0")"

PIDS="$(pgrep -f 'dolt sql-server' 2>/dev/null || true)"
if [ -n "$PIDS" ]; then
  count="$(echo "$PIDS" | wc -w)"
  echo "Killing ${count} dolt sql-server process(es)..."
  kill -KILL $PIDS 2>/dev/null || true
  sleep 1
fi

for f in .beads/dolt-server.lock .beads/dolt-server.pid .beads/dolt-server.port; do
  [ -e "$f" ] && rm -f "$f" && echo "Removed $f"
done

if compgen -G "/tmp/beads-circuit/*.json" >/dev/null 2>&1; then
  rm -f /tmp/beads-circuit/*.json
  echo "Cleared /tmp/beads-circuit/*.json"
fi

# Detect mode from `bd dolt status`. Embedded mode prints
# "Dolt engine: embedded (in-process, no server)" and `bd dolt start`
# errors out — skip the start step.
mode_status="$(bd dolt status 2>&1 || true)"
if echo "$mode_status" | grep -q 'embedded'; then
  echo "Embedded mode detected — skipping 'bd dolt start' (not supported in embedded)."
else
  echo "Starting fresh dolt..."
  bd dolt start 2>&1 | sed 's/^/  /'
fi

echo
echo "Final state:"
"$(dirname "$0")/dump-state.sh"
