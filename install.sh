#!/usr/bin/env bash
# install.sh - Claude Session Manager
#
# Installs CSM from this source checkout to system locations:
#   ~/opt/claude_session_manager/bin/     - canonical deployment: csm, csm-sync, status
#   ~/.local/bin/                         - PATH entry points, symlinked into the above
#   ~/.claude/skills/inject/SKILL.md      - /inject skill
#   ~/opt/claude_session_manager/         - service scripts + logs (canonical location)
#   ~/.csm/                               - settings, index, lifecycle sidecars, sync log
#   ~/Library/LaunchAgents/ (macOS) or
#     ~/.config/systemd/user/ (Linux)     - scheduled reindex + sync
#   ~/.claude/settings.json               - lifecycle hooks (auto-registered)
#
# First install:
#   git clone <repo-url> && cd claude-session-manager && bash install.sh
#
# Re-install after update (from deployed copy):
#   ~/opt/claude_session_manager/install.sh

set -euo pipefail

# Resolve source directory (where this script lives)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/src"
MACOS_DIR="$SRC_DIR/macos"
LINUX_DIR="$SRC_DIR/linux"

SERVICE_DIR="$HOME/opt/claude_session_manager"
SETTINGS_JSON="$HOME/.claude/settings.json"
IS_MACOS=$( [[ "$(uname -s)" == "Darwin" ]] && echo true || echo false )

echo "Installing Claude Session Manager..."
echo ""

# -- Pre-flight: check fzf and python3 ---------------------------------------
# python3 isn't optional: csm itself is a Python script (see src/csm's shebang),
# and this installer uses it once to safely edit ~/.claude/settings.json's JSON.

if ! command -v fzf &>/dev/null; then
    echo "ERROR: fzf is required but not installed."
    if $IS_MACOS; then
        echo "  Install it with: brew install fzf"
    else
        echo "  Install it with your package manager, e.g.: apt install fzf / dnf install fzf / pacman -S fzf"
    fi
    exit 1
fi

if ! command -v python3 &>/dev/null; then
    echo "ERROR: python3 is required but not installed."
    if $IS_MACOS; then
        echo "  Install it with: brew install python3"
    else
        echo "  Install it with your package manager, e.g.: apt install python3 / dnf install python3 / pacman -S python"
    fi
    exit 1
fi

# -- One-time migration: ~/.claude/{csm-settings.json,session-index-local,   --
# -- *.lifecycle.jsonl} -> ~/.csm/ (no-op on a fresh install / already done) --

mkdir -p "$HOME/.csm"

if [ -f "$HOME/.claude/csm-settings.json" ] && [ ! -f "$HOME/.csm/settings.json" ]; then
    mv "$HOME/.claude/csm-settings.json" "$HOME/.csm/settings.json"
    # The moved file still has old-format values (e.g. local_index_dir pointing
    # at the old ~/.claude location) - fix those up in place, don't just move
    # the file and leave it pointing at paths that no longer hold the data.
    python3 - "$HOME/.csm/settings.json" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as f:
    s = json.load(f)
s["local_index_dir"] = "~/.csm/indexes"
s.setdefault("lifecycle_dir", "~/.csm/lifecycles")
s.setdefault("sync_stale_warning_hours", 24)
s.setdefault("ignore_path_substrings", [])
if s.get("remote_index_dir") in ("~/.claude/session-index-local", ""):
    s["remote_index_dir"] = "~/.csm/indexes"
s.pop("remote_projects_dir", None)
with open(path, "w") as f:
    json.dump(s, f, indent=2)
    f.write("\n")
PYEOF
    echo "  Migrated ~/.claude/csm-settings.json -> ~/.csm/settings.json (paths updated)"
fi

if [ -d "$HOME/.claude/session-index-local" ] && [ ! -d "$HOME/.csm/indexes" ]; then
    mv "$HOME/.claude/session-index-local" "$HOME/.csm/indexes"
    echo "  Migrated ~/.claude/session-index-local/ -> ~/.csm/indexes/"
fi

if [ -d "$HOME/.claude/projects" ]; then
    MIGRATED_LC=0
    while IFS= read -r -d '' f; do
        mkdir -p "$HOME/.csm/lifecycles"
        uuid=$(basename "$f" .lifecycle.jsonl)
        dest="$HOME/.csm/lifecycles/${uuid}.jsonl"
        if [ ! -f "$dest" ]; then
            mv "$f" "$dest"
            MIGRATED_LC=$((MIGRATED_LC + 1))
        fi
    done < <(find "$HOME/.claude/projects" -name '*.lifecycle.jsonl' -print0 2>/dev/null)
    [ "$MIGRATED_LC" -gt 0 ] && echo "  Migrated $MIGRATED_LC lifecycle sidecar(s) -> ~/.csm/lifecycles/"
