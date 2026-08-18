# csm: Claude Session Manager

**A CLI tool that extends Claude Code's session management with cross-directory search, cross-machine sync, session monitoring, and analytics.**

## What Claude Code Provides Natively

Claude Code has built-in session discovery via `/resume` (inside a session) and `claude --resume` (from the CLI). Both open an interactive picker showing sessions with titles, timestamps, and message counts.

However, both are **scoped to the current project directory** (the slug derived from your working directory). This means:

- You can only see sessions started in the folder you are currently in
- You cannot search or resume sessions from a different folder, even on the same machine
- You cannot see sessions from another machine at all
- If you `cd` to a different directory and run `claude --resume`, your previous sessions are invisible

## What csm Adds

csm solves problems that Claude Code's native resume does not address.

### 1. Cross-Directory Session Discovery

Claude Code's `/resume` is blind to sessions outside the current directory. If you ran sessions across 20 different project folders over the past month, you would need to `cd` into each one individually and check `/resume` to find the one you are looking for.

csm indexes **all** local sessions across **all** project directories into a single searchable catalog. You search once, from anywhere, and csm handles the `cd` for you before resuming.

**Full-text keyword search** across the entire conversation content (not just titles). Strict matching first, automatic fuzzy fallback if no exact matches. Filter by hostname, date range, or both.

### 2. Cross-Machine Sync (optional)

csm is **local-first**: everything it writes lives on local disk, and it works fully offline with no remote configured. If you also work from a second machine (a personal VM, a devserver, another laptop) with no shared filesystem between them, `csm-sync` optionally syncs session files and the index over plain SSH - no mounted drive, no cloud-storage folder required.

- Configure a remote host once in `~/.claude/csm-settings.json` (`remote_ssh_host`, `remote_ssh_user`, `remote_ssh_port`, and the remote-side paths).
- `csm-sync` reconciles session files (`.jsonl` + `.lifecycle.jsonl`) and index files (`.json`) between the two machines using `rsync` over `ssh`. Byte-level conflict detection (`cmp`) handles the case where the same append-only session file was written to on both machines: it keeps the larger/more-complete version and saves the divergent lines from the other side to a local `.extra-*` file for manual recovery.
- The lifecycle hook automatically pushes a session's files to the remote on `SessionEnd`, so a session becomes visible on the other machine shortly after you close it - no need to wait for a scheduled sync.
- If no remote is configured, `csm-sync` exits silently. Nothing about local indexing or resume depends on it.

**What sync does *not* give you**: a shared filesystem. Claude Code derives its project-folder slug from the absolute working directory path, and a session started on one machine will almost never have a matching directory on the other (different absolute paths entirely, e.g. a laptop `/Users/...` project vs a VM `/home/...` project). So a session synced from another machine typically cannot be **truly resumed** in place - `csm resume` will detect this and tell you to run `/inject <uuid>` instead, which loads the session's content into a new conversation as context rather than extending the original transcript. See `DEV_DOC.md` (D2/D3) for the full rationale.

### 3. Session Monitoring and Analytics

The JSON index stores structured metadata for every session: conversation messages with timestamps, hostname, working directory, tmux context, session state, and titles. This enables:

- **Monitoring sessions across machines**: see what's running, what exited, what was last active when, on which host
- **Prompt and character counting**: each message is stored with role, timestamp, and full text, queryable with `jq`
- **tmux layout tracking**: which tmux session, window, and pane each Claude session was running in

## Key Features

| Feature | Native `/resume` | csm |
|---|---|---|
| Interactive picker | ✅ Yes (built-in) | ✅ Yes (fzf) |
| Search by title | ✅ Yes (picker filter) | ✅ Yes |
| Search by conversation content | ❌ No | ✅ Yes (full-text keyword search) |
| See sessions from other directories | ❌ No | ✅ Yes |
| Resume from a different directory | ❌ No | ✅ Yes (auto-cd to original dir) |
| See sessions from other machines | ❌ No | ✅ Yes (optional SSH sync) |
| LLM-generated titles | ❌ No (only user-set names) | ✅ Yes, if the autoname plugin is installed (skipped gracefully otherwise) |
| Hostname/date filtering | ❌ No | ✅ Yes |
| Session state tracking | ❌ No | ✅ Yes (pending/exited) |
| Prompt/character analytics | ❌ No | ✅ Yes (full conversation stored in JSON index) |
| Fuzzy search fallback | ❌ No | ✅ Yes |

## How It Works

```
   ~/.claude/projects/*/                       ~/.claude/projects/*/
   *.jsonl + *.lifecycle.jsonl                 *.jsonl + *.lifecycle.jsonl
   (machine A)                                 (machine B)
          |                                             |
   csm reindex (scheduled)                      csm reindex (scheduled)
          |                                             |
   ~/.claude/session-index-local/*.json  <--ssh/rsync--> ~/.claude/session-index-local/*.json
   (local index, source of truth for A)      csm-sync    (local index, source of truth for B)
          |
   csm resume (interactive, fzf picker + claude --resume)
```

