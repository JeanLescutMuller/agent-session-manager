# ASM: Developer Documentation

Requirements and design rationale for Agent Session Manager. For installation and
day-to-day usage, see `README.md`. For the short pointer Claude Code itself reads,
see `CLAUDE.md`.

This document is split into two parts: **Requirements** (what ASM does) and
**Design Notes** (why it's built this way, including alternatives that were
considered and rejected).

## Codex integration notes (Phase 0 spike, 2026-08-30)

Empirically verified against the live install (`codex-cli 0.150.1`) and its
Rust source (`hooks/` and `app-server*` crates), using a scratch `CODEX_HOME`
so the user's real `~/.codex/config.toml` was never touched. Confirmed via
`grep -c asmspike ~/.codex/config.toml` = 0 after the spike.

1. **Hook payload delivery matches Claude Code exactly.** Codex hooks receive
   context as **stdin JSON** with the same field names
   `lifecycle_generation.sh` already reads: `session_id`, `transcript_path`,
   `cwd` (plus Codex-only extras: `hook_event_name`, `model`,
   `permission_mode`, `source`/`reason`). Verified live: a `SessionStart` and
   a `SessionEnd` invocation both produced exactly
   `{"session_id":...,"transcript_path":...,"cwd":...,"hook_event_name":...}`
   on stdin. **`lifecycle_generation.sh` needs no changes at all** for Codex
   — the existing `jq`/`python3` stdin parsing already extracts the three
   fields it uses. This simplifies Phase 4 considerably (no wrapper script
   needed).