fi

# -- Service scripts -> ~/opt/claude_session_manager/ ----------

mkdir -p "$SERVICE_DIR"

# Cross-platform: lifecycle hook, scheduled reindex+sync wrapper, install/uninstall
cp "$SRC_DIR/lifecycle_generation.sh" "$SERVICE_DIR/lifecycle_generation.sh"
chmod +x "$SERVICE_DIR/lifecycle_generation.sh"
echo "  $SERVICE_DIR/lifecycle_generation.sh"

cp "$SRC_DIR/csm-reindex-sync.sh" "$SERVICE_DIR/csm-reindex-sync.sh"
chmod +x "$SERVICE_DIR/csm-reindex-sync.sh"
echo "  $SERVICE_DIR/csm-reindex-sync.sh"

for script in install.sh uninstall.sh; do
    cp "$SCRIPT_DIR/$script" "$SERVICE_DIR/$script"
    chmod +x "$SERVICE_DIR/$script"
    echo "  $SERVICE_DIR/$script"
done

# -- csm, csm-sync, status -> ~/opt/claude_session_manager/bin/, symlinked --
# -- from ~/.local/bin/. ~/opt/.../ is the canonical deployment location;   --
# -- ~/.local/bin/ only ever holds PATH-visible entry points, no real files.

OPT_BIN_DIR="$SERVICE_DIR/bin"
mkdir -p "$OPT_BIN_DIR"
BIN_DIR="$HOME/.local/bin"
mkdir -p "$BIN_DIR"

for bin in csm csm-sync status; do
    cp "$SRC_DIR/$bin" "$OPT_BIN_DIR/$bin"
    chmod +x "$OPT_BIN_DIR/$bin"
    ln -sf "$OPT_BIN_DIR/$bin" "$BIN_DIR/$bin"
    echo "  $OPT_BIN_DIR/$bin  (symlinked from $BIN_DIR/$bin)"
done

# Warn about stale copies elsewhere (e.g. from an older install that used
# ~/bin, /usr/local/bin, or a plain ~/.local/bin copy instead of a symlink)
for bin in csm csm-sync status; do
    for stale in $(type -aP "$bin" 2>/dev/null); do
        [ "$stale" = "$BIN_DIR/$bin" ] && continue
        echo "  WARNING: stale $bin at $stale (shadowed by $BIN_DIR/$bin if \$PATH is ordered correctly)"
    done
done

# Warn if ~/.local/bin isn't even on PATH yet
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *)
        echo "  WARNING: $BIN_DIR is not on your \$PATH."
        echo "    Add this to your shell profile (~/.zshrc, ~/.bashrc, ...):"
        echo "      export PATH=\"\$HOME/.local/bin:\$PATH\""
        ;;
esac

# -- settings.json -> ~/.csm/ --------------------------------------------------

if [ ! -f "$HOME/.csm/settings.json" ]; then
    cp "$SRC_DIR/settings.json" "$HOME/.csm/settings.json"
    echo "  $HOME/.csm/settings.json (created - fill in remote_ssh_* to enable sync)"
else
    echo "  $HOME/.csm/settings.json (already exists, not overwritten)"
fi

# -- inject skill -> ~/.claude/skills/inject/ ---------------------------------

mkdir -p "$HOME/.claude/skills/inject"
cp "$SRC_DIR/inject/SKILL.md" "$HOME/.claude/skills/inject/SKILL.md"
echo "  $HOME/.claude/skills/inject/SKILL.md"

# -- Clean up old /info skill (replaced by ~/.local/bin/status) --------------

if [ -d "$HOME/.claude/skills/info" ]; then
    rm -rf "$HOME/.claude/skills/info"
    echo "  Removed old ~/.claude/skills/info/ (replaced by ~/.local/bin/status)"
fi

# -- Scheduled reindex + sync ---------------------------------------------------