Everything is local-first: `csm reindex` and `csm resume` never touch the network. `csm-sync` is a separate, optional step that reconciles two machines' local state over SSH.

### Lifecycle Hooks

csm registers Claude Code hooks for `SessionStart` and `SessionEnd` events. These write `.lifecycle.jsonl` sidecar files that capture metadata absent from conversation logs: hostname, tmux pane, working directory, PID, session state. On `SessionEnd`, the hook also reindexes that session and (if a remote is configured) pushes it via `csm-sync` in the background.

## Usage

### `csm resume` - find and resume a past session

```bash
csm resume                          # browse recent sessions, no keywords
csm resume profiling hallucination  # full-text keyword search (fuzzy fallback if no exact match)

# Filters
csm resume --host myserver          # only sessions from a given hostname
csm resume --state pending          # pending (no matching SessionEnd yet) or exited
csm resume -f 30                    # only active in the last 30 days (default: 90)
csm resume -u 7                     # only active more than 7 days ago
csm resume --max-scan 200           # recent sessions scanned when no keywords given (default: 50)

# Resume behavior
csm resume --fork                   # fork into a new session instead of resuming in place
csm resume -v                       # verbose logging (timestamps on stderr)
```

### `csm reindex` - rebuild the local JSON index

```bash
csm reindex                # incremental: only sessions changed since the last index
csm reindex -n 5           # cap at 5 sessions this run
csm reindex --force        # reindex everything + retry title generation on orphaned entries
csm reindex --uuid <uuid>  # reindex a single session (what the SessionEnd hook calls internally)
```

### `csm-sync` - optional cross-machine sync (no-op if no remote is configured)

```bash
csm-sync                 # bidirectional sync, all sessions
csm-sync <uuid>           # sync a single session
csm-sync --push [uuid]    # local → remote only
csm-sync --pull [uuid]    # remote → local only
csm-sync --check [uuid]   # dry run - report what would sync, without copying
```

### Other

```bash
csm --version   # show version
csm --help      # show all flags
! status        # (from inside Claude Code) current session's title, tokens, cost, model
```

## Installation

```bash
git clone <repo-url>
cd claude-session-manager
bash install.sh
```

Installs `csm`, `csm-sync`, and `status` to `~/.local/bin/`, registers the `SessionStart`/`SessionEnd` lifecycle hooks in `~/.claude/settings.json`, installs the `/inject` skill, and (on macOS) sets up a `launchd` job for scheduled reindexing. Requires `fzf`. If `~/.local/bin` isn't already on your `$PATH`, `install.sh` will tell you.

## Settings (`~/.claude/csm-settings.json`)

Created by `install.sh` on first install, never overwritten afterward. All keys are optional except that sync requires the `remote_ssh_*` ones to be filled in.

| Key | Default | Purpose |
|---|---|---|
| `local_projects_dir` | `~/.claude/projects` | Where Claude Code writes session files locally |
| `local_index_dir` | `~/.claude/session-index-local` | Where `csm reindex` writes the JSON index locally |
| `ignore_path_substrings` | `[]` | List of substrings; any `.jsonl` whose path contains one is skipped entirely during reindex. Use this to exclude sessions from a specific tool, bot, or scratch directory (e.g. `["/agent-scratch/"]`) without a code change. |
| `remote_ssh_host` | `""` | VM/devserver hostname or IP. Empty ⇒ `csm-sync` exits silently, sync is fully optional |
| `remote_ssh_user` | `""` | SSH user on the remote |
| `remote_ssh_port` | `"22"` | SSH port |
| `remote_projects_dir` | `~/.claude/projects` | Path **on the remote machine** |
| `remote_index_dir` | `~/.claude/session-index-local` | Path **on the remote machine** |

To enable cross-machine sync, fill in the `remote_ssh_*` keys and run the same `install.sh` on the other machine too.

## Important: Extend Session Retention

Claude Code **deletes session `.jsonl` files after 30 days by default**. Once deleted, sessions can no longer be resumed (csm will show them as `[Deleted]` in the picker). To prevent this, add to `~/.claude/settings.json` on **every machine**:

```json
{
  "cleanupPeriodDays": 365
}
```

This must be set on each machine independently.

## Technical Details

- Pure Python (stdlib only, no pip dependencies) for `csm`; plain Bash for `csm-sync` and the lifecycle hook
- Parallel reindexing with 10 concurrent workers
- Incremental: skips sessions unchanged since last index (mtime comparison)
- Optional LLM title generation via a separate autoname plugin (skipped gracefully if not installed)
- Atomic file writes (tempfile + os.replace) for crash safety
- JSON index format, queryable with `jq` for ad hoc analysis
- Resume search completes in well under a second from local disk
