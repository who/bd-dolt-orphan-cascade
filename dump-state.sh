#!/bin/bash
# dump-state.sh - one-shot snapshot of bd/dolt state. Use to verify baseline
# before repro and to quantify damage during/after.

set -uo pipefail

cd "$(dirname "$0")"

echo "=== $(date '+%Y-%m-%d %H:%M:%S') ==="
echo
echo "dolt sql-server processes:"
pgrep -af 'dolt sql-server' 2>/dev/null | grep -v 'pgrep\|/bin/bash -c' || echo "  (none)"
# Use pipe-to-wc for the count: pgrep -c exits 1 when count is 0, which
# trips up `|| echo 0` (it appends a second line).
echo "  count: $(pgrep -f 'dolt sql-server' 2>/dev/null | wc -l)"
echo

echo "bd-owned state files:"
for f in .beads/dolt-server.pid .beads/dolt-server.port .beads/dolt-server.lock .beads/dolt-server.log; do
  if [ -e "$f" ]; then
    printf '  %-32s  %s bytes\n' "$f" "$(stat -c '%s' "$f" 2>/dev/null || echo ?)"
  else
    printf '  %-32s  MISSING\n' "$f"
  fi
done
echo

echo "noms LOCK files (dolt-internal — DO NOT TOUCH):"
find .beads/dolt -name LOCK -type f 2>/dev/null | sed 's/^/  /' || true
echo

echo "/tmp/beads-circuit/ files:"
ls /tmp/beads-circuit/*.json 2>/dev/null | sed 's/^/  /' || echo "  (none)"
echo

echo "bd dolt status:"
timeout 5 bd dolt status 2>&1 | sed 's/^/  /' || echo "  (bd dolt status timed out or errored)"
