#!/usr/bin/env bash
# uninstall.sh - Agent Session Manager
#
# Removes all installed ASM artifacts. Does NOT touch:
#   - This source folder
#   - Session history (.jsonl files in ~/.claude/projects/ or ~/.codex/sessions/)
#   - ~/opt/agent-session-manager/data/ (index, settings, lifecycle sidecars, sync log)
#
# Run: bash uninstall.sh   (from the repo root)
# Or:  ~/opt/agent-session-manager/uninstall.sh

set -euo pipefail

SERVICE_DIR="$HOME/opt/agent-session-manager"
IS_MACOS=$( [[ "$(uname -s)" == "Darwin" ]] && echo true || echo false )

echo "Uninstalling Agent Session Manager..."
echo ""

# -- Remove scheduled reindex + rsync job -------------------------------------

# Scheduled by smart-orchestrator through a symlink; also clear any former
# launchd / systemd scheduling left by older installs.
if [ -L "$HOME/opt/smart-orchestrator/jobs/asm-reindex-and-rsync.conf" ]; then
    rm -f "$HOME/opt/smart-orchestrator/jobs/asm-reindex-and-rsync.conf"
    echo "  Removed $HOME/opt/smart-orchestrator/jobs/asm-reindex-and-rsync.conf"
fi
for name in com.asm.reindex-sync com.csm.reindex-sync; do
    if $IS_MACOS; then
        plist_path="$HOME/Library/LaunchAgents/$name.plist"
        if [ -e "$plist_path" ] || [ -L "$plist_path" ]; then
            launchctl unload "$plist_path" 2>/dev/null || true
            rm -f "$plist_path"
            echo "  Removed $plist_path"
        fi
    else
        SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
        if command -v systemctl &>/dev/null && [ -e "$SYSTEMD_USER_DIR/$name.timer" ]; then
            systemctl --user disable --now "$name.timer" 2>/dev/null || true
            rm -f "$SYSTEMD_USER_DIR/$name.service" "$SYSTEMD_USER_DIR/$name.timer"
            systemctl --user daemon-reload 2>/dev/null || true
            echo "  Removed $SYSTEMD_USER_DIR/$name.{service,timer}"
        fi
    fi
done

# -- Remove asm, asm-sync, status --------------------------------------------

BIN_DIR="$HOME/.local/bin"
for bin in asm asm-sync status; do
    if [ -f "$BIN_DIR/$bin" ]; then
        rm "$BIN_DIR/$bin"
        echo "  Removed $BIN_DIR/$bin"
    fi
done

# -- Remove inject skill -------------------------------------------------------

if [ -d "$HOME/.claude/skills/inject" ]; then
    rm -rf "$HOME/.claude/skills/inject"
    echo "  Removed ~/.claude/skills/inject/"
fi

if [ -d "$HOME/.codex/skills/inject" ]; then
    rm -rf "$HOME/.codex/skills/inject"
    echo "  Removed ~/.codex/skills/inject/"
fi

# -- Remove info skill ---------------------------------------------------------

if [ -d "$HOME/.claude/skills/info" ]; then
    rm -rf "$HOME/.claude/skills/info"
    echo "  Removed ~/.claude/skills/info/"
fi

# -- Remove lifecycle hooks from settings.json ------------------------------

SETTINGS_JSON="$HOME/.claude/settings.json"
if [ -f "$SETTINGS_JSON" ] && command -v python3 &>/dev/null; then
    python3 - "$SETTINGS_JSON" <<'PYEOF'
import json, sys

settings_path = sys.argv[1]
with open(settings_path) as f:
    settings = json.load(f)

hooks = settings.get("hooks", {})
changed = False
for event_key, identifier in [
    ("SessionStart", "agent-session-manager/lifecycle_generation.sh"),
    ("SessionEnd", "agent-session-manager/lifecycle_generation.sh"),
]:
    existing = hooks.get(event_key, [])
    filtered = [
        g for g in existing
        if not any(identifier in h.get("command", "") for h in g.get("hooks", []))
    ]
    if len(filtered) != len(existing):
        changed = True
        if filtered:
            hooks[event_key] = filtered
        else:
            del hooks[event_key]

if changed:
    if not hooks:
        del settings["hooks"]
    with open(settings_path, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")
PYEOF
    echo "  Removed lifecycle hooks from $SETTINGS_JSON"
fi

# -- Remove Codex plugin (session lifecycle hooks) ---------------------------

if command -v codex &>/dev/null; then
    codex plugin remove asm@asm-local >/dev/null 2>&1 || true
    codex plugin marketplace remove asm-local >/dev/null 2>&1 || true
    echo "  Removed asm@asm-local plugin/marketplace from ~/.codex/config.toml (if present)"
fi

# -- Remove service directory, preserving data/ ------------------------------
# data/ (settings, index, lifecycle sidecars, sync log) lives inside
# $SERVICE_DIR alongside the code/scripts, so this can't just rm -rf the
# whole thing - only the non-data children are removed.

if [ -d "$SERVICE_DIR" ]; then
    find "$SERVICE_DIR" -mindepth 1 -maxdepth 1 ! -name data -exec rm -rf {} +
    echo "  Removed $SERVICE_DIR (kept $SERVICE_DIR/data)"
fi

echo ""
echo "Done. $SERVICE_DIR/data/ (index, settings, lifecycle sidecars, sync log)"
echo "and session history (~/.claude/projects/) were preserved."
echo ""
echo "To also remove ASM's own data (optional):"
echo "  rm -rf $SERVICE_DIR/data"
