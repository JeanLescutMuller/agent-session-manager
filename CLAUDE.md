# Claude Session Manager (CSM)

CLI tool for indexing, searching, and resuming Claude Code sessions across machines.

- Requirements and design rationale: `DEV_DOC.md`
- Installation and day-to-day usage: `README.md`

## Folder Structure

```
claude-session-manager/
├-- CLAUDE.md              # this file
├-- DEV_DOC.md             # requirements + design notes
├-- README.md              # user-facing documentation
├-- install.sh             # installs all artifacts to system locations
├-- uninstall.sh           # reverses install.sh
│
├-- src/                    # source files deployed by install.sh
│   ├-- csm                 # the CLI executable (Python, stdlib only, local-only)
│   ├-- csm-sync             # optional sync script (Bash, SSH/rsync to a remote host)
│   ├-- csm-settings.json    # settings template
│   ├-- status               # standalone session info script
│   ├-- inject/              # /inject skill for Claude Code
│   │   └-- SKILL.md
│   ├-- lifecycle_generation.sh  # session lifecycle hook (cross-platform)
│   │
│   ├-- macos/               # macOS-specific: LaunchAgents
│   │   └-- com.csm.reindex.plist
```

## Key Concepts

- **Local-first**: `csm` works entirely on local disk. No shared filesystem or mount is assumed. All runtime writes (JSONL, lifecycle) go to `~/.claude/projects/` on local disk.
- **Optional sync**: `csm-sync` is a separate script that syncs local ↔ a remote host over SSH/rsync (no shared mount required). Uses `cmp` for byte-level conflict detection. Exits silently if not configured.
- **Title pipeline**: custom title (from `/rename`) > autoname plugin (`session-autoname.py`, called during reindex) > "Untitled session" (autoname is optional and skipped gracefully if not installed).
- **Pure Python, stdlib only**: no pip dependencies. Uses `json`, `pathlib`, `subprocess`, `argparse`.
- **Mtime-based skip**: only reindexes sessions whose `.jsonl` mtime is newer than the index `.json` mtime.

## Install / Update / Uninstall

```bash
# Install (first time)
bash install.sh

# Re-install after editing (from deployed copy)
~/services/claude_session_manager/install.sh

# Uninstall
bash uninstall.sh
```

## Installed Locations

| Artifact | Destination | Platform |
|----------|-------------|----------|
| `csm` | `~/.local/bin/csm` | All |
| `csm-sync` | `~/.local/bin/csm-sync` | All |
| `status` | `~/.local/bin/status` | All |
| `csm-settings.json` | `~/.claude/csm-settings.json` | All |
| `inject/SKILL.md` | `~/.claude/skills/inject/SKILL.md` | All |
| `lifecycle_generation.sh` | `~/services/claude_session_manager/` | All |
| `install.sh`, `uninstall.sh` | `~/services/claude_session_manager/` | All |
| Lifecycle hooks | `~/.claude/settings.json` (auto-registered) | All |
| LaunchAgent plists | `~/Library/LaunchAgents/` | macOS |
