# bd-locking-bug — minimal repro

Reproduces the dolt-server orphan cascade in `bd` v1.0.3.

## What you'll see

After running `./repro.sh` for ~30 seconds to ~5 minutes (depends on system
load):

- `pgrep -cf 'dolt sql-server'` grows past 1 — sometimes to dozens.
- `.beads/dolt-server.pid` and `.beads/dolt-server.port` disappear from disk
  even though dolt is still running.
- New `bd` commands start failing with:
  ```
  Error: failed to open database: Dolt server unreachable at 127.0.0.1:0
  and auto-start failed: server started (PID …) but not accepting
  connections on port …: timeout after 10s
  ```
- `bd dolt stop` reports success but doesn't kill the orphans (it can't —
  it doesn't know about them).
- The only escape is `pkill -9 dolt sql-server` + manual state cleanup +
  `bd dolt start`.

## Why it happens (short version)

`bd`'s `IsRunning()` in `internal/doltserver/doltserver.go:519-524` deletes
`.beads/dolt-server.{pid,port}` whenever `isDoltProcess(pid)` returns false.
That function shells out to `pgrep -f "dolt sql-server"` + `ps -p <pid> -o command=`.
**Any transient failure of those commands** (system load, brief race, `Z`
state byte during exit, cmdline read error) returns false, and bd nukes
the state files. From there, every subsequent `bd` call auto-starts a new
dolt that loses the `noms/LOCK` race against the surviving alive dolt,
fails `waitForReady`, and orphans itself. Cascade.

Long version + proposed fixes: see the attached upstream issue draft
(`UPSTREAM-ISSUE.md` in this directory if present, otherwise reference
gastownhall/beads#3392 — same root cause, different framing).

## Setup

Requires: `bd` v1.0.3 on `$PATH`, `jq`, GNU coreutils, `pgrep`/`ps`.

```bash
git clone https://github.com/who/bd-locking-bug.git
cd <path-to-cloned-repo>/bd-locking-bug
bd init                    # creates .beads/
./seed.sh                  # creates 5 ready issues so bd has something to query
./dump-state.sh            # baseline: should show 1 dolt, all state files present
```

## Repro

```bash
./repro.sh                 # parallel bd loop. ctrl-c to stop.
```

In another terminal, watch the damage:

```bash
watch -n 1 './dump-state.sh'
```

You'll see the dolt process count climb and the state files start vanishing.

## Recovery

```bash
./cleanup.sh               # SIGKILLs all dolts, clears bd-owned state, restarts
```

This is identical to ortus's `recover-dolt.sh`; copied here so the repro
is self-contained.

## Files

- `seed.sh` — creates 5 starter bd issues so `bd ready` returns rows
- `repro.sh` — parallel bd loop that triggers the cascade
- `dump-state.sh` — one-shot diagnostic snapshot
- `cleanup.sh` — kill orphans + reset state + restart fresh

Nothing else. No application code. The repo exists to demonstrate one bug.

## Sharing

`.beads/` and runtime artifacts are gitignored. Safe to `git init` and push.