2. **Plugin registration should go through `codex plugin` subcommands, not
   hand-written TOML.** `codex plugin marketplace add <dir>` and
   `codex plugin add <name>@<marketplace>` are real, non-interactive,
   scriptable CLI commands that write the `[marketplaces.x]`/`[plugins."x"]`
   sections themselves — verified live. This avoids the TOML-writer problem
   entirely (Python's stdlib `tomllib` is read-only) and is simpler than the
   "managed block" text-append approach originally planned for Phase 4.
   **Phase 4 should shell out to these two commands from `install.sh`
   instead of writing TOML directly.**

3. **Hook trust cannot be (and should not be) bypassed by `install.sh`.**
   The trust hash is a custom normalized-identity hash
   (`hooks/src/engine/discovery.rs`), not a simple `sha256(hooks.json)` —
   not something to hand-compute. Verified live: after registering the
   plugin, a plain `codex exec` loaded the hook (visible in a timeout-clamp
   warning) but **silently did not run it** (no `capture.log` entry, no
   `[hooks.state]` written); adding `--dangerously-bypass-hook-trust` made
   it run and populate the payload. That flag is documented as "intended
   only for automation that already vets hook sources" and is a
   per-invocation flag, not something `install.sh` can persist. The only
   trust-exempt config layers (`System`/`Mdm`/`EnterpriseManaged`) are
   admin/enterprise-only — not appropriate for a personal per-user tool.
   **Conclusion: `install.sh` registers the plugin and prints a one-time
   instruction** ("run `codex` once and approve asm's lifecycle hooks when
   prompted") rather than trying to silently bypass Codex's own hook-trust
   security model.

4. **No simple Claude-style live-session file exists for `close` parity.**
   Claude's `close` depends on `~/.claude/sessions/<pid>.json`. Codex has no
   equivalent flat file — `codex agents` ("browse all agent sessions on the
   shared local app-server daemon") is backed by a real daemon
   (`app-server-daemon` crate) speaking a unix-socket IPC protocol
   (`app-server-transport/src/transport/unix_socket.rs`), not a stable
   public CLI surface (`codex agents` has no `--json`/scriptable output).
   Reverse-engineering an internal IPC protocol is disproportionate to this
   feature and fragile across Codex versions. **Confirms the plan's Phase 6
   contingency**: ship the honest "not supported for codex sessions yet"
   message rather than attempting this.

5. **Codex's skill format is SKILL.md-compatible with Claude's** — confirmed
   via `~/.codex/skills/.system/openai-docs/SKILL.md`'s frontmatter
   (`name`/`description`/`metadata` YAML, markdown body below) — same shape
   Claude Code skills use. No format translation needed for Phase 5.

None of these findings invalidate the plan; #2 simplifies Phase 4's
implementation, #3 changes what `install.sh` prints (not what it does), and
#4 confirms (rather than newly discovers) Phase 6's already-planned
contingency.

## Multi-agent backend architecture (as built, Phases 1-6, 2026-08-30)

The refactor added a `Backend` interface (`NamedTuple`: `name`, `scan`,
`parse`, `resolve_working_dir`, `resume_cmd`, `uuid_of`, `supports_close`) in
`src/asm`, with instances registered in `BACKENDS: Dict[str, Backend]`
(`"claude"` always present; `"codex"` added conditionally, based on
`CODEX_ENABLED`). Everything upstream of that interface - `find_sessions`,
`passes_filters`, `format_session_for_fzf`, `host_block`, ranking - is
agent-agnostic by construction: it operates on the index-doc dict only, and
required zero changes to support a second backend.

Each indexed doc carries an additive `agent_type` field (`"claude"` or
`"codex"`, written by `build_doc`), filterable via `--agent` (mirrors
`--host` exactly) and rendered as a colored `[claude]`/`[codex]` tag in the
picker (`agent_block()`).

Per-backend implementations:

| Concern | Claude Code | Codex CLI |
|---|---|---|
| Session files | `~/.claude/projects/<slug>/<uuid>.jsonl` (slug-encoded dir per project) | `~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl` (flat, timestamp-sharded) |
| Transcript line shape | `{type: user/assistant/ai-title/custom-title, ...}` | `{type: session_meta/response_item/event_msg/turn_context/world_state, payload: {...}}` |
| Working dir | Decoded from the project-slug folder name (`_claude_resolve_working_dir`) | Read directly from `session_meta.payload.cwd` - no decoding needed (`_codex_resolve_working_dir`) |
| Titles | Embedded in the transcript (`ai-title`/`custom-title` lines) | Separate append-only log, `~/.codex/session_index.jsonl` (`{id, thread_name, updated_at}`, latest line wins) - `_codex_session_titles()` |
| UUID from filename | Filename stem *is* the UUID (`_claude_uuid_of`) | Regex-extracted from `rollout-<ts>-<uuid>.jsonl` (`_codex_uuid_of`) - the stem is not the bare UUID |
| Resume/fork command | `claude --resume <uuid>` / `claude --resume <uuid> '/rename <title>'` | `codex resume <uuid>` / `codex fork <uuid>` |
| `supports_close` | `True` | `False` (see finding #4 above) |

New settings keys (flat, matching the file's existing style rather than a
nested `agents.{claude,codex}` block originally sketched in the plan):
`codex_sessions_dir` (default `~/.codex/sessions`), `codex_session_index_file`
(default `~/.codex/session_index.jsonl`), `codex_enabled` (`null` =
auto-detect via `codex_sessions_dir` existing; explicit `true`/`false`
overrides). Adding this last one required a fix to `_load_settings`'s merge
loop, which previously had no branch for JSON booleans at all.

### Feature support by agent

| Feature | Claude Code | Codex CLI |
|---|:---:|:---:|
| Reindex / search / unified picker | ✅ | ✅ |
| True resume | ✅ `claude --resume` | ✅ `codex resume` |
| Fork | ✅ | ✅ `codex fork` |
| `--agent`/`--host`/`--print-cmd` | ✅ | ✅ |
| Cross-machine sync (index-only) | ✅ | ✅ - same index, agent-agnostic |
| Lifecycle hooks | ✅ native | ✅ via `codex plugin` (one-time hook-trust approval) |
| `/inject` | ✅ | ✅ |
| `asm close` | ✅ | ❌ descoped - no stable public live-session surface (finding #4); fails with an explicit message rather than a misleading generic one, and is unreachable from the interactive picker since `live_only` filtering keys off Claude's `~/.claude/sessions/*.json` exclusively |

Codex support is entirely additive: if `codex` isn't installed and
`~/.codex/sessions` doesn't exist, `BACKENDS` only ever contains `"claude"`,
and every codex-specific code path is simply never reached.

---

# Part 1: Requirements

A unified tool for tracking, indexing, and resuming Claude Code and Codex CLI
sessions through one picker, with optional index-only visibility across
machines.

## Use Cases

1. **Find and resume a past session by topic**: "I had a session about profiling hallucination rates, what was the slug?" Search by keywords across prompts and get the session instantly.
2. **Cross-machine visibility**: "I was working on this on my VM earlier - is it visible from my laptop?" Search once, from anywhere, and pull a past session's content into a new conversation via `/inject` - not a true resume (see D2/D3 for why that's out of scope), but enough to pick the work back up without SSH-ing over just to remember what you were doing.
3. **Spot what's still open**: `asm resume --state pending` across all your machines to see sessions that started but never got a clean `SessionEnd` - not full crash recovery (see R4/R5's implementation status), but the closest thing available today.

---

## R1: Indexing

Extracts and stores cleaned session content into a searchable JSON index.

**Format:** One JSON file per session (`<uuid>.json`), stored in a single flat folder.

**Index folder:** `~/opt/agent-session-manager/data/indexes/` - a real local directory on each machine, never a mount or symlink to shared storage. Indexing (`asm reindex`) and search (`asm resume`) are entirely local-first and never touch the network by themselves. Multi-machine visibility, if wanted, is provided separately and optionally by `asm-sync` (R6.4), which reconciles two machines' local indexes over SSH - index-only, see R6.4.

**Inputs per session** (R1-R7 below describe the Claude Code path in detail; the equivalent Codex CLI path - `~/.codex/sessions/**/*.jsonl` plus `~/.codex/session_index.jsonl` for titles - is structurally different but produces the same index-doc shape via its own `Backend`, see "Multi-agent backend architecture" above for the field-by-field mapping):
- `~/.claude/projects/<slug>/<uuid>.jsonl` - conversation history written by Claude Code
- `~/opt/agent-session-manager/data/lifecycles/<uuid>.jsonl` - lifecycle events written by `lifecycle_generation.sh` (R2) - flat, keyed by UUID, not co-located with the file above

**Each index file contains:**
- `agent_type`: `"claude"` or `"codex"` - which backend produced this doc
- `session_id`: full UUID
- `custom_title`: set by `--name` or `/rename`; if absent, falls back to Claude Code's own native `ai-title` transcript entry; if neither is present, `"[Empty session]"` or `"Untitled session [prompt]"`
- `working_dir`: original working directory path, stored as an explicit string (never decoded from the slug - see D4)
- `hostname`: machine where the session was created
- `created_at`: timestamp of the first message
- `last_active`: timestamp of the last message
- `tmux_session`, `tmux_pane`, `tmux_window`: populated from lifecycle events
- `session_state`: `pending` (has a `start`/`resume` lifecycle event with no matching `end`) or `exited`
- `conversation`: list of `{role, timestamp, text}` entries - user and assistant turns only; system reminders, XML tags, and tool invocations stripped; tool output text retained

**Incremental updates:** For each `<uuid>.jsonl`, check whether a corresponding `<uuid>.json` exists in the index and has a newer mtime. If yes, skip. If no, re-index. This avoids redundant work on every machine independently; if a remote is configured, `asm-sync` (R6.4) separately reconciles already-built index files between machines rather than re-indexing them.

**Searchability:** Indexed as JSON, queryable with `jq`; keyword search matches against the extracted title/paths/conversation text.

---

## R2: Lifecycle Tracking

Captures session metadata that is absent from `.jsonl` files, via hooks - Claude Code's native hook mechanism, and (if Codex is installed) an equivalent Codex plugin, both calling the same script.

**Script:** `lifecycle_generation.sh` - registered as a `SessionStart`/`SessionEnd` hook for both agents; the payload contract (stdin JSON with `session_id`/`transcript_path`/`cwd`) is byte-for-byte identical between them, confirmed live (see Phase 0 spike notes above), so the script itself needed no per-agent branching. (`SessionResume` does not exist as a hook type in either agent - resume is inferred from sidecar existence at `SessionStart` time.)

**Output:** one sidecar file per session: `~/opt/agent-session-manager/data/lifecycles/<uuid>.jsonl`. Flat, keyed by UUID - not nested under a project slug and not co-located with the corresponding `.jsonl` in `~/.claude/projects/`. This colocation-vs-flat question only matters for lookup convenience (the UUID is always known before the lifecycle path is needed) since `asm-sync` never touches lifecycle files at all (R6.4 is index-only); flat also matches how the index itself is keyed. Append-only, one JSON line per event.

**Each event line contains:**
- `event`: `start`, `resume`, or `end`
- `timestamp`: ISO 8601
- `session_id`: full UUID
- `hostname`: current machine
- `working_dir`: current working directory
- `tmux_session`, `tmux_pane`, `tmux_window`: current tmux context
- `pid`: process ID of the Claude process (Start event only)

The indexer (`asm reindex`) is the sole writer of JSON index files. `lifecycle_generation.sh` writes only to `~/opt/agent-session-manager/data/lifecycles/*.jsonl` sidecars. This separation avoids race conditions.

---

## R3: Search

**Speed is the primary constraint.**

**Keyword search:** grep case-insensitively across all index files, requiring ALL keywords to match (any order, any position in the file).

**Default scope:** sessions from the last 90 days.

**Fuzzy fallback:** if exact keyword search returns zero results, automatically retry with fuzzy matching. No flag required.

**Filters actually implemented in `asm resume`:**
- `--host <hostname>`: filter by machine
- `--agent <claude|codex>`: filter by backend
- `--state <pending|exited>`: session state
- `--tmux <name>`: filter by tmux session name (substring match against `tmux_session`, captured at `SessionStart` - empty for sessions started outside tmux or before the lifecycle hook recorded it)
- `-f/--from-days-ago`, `-u/--until-days-ago`: date range
- `--max-scan`: cap on recent sessions scanned when no keywords are given
- `--print-cmd`: print the resolved resume/fork command instead of executing it

> Earlier design also called for `--dir <path>` and `--all` flags; those were never implemented. Run `asm --help` for the current, authoritative flag list.

**Result format per match:**
- Title (custom title via `/rename`, then Claude Code's native `ai-title`, then a generic untitled placeholder)
- Working directory and hostname
- Last active timestamp
- Matching snippet with its timestamp

**Ranking:** results sorted by recency of last activity, with title matches ranked first (stable sort preserves recency within that group). Multiple keyword hits within one session otherwise break ties by term-frequency density.

---

## R4: Crash Recovery

> **Status: not implemented.** This section describes original design intent. `asm` does not currently ship a crash-recovery command or tmux-layout restore script. The closest available tool today is `asm resume --state pending`, which surfaces sessions with a `start`/`resume` lifecycle event and no matching `end` - useful for spotting what didn't get cleanly closed, but it does not restore a tmux layout automatically.

Depends on R5 (live state tracking).

Provides a script to identify sessions that were running before a crash and restore them.

**Output:** list of orphaned sessions with hostname, tmux session name, custom title, working directory, and last active timestamp.

**Recovery:** based on user selection, generate and optionally exec a recovery script that:
- Restores the tmux layout (session, window, pane)
- Runs `cd <working-dir> && claude --dangerously-skip-permissions --resume <uuid>` per session

**Partial recovery:** if a `.jsonl` file is corrupted or missing, skip that session with a warning.

---

## R5: Live State Tracking

> **Status: partially implemented.** `session_state` (`pending`/`exited`, R1) is computed and usable via `asm resume --state pending`. The PID-liveness confirmation step and a dedicated orphan-detection heuristic/state file described below were never built.

Prerequisite for R4.

Tracks which Claude sessions are currently running, on which machine, in which tmux pane.

**Data sources:** lifecycle events from `~/opt/agent-session-manager/data/lifecycles/*.jsonl` sidecar files. No heartbeat, no scrollback scanning.

**Orphan detection heuristic (as originally designed):** a session is considered orphaned when:
- A `start` event exists with no corresponding `end` event, AND
- `last_active` in the index is older than 2 hours

Optionally: confirm by checking whether the PID recorded in the `start` event is still alive on the recorded hostname (local machine only; cross-machine PID check requires SSH and is out of scope).

**State file** records hostname per entry to support multiple servers.

---

## R6: Execution and Output

### R6.1: Components

| Component | Type | When invoked |
|---|---|---|
| `asm reindex` | Python script | scheduled, as part of `asm-reindex-sync.sh` below |
| `lifecycle_generation.sh` | shell script | Claude Code hooks (SessionStart / SessionEnd), and the Codex plugin below - same script, same trigger events |
| `codex-plugin/` | Codex plugin | registered via `codex plugin`; wires Codex's SessionStart/SessionEnd to `lifecycle_generation.sh` |
| `asm-sync` | shell script | trigger 1: backgrounded on `SessionEnd`; trigger 2: opportunistically at the start of `asm resume`; trigger 3: scheduled, as part of `asm-reindex-sync.sh`; always a no-op if no remote configured |
| `asm-reindex-sync.sh` | shell script | scheduled (`launchd` on macOS, `systemd --user` timer on Linux) - runs `asm reindex` then unconditionally `asm-sync`, reindex failure never skips the sync step |
| `asm` | shell script | terminal, before opening the agent (`asm resume`, `asm reindex`, …) |
| `~/.claude/skills/inject/SKILL.md`, `~/.codex/skills/inject/SKILL.md` | skill | inside an active Claude Code or Codex session |

### R6.2: `asm reindex`

Scans all local session files and writes the local JSON index. Purely local - never touches the network.

- For each backend in `BACKENDS` (`claude`, and `codex` if enabled), scan its session files (`~/.claude/projects/**/<uuid>.jsonl` or `~/.codex/sessions/**/*.jsonl`), first checking `ignore_path_substrings` (`~/opt/agent-session-manager/data/settings.json`) - if the path matches, skip it entirely, before any mtime comparison
- Otherwise, check if `~/opt/agent-session-manager/data/indexes/<uuid>.json` exists and has a newer mtime than the `.jsonl`
- If yes: skip
- If no: read the `.jsonl` (via that backend's `parse`) and the corresponding lifecycle sidecar at `~/opt/agent-session-manager/data/lifecycles/<uuid>.jsonl` (if present), extract fields, write `<uuid>.json` to the index folder with `agent_type` set accordingly
- Writes are atomic (write to temp file, then rename) to avoid partial reads by `asm resume`

### R6.3: `lifecycle_generation.sh`

Registered as a `SessionStart`/`SessionEnd` hook - natively in `~/.claude/settings.json` for Claude Code, and via a `codex plugin` (`asm@asm-local`) for Codex, both invoking this same script unmodified. Start vs resume is inferred from sidecar existence; no `SessionResume` hook exists in either agent.

- Appends one JSON line to `~/opt/agent-session-manager/data/lifecycles/<uuid>.jsonl`
- Creates the file (and `~/opt/agent-session-manager/data/lifecycles/` itself) if it does not exist
- Must complete quickly (hooks block the Claude session start)
- On `SessionEnd`, also triggers `asm reindex --uuid <session_id>` and a backgrounded `asm-sync --push <session_id>` (trigger 1, below)

### R6.4: `asm-sync` (optional, cross-machine, index-only)

Reconciles **only** `~/opt/agent-session-manager/data/indexes/*.json` between the local machine and one remote host over SSH - no shared filesystem, mount, or cloud-storage folder required, and no raw `.jsonl`/lifecycle files are ever transferred. The index already embeds the full conversation (every message, role, timestamp), so nothing needed for search or `/inject` is lost by not syncing the raw files - and since index files are always fully regenerated by `asm reindex` rather than hand-appended, newest-`mtime`-wins is the only reconciliation rule ever needed (no byte-level conflict resolution, unlike raw session logs would require).

**Topology - hub and spoke, not mesh.** SSH connections here are always initiated by whichever machine has `remote_ssh_host` configured (the "spoke"); the target ("hub") never dials out. In this project's actual deployment, the always-reachable VM is the hub (its own `remote_ssh_host` stays empty - nothing to push to, and it likely isn't reachable from outside anyway), and the laptop is a spoke that both pushes and pulls, so it gets full visibility too, not just the hub.

- Configured in `~/opt/agent-session-manager/data/settings.json`: `remote_ssh_host`, `remote_ssh_user`, `remote_ssh_port`, `remote_index_dir` (path on the remote). If `remote_ssh_host` is empty, `asm-sync` exits silently - sync is entirely optional, and this is how a hub machine opts out of ever pushing/pulling.
- Transport is `ssh`/`rsync`. One SSH round trip builds a manifest (path, size, mtime) of the remote's index files; new-on-one-side files are pushed/pulled in a single batched `rsync`; files present on both sides use newest-mtime-wins, no fetch-and-compare needed.
- `asm-sync [uuid]` syncs one session's index entry (bidirectional); `asm-sync` with no argument syncs the whole index dir; `--push`/`--pull` restrict direction; `--check` is a dry run.
- Does **not** attempt to alias project-folder slugs between machines the way a shared-mount setup would - see D2/D3 for why that doesn't apply without a shared filesystem, and why a synced session always falls back to `/inject` rather than true resume (which was never in scope for index-only sync anyway).

**Offline resilience.** Every real (non-`--check`) run that gets far enough to attempt the SSH reachability check appends one line to `~/opt/agent-session-manager/data/sync-log.jsonl`: `{"timestamp": ..., "outcome": "success", "synced": N, "errors": N}` or `{"timestamp": ..., "outcome": "unreachable"}`. A spoke machine (laptop, working intermittently offline) is expected to fail this regularly and harmlessly - `asm-sync` always exits cleanly either way, never treats "can't reach the remote right now" as a fatal error. `asm resume` (R6.5) reads this log to warn when the local index hasn't successfully synced in a while, rather than silently searching stale data with no indication.

**Three triggers, kept independent on purpose** (separate failure modes, easy to tell apart in logs):
1. `SessionEnd` hook - reindex the session that just ended, push its one index entry. Backgrounded, non-blocking.
2. Start of `asm resume` - rate-limited (skipped if attempted <60s ago) opportunistic pull, hard-capped at a few seconds via a subprocess timeout, wrapped so it can never crash or hang the interactive command.
3. `asm-reindex-sync.sh`, scheduled (`launchd`/`systemd --user timer`, every 30 min) - `asm reindex` then unconditionally `asm-sync` (both directions). Reindex failing must never skip the sync step, so this wrapper explicitly ignores reindex's exit status rather than chaining under `set -e`.

### R6.5: `asm resume`

Main entry point for finding and resuming a past session from the terminal.

**Usage:** `asm resume "keyword1 keyword2"`

**Flow:**
1. If a remote is configured (R6.4): opportunistic rate-limited pull (trigger 2), then check `~/opt/agent-session-manager/data/sync-log.jsonl` for the last successful sync - if missing or older than `sync_stale_warning_hours` (default 24, `~/opt/agent-session-manager/data/settings.json`), print a one-line `⚠` warning before results. Both steps are skipped entirely, silently, if no remote is configured.
2. Runs the search (R3) against the index
3. Opens `fzf` with matching sessions - showing title, hostname, last active timestamp, matching snippet
4. User picks a session
5. Reads the original working directory from the index file (see R1), and dispatches to the doc's `agent_type` backend for step 6
6. If the working directory exists on this machine:
    - exec `cd <original-dir> && claude --dangerously-skip-permissions --resume <uuid>` (Claude) or `cd <original-dir> && codex resume <uuid>` (Codex) - **true resume**, appends to the original `.jsonl`
7. If the working directory does not exist on this machine (e.g. a session synced from another machine, whose absolute path doesn't exist here - the expected case for any cross-machine session, since true resume was never a goal of index-only sync):
    - Print yellow WARNING: session cannot be truly resumed from this machine
    - Print: `Open Claude Code or Codex and invoke the /inject skill with <uuid>`

### R6.6: `/inject`

Skill for context injection when true resume is not possible, identical content installed for both agents.

- Invoked inside an active session via `~/.claude/skills/inject/SKILL.md` (Claude Code) or `~/.codex/skills/inject/SKILL.md` (Codex, if detected) - Codex triggers skills by name/description match rather than Claude's `/inject <arg>` slash-command syntax, so the skill's own instructions describe both invocation styles
- **Usage:** `/inject <uuid>` (Claude Code) or a plain-text mention of the skill plus the uuid/keywords (Codex), or `/inject "<custom title>"` (fuzzy match against index if title provided)
- Loads the session content from the index and injects it into the current conversation - works the same regardless of whether the target session's `agent_type` is claude or codex, since the index already normalized both into the same conversation shape
- **Not a true resume:** creates a new `.jsonl` for the current session; the original session history is not extended

---

## R7: File Inventory

### Scripts

| File | Purpose |
|---|---|
| `asm` (`reindex`/`resume`) | R1/R6.2/R6.5: reads Claude Code `.jsonl` and Codex `.jsonl` via the `BACKENDS` registry + `~/opt/agent-session-manager/data/lifecycles/*.jsonl`, writes JSON index; search + fzf + exec resume/fork command |
| `lifecycle_generation.sh` | R2: hook body, shared verbatim by both Claude Code's native hook and the Codex plugin below; writes `~/opt/agent-session-manager/data/lifecycles/<uuid>.jsonl` sidecar files |
| `asm-sync` | R6.4: optional SSH-based sync of `~/opt/agent-session-manager/data/indexes/` only, between two machines (agent-agnostic - syncs both backends' index entries identically) |
| `asm-reindex-sync.sh` | R6.4: scheduled wrapper - `asm reindex` then unconditionally `asm-sync` |
| `codex-plugin/` (`.codex-plugin/plugin.json` + `hooks/hooks.json`) | R2: Codex plugin manifest, registered as `asm@asm-local` - wires the same `lifecycle_generation.sh` into Codex's `SessionStart`/`SessionEnd` |
| `~/.claude/skills/inject/SKILL.md`, `~/.codex/skills/inject/SKILL.md` (if Codex detected) | R6.6: skill for context injection, identical content for both agents |

### Scheduler config

| Device | Files | Purpose |
|---|---|---|
| macOS | `~/Library/LaunchAgents/com.asm.reindex-sync.plist` | runs `asm-reindex-sync.sh` every 30 min via `launchd` |
| Linux | `~/.config/systemd/user/com.asm.reindex-sync.{service,timer}` | same, via `systemd --user` timer (`OnCalendar=*:0/30`) |

The Linux unit files use systemd's native `%h` home-directory specifier, so unlike the macOS `.plist` they need no `sed` templating at install time. `install.sh` also best-effort runs `loginctl enable-linger` on Linux - without it, the user's systemd instance (and thus the timer) may only run while a session/SSH login is active, which matters for a VM you don't keep permanently logged into.

Claude Code hook registration in `~/.claude/settings.json`:
```json
"hooks": {
  "SessionStart": [{"type": "command", "command": "HOOK_EVENT=start /path/to/lifecycle_generation.sh"}],
  "SessionEnd":   [{"type": "command", "command": "HOOK_EVENT=end   /path/to/lifecycle_generation.sh"}]
}
```

Codex hook registration (if detected) goes through `codex plugin marketplace add`/`codex plugin add asm@asm-local` instead of a hand-written config block - see the Phase 0 spike notes above for why. The `hooks/hooks.json` payload wires the identical `SessionStart`/`SessionEnd` events to the same `lifecycle_generation.sh`, unmodified. Codex requires a one-time interactive hook-trust approval on first use; `install.sh` cannot bypass this (see finding #3 above) and prints a reminder instead.

### Data files

| File | Written by | Synced by asm-sync? |
|---|---|---|
| `~/opt/agent-session-manager/data/indexes/<uuid>.json` | `asm reindex` | yes, if a remote is configured |
| `~/opt/agent-session-manager/data/lifecycles/<uuid>.jsonl` | `lifecycle_generation.sh` | no - never synced (see R6.4) |
| `~/opt/agent-session-manager/data/settings.json` | user-edited / created by `install.sh` | no |
| `~/opt/agent-session-manager/data/sync-log.jsonl` | `asm-sync` | no - local-only record of sync attempts |

### Filesystem structure (one-time setup per machine)

Every machine is fully local and self-contained - no mounts, no symlinks to shared storage. What ASM owns lives under `~/opt/agent-session-manager/` (code and data together, per this machine's `~/opt/<project>/` convention); what Claude Code and Codex each own stays under their own dotfile dir (`~/.claude/`, `~/.codex/`) - ASM never relocates those, it only reads their session files and adds its own skill/hook registration alongside them:

| Path | What it is |
|---|---|
| `~/.claude/projects/` | real local directory (written directly by Claude Code) |
| `~/.codex/sessions/` | real local directory (written directly by Codex CLI, if installed) |
| `~/opt/agent-session-manager/data/indexes/` | real local directory (written by `asm reindex`, both backends' entries mixed together) |
| `~/opt/agent-session-manager/data/lifecycles/` | real local directory (written by `lifecycle_generation.sh`, shared by both agents' hooks) |
| `~/opt/agent-session-manager/data/settings.json` | ASM's own settings |
| `~/opt/agent-session-manager/data/sync-log.jsonl` | append-only sync-attempt log |
| `~/opt/agent-session-manager/` | canonical deployment location - `bin/{asm,asm-sync,status}`, `lifecycle_generation.sh`, `asm-reindex-sync.sh`, `codex-plugin/`, `install.sh`/`uninstall.sh` copies, and `data/` (above) |
| `~/.local/bin/{asm,asm-sync,status}` | symlinks into `~/opt/agent-session-manager/bin/` - the only thing on `$PATH`, never real files |

`uninstall.sh` removes everything under `~/opt/agent-session-manager/` **except** `data/`, since code and data now share one parent directory - see its own header comment.

`asm-sync` (optional) reconciles `~/opt/agent-session-manager/data/indexes/` with the equivalent directory on one remote host over SSH - see R6.4. There is no per-platform slug-aliasing setup step; that only made sense when multiple machines shared one mounted folder.

---

# Part 2: Design Notes

Rationale, constraints, and rejected alternatives behind the decisions in Part 1.

---

## D0: Background

This project originally merged two prior tools: a hook-based lifecycle-logging +
tmux-state-snapshot script, and a separate prompt-indexing/search script. Those
two roles now correspond to `lifecycle_generation.sh` (R2) and `asm reindex` (R6.2)
respectively.

---

## D1: Why `claude --resume` requires the original working directory

Claude Code stores session `.jsonl` files in a folder whose name is a slug derived from the absolute path of the working directory at session start:

```
/home/jeanlescut/some-project/  -->  ~/.claude/projects/-home-jeanlescut-some-project/
```

When `claude --resume <uuid>` is invoked, it looks for `<uuid>.jsonl` only inside the project folder matching the **current** working directory. A session started in `folderA` cannot be resumed from `folderB`, even on the same machine. The resume command must always be prefixed with a `cd`:

```bash
cd /original/working/directory && claude --dangerously-skip-permissions --resume <uuid>
```

This is why `asm resume` reads the original working directory from the index (stored explicitly) and always emits a `cd` prefix.

---

## D2: Why cross-machine resume is non-trivial

There is no shared filesystem between machines: a laptop and a personal VM each have their own independent `~/.claude/projects/`, and `asm-sync` (R6.4) only moves *file contents* between them over SSH - it does not make the two machines see the same absolute paths.

A session's project folder slug is derived from the absolute working directory it was started in, and that path is essentially never the same on two different machines:

```
laptop: ~/.claude/projects/-Users-jeanlescut-some-project/
VM:     ~/.claude/projects/-home-vmuser-some-project/
```

Even after `asm-sync` copies a session's `.jsonl` from the VM to the laptop, `claude --resume <uuid>` on the laptop still looks for it inside the slug folder matching the laptop's *current* working directory - it has no way to know the file came from a differently-named directory on another machine. You cannot `cd /home/vmuser/...` from the laptop, and the laptop's own equivalent directory (if any) would produce a different slug anyway.

This is a fundamentally different failure mode from a same-account macOS-vs-Linux case (same underlying directory, different slug because of a fixed `/Users` vs `/home` prefix): here it's two genuinely distinct machines with no relationship between their directory layouts at all. There is no prefix-swapping fix for that - see D3.

---

## D3: Rejected strategies for cross-machine path resolution

Strategies A-E below all presuppose that both machines can see the *same underlying
directory* somehow (a mounted network drive, a synced cloud-storage folder) so that
a symlink or file placed by one machine is immediately visible to the other. That
premise doesn't hold for a laptop + a personal VM with no shared filesystem, where
the only channel between the two machines is SSH. Strategy F, at the end, is what
`asm-sync` actually does today.

### Strategy A: Move the `.jsonl` (`mv`)

Migrate the session file from the source machine's project folder to the target machine's folder before resuming.

**Rejected because:**
1. Ping-pong: session starts on Linux, migrated to Mac folder on resume, migrated back to Linux folder on next resume, indefinitely.
2. Race condition: if two machines attempt to resume simultaneously, one machine moves the file while the other is actively appending to it, causing lost writes or a crash.

### Strategy B: Copy the `.jsonl` (`cp`)

Copy the session file into the target machine's project folder.

**Rejected because:** creates two independent `.jsonl` files that immediately diverge. Messages appended on one machine are not reflected on the other. There is no canonical version and no way to merge.

### Strategy C: Symlink individual `.jsonl` files

Create a symlink in the target machine's project folder pointing to the canonical file:

```
-Users-jeanlescut-shared-project/<uuid>.jsonl
  --> -home-jeanlescut-shared-project/<uuid>.jsonl
```

Both machines read and write to the same file. No duplication, no divergence.

**Rejected because:** requires one symlink per session. Every new session needs a new symlink. Does not scale and requires per-session scripted maintenance.

### Strategy D: Symlink entire project folders (superseded)

Symlink the entire platform-specific slug folder to the canonical slug folder on a
shared mount:

```
-Users-jeanlescut-shared-project/  -->  -home-jeanlescut-shared-project/  (canonical, on the shared mount)
```

Any session created on one machine writes its `.jsonl` through the symlink into
the canonical folder on the shared mount; the other machine writes there directly.
Both machines always see the same files, and all future sessions in that directory
are covered automatically with no per-session action needed.

**This was an earlier design**, viable only because `~/.claude/projects/` on both
machines could resolve into one shared, mounted folder. It required
`~/.claude/projects/` to be a real local directory (not itself a mount symlink) with
per-slug symlinks maintained inside it by a scheduled script. **It doesn't apply
without a shared mount** - there is no folder for either machine's alias symlink to
point at. See Strategy F.

### Strategy E: System-level base folder symlink

Create `/Users/jeanlescut --> /home/vmuser` on the VM and the reverse on the laptop,
so that paths appear identical on both machines.

**Rejected because:** when the user runs `cd /home/vmuser/...` on the laptop via the
symlink, the shell resolves the symlink and the real working directory becomes
`/Users/jeanlescut/...`. Claude Code encodes the project folder slug from the
resolved path, not the symlink path. The slug produced is still
`-Users-jeanlescut-...`. The benefit is lost entirely. (This also does nothing about
the underlying problem: even with identical-looking paths, the two machines still
don't share a filesystem, so the directories' actual *contents* would still need a
sync mechanism - which is Strategy F.)

### Strategy F: Independent local storage + SSH index sync (current approach)

Give up on making the two machines' paths or project folders resolve to "the same"
anything. Each machine keeps a fully independent, real `~/.claude/projects/` (Claude
Code's own, untouched) and `~/opt/agent-session-manager/data/indexes/`. `asm-sync` (R6.4) is the only thing
that ever crosses the machine boundary, and it moves only index-file *contents* over
`ssh`/`rsync` - not the raw `.jsonl` transcripts, not paths, not symlinks.

**Consequences, accepted as the tradeoff:**
- A session synced from another machine essentially never has a working directory
  that exists locally (see D2), so `asm resume` cannot exec a true `claude --resume`
  for it. It correctly detects this and points the user at `/inject <uuid>` instead
  (D5) - a deliberate, expected fallback, not a bug, and not something index-only
  sync ever tried to fix.
- No slug-aliasing setup step is needed on either machine, at install time or ever.
- Sync is purely optional and additive: nothing about local indexing or resume
  depends on `asm-sync` being configured or reachable.
- Layered on top: a hub-and-spoke topology (not a mesh) - the reliably-reachable
  machine is the hub and never configures `remote_ssh_host`, other machines are
  spokes that dial out to it. See R6.4 for why (SSH connections are always
  initiated by the spoke; a typical home laptop isn't reachable from a VM).

---

## D4: Why slug decoding is unreliable and paths must be stored explicitly

The project folder slug encodes `/` as `-`. Decoding reverses this: prepend `/` and replace `-` with `/`. This is ambiguous: a directory named `my-project` contains a `-` that is indistinguishable from a path separator in the slug. For example:

```
-home-jeanlescut-my-project-notes/
```

Could decode to `/home/jeanlescut/my-project/notes/` or `/home/jeanlescut/my/project/notes/` or other variants.

The index (R1) must store the original working directory path as an explicit string field so that `asm resume` never needs to decode slugs.

---

## D5: Why context injection (`/inject`) must run inside Claude, not as a CLI flag

Injecting past session content into a new Claude session from the terminal has no clean mechanism. Claude Code's CLI has no flag for pre-loading a conversation into an interactive session. The `--print` / stdin path only works in non-interactive mode. Writing a fabricated `.jsonl` file to trick `claude --resume` into loading pre-baked history is fragile and unsupported.

The clean separation is:

- `asm resume` (outside Claude) handles **true resume** via `cd <dir> && claude --dangerously-skip-permissions --resume <uuid>`
- `/inject` (inside Claude) handles **context injection** when true resume is not possible

When `asm resume` detects that the original working directory does not exist on the current machine, it prints the UUID and instructs the user to open Claude and run `/inject <uuid>`.
