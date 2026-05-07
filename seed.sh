#!/bin/bash
# seed.sh - create 5 starter bd issues so `bd ready` has rows to return.
# Run once after `bd init`.

set -euo pipefail

if [ ! -d .beads ]; then
  echo "ERROR: no .beads/ in $PWD. Run 'bd init' first." >&2
  exit 1
fi

for i in 1 2 3 4 5; do
  bd create \
    --title="Seed issue $i" \
    --description="Filler issue $i for the bd-locking-bug repro. No real work attached." \
    --type=task \
    --priority=2 \
    >/dev/null
done

echo "Seeded 5 issues."
bd ready 2>&1 | tail -10