if $IS_MACOS; then
    # macOS: launchd. Templated at install time - the source plist ships with
    # placeholders since the wrapper-script path and log dir are per-user ($HOME).
    LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
    mkdir -p "$LAUNCH_AGENTS"

    OLD_PLIST="$LAUNCH_AGENTS/com.csm.reindex.plist"
    if [ -f "$OLD_PLIST" ]; then
        launchctl unload "$OLD_PLIST" 2>/dev/null || true
        rm -f "$OLD_PLIST"
        echo "  Removed old $OLD_PLIST (replaced by com.csm.reindex-sync.plist)"
    fi

    plist="com.csm.reindex-sync.plist"
    sed -e "s|__WRAPPER_SCRIPT__|$SERVICE_DIR/csm-reindex-sync.sh|g" -e "s|__LOG_DIR__|$SERVICE_DIR|g" \
        "$MACOS_DIR/$plist" > "$LAUNCH_AGENTS/$plist"
    launchctl unload "$LAUNCH_AGENTS/$plist" 2>/dev/null || true
    launchctl load "$LAUNCH_AGENTS/$plist"
    echo "  $LAUNCH_AGENTS/$plist (loaded)"
else
    # Linux: systemd --user timer. Unit files use systemd's native %h
    # specifier for the home directory, so no templating is needed here.
    if command -v systemctl &>/dev/null; then
        SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
        mkdir -p "$SYSTEMD_USER_DIR"
        cp "$LINUX_DIR/com.csm.reindex-sync.service" "$SYSTEMD_USER_DIR/"
        cp "$LINUX_DIR/com.csm.reindex-sync.timer" "$SYSTEMD_USER_DIR/"

        if systemctl --user daemon-reload 2>/dev/null && \
           systemctl --user enable --now com.csm.reindex-sync.timer 2>/dev/null; then
            echo "  $SYSTEMD_USER_DIR/com.csm.reindex-sync.{service,timer} (enabled)"
        else
            echo "  WARNING: could not enable the systemd timer. Run manually later:"
            echo "    systemctl --user daemon-reload && systemctl --user enable --now com.csm.reindex-sync.timer"
        fi

        if command -v loginctl &>/dev/null; then
            if loginctl enable-linger "$(whoami)" 2>/dev/null; then
                echo "  Lingering enabled for $(whoami) (scheduled job runs even without an active session)"
            else
                echo "  NOTE: could not enable lingering (loginctl enable-linger $(whoami))."
                echo "        Without it, the scheduled reindex+sync job may only run while you"
                echo "        have an active session/SSH login. Ask your admin, or run it yourself:"
                echo "          loginctl enable-linger $(whoami)"
            fi
        fi
    else
        echo "  NOTE: systemd not found - scheduled reindex+sync not set up automatically."
        echo "        Run $SERVICE_DIR/csm-reindex-sync.sh via cron yourself if you want scheduling."
    fi
fi

# -- Register lifecycle hooks in settings.json --------------------------------

# Uses $HOME so the path resolves correctly on any machine.
HOOK_CMD_START='HOOK_EVENT=start "$HOME/opt/claude_session_manager/lifecycle_generation.sh"'
HOOK_CMD_END='HOOK_EVENT=end "$HOME/opt/claude_session_manager/lifecycle_generation.sh"'

if [ -f "$SETTINGS_JSON" ]; then
    python3 - "$SETTINGS_JSON" "$HOOK_CMD_START" "$HOOK_CMD_END" <<'PYEOF'
import json, sys

settings_path, cmd_start, cmd_end = sys.argv[1], sys.argv[2], sys.argv[3]

with open(settings_path) as f:
    settings = json.load(f)

hooks = settings.setdefault("hooks", {})

def set_hook(event_key, command, identifier):
    """Set a hook, replacing any existing entry matching the identifier."""
    hook_entry = {"command": command, "type": "command"}
    hook_group = {"hooks": [hook_entry], "matcher": ""}

    existing = hooks.get(event_key, [])
    filtered = [
        g for g in existing
        if not any(identifier in h.get("command", "") for h in g.get("hooks", []))
    ]
    filtered.append(hook_group)
    hooks[event_key] = filtered

set_hook("SessionStart", cmd_start, "lifecycle_generation")
set_hook("SessionEnd", cmd_end, "lifecycle_generation")

# Clean up old UserPromptSubmit hook if present
existing_ups = hooks.get("UserPromptSubmit", [])
filtered_ups = [
    g for g in existing_ups
    if not any("duplicate_session_check" in h.get("command", "") for h in g.get("hooks", []))
]
if len(filtered_ups) != len(existing_ups):
    if filtered_ups:
        hooks["UserPromptSubmit"] = filtered_ups
    else:
        hooks.pop("UserPromptSubmit", None)

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
PYEOF
    echo "  $SETTINGS_JSON (lifecycle hooks registered)"
else
    echo "  WARNING: $SETTINGS_JSON not found, skipping hook registration"
    echo "  You may need to register hooks manually after Claude Code is set up."
fi

echo ""
echo "Done."
