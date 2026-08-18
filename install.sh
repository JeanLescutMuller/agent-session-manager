#!/usr/bin/env bash
# install.sh - Claude Session Manager
#
# Installs CSM from this source checkout to system locations:
#   ~/.local/bin/csm                      - the CLI
#   ~/.local/bin/csm-sync                 - optional sync script
#   ~/.local/bin/status                   - standalone session status script
#   ~/.claude/skills/inject/SKILL.md      - /inject skill
#   ~/services/claude_session_manager/    - service scripts + logs
#   ~/Library/LaunchAgents/               - scheduled reindex (macOS only)
#   ~/.claude/settings.json               - lifecycle hooks (auto-registered)
#
# First install:
#   git clone <repo-url> && cd claude-session-manager && bash install.sh
#
# Re-install after update (from deployed copy):
#   ~/services/claude_session_manager/install.sh

set -euo pipefail

# Resolve source directory (where this script lives)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/src"
MACOS_DIR="$SRC_DIR/macos"

SERVICE_DIR="$HOME/services/claude_session_manager"
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

# -- Pre-flight: check autoname plugin (optional - title generation just --
# -- gets skipped gracefully if it's not installed) -------------------------

AUTONAME_GLOB="$HOME/.claude/plugins/cache/claude-templates/autoname/*/scripts/session-autoname.py"
if ! compgen -G "$AUTONAME_GLOB" >/dev/null 2>&1; then
    if command -v claude-templates &>/dev/null; then
        echo "  Installing autoname plugin (optional, for LLM title generation)..."
        claude-templates plugin autoname install 2>&1 | tail -3
        if compgen -G "$AUTONAME_GLOB" >/dev/null 2>&1; then
            echo "  autoname plugin installed."
        else
            echo "  NOTE: autoname plugin installation failed - title generation will be skipped."
        fi
    else
        echo "  NOTE: autoname plugin not installed - title generation will be skipped."
        echo "        (optional; install claude-templates and run 'claude-templates plugin autoname install' to enable it)"
    fi
else
    echo "  autoname plugin: already installed"
fi

# -- Service scripts -> ~/services/claude_session_manager/ ----------

mkdir -p "$SERVICE_DIR"

# Cross-platform: lifecycle hook + install/uninstall scripts
cp "$SRC_DIR/lifecycle_generation.sh" "$SERVICE_DIR/lifecycle_generation.sh"
chmod +x "$SERVICE_DIR/lifecycle_generation.sh"
echo "  $SERVICE_DIR/lifecycle_generation.sh"

for script in install.sh uninstall.sh; do
    cp "$SCRIPT_DIR/$script" "$SERVICE_DIR/$script"
    chmod +x "$SERVICE_DIR/$script"
    echo "  $SERVICE_DIR/$script"
done

# -- csm, csm-sync, status -> ~/.local/bin/ ----------------------------------
# Single, fixed install location - no PATH-priority scanning, no sudo, no
# /usr/local/bin fallback.

BIN_DIR="$HOME/.local/bin"
mkdir -p "$BIN_DIR"

for bin in csm csm-sync status; do
    cp "$SRC_DIR/$bin" "$BIN_DIR/$bin"
    chmod +x "$BIN_DIR/$bin"
    echo "  $BIN_DIR/$bin"
done

# Warn about stale copies elsewhere (e.g. from an older install that used
# ~/bin or /usr/local/bin)
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

# -- csm-settings.json -> ~/.claude/ ------------------------------------------

if [ ! -f "$HOME/.claude/csm-settings.json" ]; then
    cp "$SRC_DIR/csm-settings.json" "$HOME/.claude/csm-settings.json"
    echo "  $HOME/.claude/csm-settings.json (created - fill in remote_ssh_* to enable sync)"
else
    echo "  $HOME/.claude/csm-settings.json (already exists, not overwritten)"
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

# -- LaunchAgent plists -> ~/Library/LaunchAgents/ (macOS only) ---------------
# Templated at install time: the source plist ships with placeholders since
# the binary path and log directory are per-user ($HOME).

if $IS_MACOS; then
    LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
    mkdir -p "$LAUNCH_AGENTS"
    for plist in com.csm.reindex.plist; do
        sed -e "s|__CSM_BIN__|$BIN_DIR/csm|g" -e "s|__LOG_DIR__|$SERVICE_DIR|g" \
            "$MACOS_DIR/$plist" > "$LAUNCH_AGENTS/$plist"
        launchctl unload "$LAUNCH_AGENTS/$plist" 2>/dev/null || true
        launchctl load "$LAUNCH_AGENTS/$plist"
        echo "  $LAUNCH_AGENTS/$plist (loaded)"
    done
fi

# -- Register lifecycle hooks in settings.json --------------------------------

# Uses $HOME so the path resolves correctly on any machine.
HOOK_CMD_START='HOOK_EVENT=start "$HOME/services/claude_session_manager/lifecycle_generation.sh"'
HOOK_CMD_END='HOOK_EVENT=end "$HOME/services/claude_session_manager/lifecycle_generation.sh"'

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
