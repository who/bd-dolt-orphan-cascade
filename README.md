# bd-dolt-orphan-cascade — minimal repro

Documents the dolt-server orphan cascade in `bd` v1.0.3.

## ⚠️ Read this first: the repro is non-deterministic

**Synthetic parallel `bd` calls in this repo do not reliably trigger the
cascade.** I have personally seen the bug manifest three times in one day
under organic Ralph (autonomous-agent loop) workload — most recently with
49 orphan `dolt sql-server` processes accumulated over four hours, plus a
later cluster of 11 orphans in a few hours. But running `./repro.sh` here
in a tight loop with up to 16 parallel bd calls per round, on the same
machine where the cascade had just been observed, **did not reproduce**
in 35 rounds (embedded mode) or 30 rounds × 16 parallel = 480 bd calls
(server mode in a separate `bubbles` repo).

The bug is real and the code path is identifiable (see "Why it happens"
below — it's about 6 lines of Go in `internal/doltserver/doltserver.go`),
but a deterministic repro script eludes me. The trigger appears to be a
specific combination of: long-running workload (hours), Ralph-style varied
bd commands (`bd update`, `bd close`, `bd dolt push` — not just reads),
system load events that flake `pgrep`/`ps`, and probably some interaction
with `bd prime` SessionStart hooks across many short-lived bd processes.

**The strongest evidence is the code analysis, not this repro.** Treat
this repo as supporting documentation, not proof-by-execution.

## What the cascade looks like in the wild

When it does trigger:

- `pgrep -cf 'dolt sql-server'` grows past 1 — observed up to 49.
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
git clone https://github.com/who/bd-dolt-orphan-cascade.git
cd bd-dolt-orphan-cascade
bd init                    # creates .beads/ in DEFAULT mode (currently 'embedded')
./seed.sh                  # creates 5 ready issues so bd has something to query
./dump-state.sh            # baseline snapshot
```

### Mode matters

`bd init` defaults to **embedded** mode in v1.0.3 ("Mode: embedded" in the
init output). The cascade in its purest, fastest form requires **server**
mode (the per-repo standalone server with `.beads/dolt-server.{pid,port}`
state files). Embedded mode also exhibits the bug — but slower, and the
state files involved are different.

To repro the canonical server-mode cascade, re-init with the right flag.
Check `bd init --help` for the exact name; in v1.0.3 it's likely
`bd init --shared-server` or `bd init --no-embedded`.

### Embedded vs server mode in practice

After 35 rounds of parallel bd calls in fresh embedded-mode repo:
**0 dolt sql-server processes spawned**, no state files, no cascade.
Embedded mode genuinely keeps everything in-process.

After 30 rounds × 16 parallel = 480 bd calls in a real server-mode repo
(`bubbles`, where the cascade was observed earlier the same day):
**still 1 dolt, all state files present, no cascade.** The single dolt
absorbed all 480 calls correctly. Synthetic stress wasn't enough to flake
`pgrep`/`ps` and trigger the deletion path.

If you are seeing dolt sql-server processes appear during a "Mode: embedded"
run, double-check whether they're from another repo on the same host. The
circuit-breaker filenames in `/tmp/beads-circuit/` include the project
prefix and are an easy tell.

## Repro (best-effort)

There are two scripts, mirroring two hypotheses about the trigger.

### Variant A — `repro.sh` (parallel bd calls, including `bd prime`)

```bash
./repro.sh                 # parallel bd loop. ctrl-c to stop.
```

Each round fires `bd prime`, `bd ready`, `bd list`, `bd show` in parallel
against the same shell. `bd prime` is what the SessionStart/PreCompact
hooks (configured in `.claude/settings.json`) actually call — running it
directly here mimics the hook code path without the cost of spinning up
a real Claude session.

Tunables: `ROUNDS=N PARALLEL=M ./repro.sh`. Defaults: 1000 × 8.

### Variant B — `repro-claude-storm.sh` (real `claude -p` sessions)

```bash
./repro-claude-storm.sh                    # 20 sessions × 4 parallel
SESSIONS=50 PARALLEL=8 ./repro-claude-storm.sh
```

Spawns fresh `claude -p` invocations. Each one boots a Node runtime, sets
up a bwrap sandbox, fires the SessionStart hook (→ `bd prime` →
`EnsureRunning` → `IsRunning`), responds to a one-word prompt, and exits.
This is the closest synthetic equivalent of Ralph's per-iteration pattern.

Costs real Anthropic API tokens — but with a tiny prompt and a small
session count, the bill is pennies. Use sparingly.

### Watching the state

In another terminal, while either script runs:

```bash
watch -n 1 './dump-state.sh'
```

What you may see (from either script):

- **No cascade.** Most likely outcome under synthetic load on a quiet
  machine. If `dolts` stays at 1 with state files present, the bug isn't
  reproducing right now.
- **Cross-repo orphan detection.** Both scripts kill pre-existing `dolt
  sql-server` processes (globally) before starting, so the count reflects
  this repo only. If you see a `Killing N pre-existing` line, those came
  from elsewhere — that's normal.
- **Cascade.** Either script self-terminates with `CASCADE DETECTED` once
  `pgrep -f 'dolt sql-server' | wc -l` exceeds 3. If you hit this, run
  `./dump-state.sh` for a snapshot, then `./cleanup.sh` to recover.

### If you really want to chase it

The most likely path to a deterministic repro probably involves:

- A multi-process workload that mixes reads and writes (`bd update`,
  `bd close`, `bd create`, `bd dolt push`) — not just reads.
- Many short-lived bd processes spawned in quick succession (Ralph-style
  agent loops, or `bd prime` hooks firing on every Claude Code session
  start in parallel — that's what Variant B exercises).
- Either real CPU/memory pressure on the host, or artificial scheduling
  jitter. The trigger is `pgrep` or `ps` returning a transient error or
  empty result, which is hard to provoke deterministically on a quiet
  machine.

If you reproduce deterministically, please update this README with the
exact recipe.

## Recovery

```bash
./cleanup.sh               # SIGKILLs all dolts, clears bd-owned state, restarts
```

This is identical to ortus's `recover-dolt.sh`; copied here so the repro
is self-contained.

## Files

- `seed.sh` — creates 5 starter bd issues so `bd ready` returns rows
- `repro.sh` — Variant A: parallel bd loop including `bd prime` (the hook command)
- `repro-claude-storm.sh` — Variant B: spawns fresh `claude -p` sessions to
  fire the real SessionStart hook through Claude Code's full lifecycle
- `dump-state.sh` — one-shot diagnostic snapshot
- `cleanup.sh` — kill orphans + reset state + restart fresh (validated
  multiple times against the cascade in real Ralph workloads)
- `.claude/settings.json` — bd-installed SessionStart + PreCompact hooks
  that fire `bd prime` (this is what makes Variant B faithful)

Nothing else. No application code. The repo exists to demonstrate one bug
and provide a reliable recovery path for it.

## Sharing

`.beads/` and runtime artifacts are gitignored. Safe to `git init` and push.
