#!/usr/bin/env bash
# install.sh - Agent Session Manager
#
# Installs ASM from this source checkout to system locations:
#   ~/opt/agent-session-manager/bin/     - canonical deployment: asm, asm-sync, status
#   ~/.local/bin/                         - PATH entry points, symlinked into the above
#   ~/.claude/skills/inject/SKILL.md      - /inject skill
#   ~/opt/agent-session-manager/         - service scripts + logs (canonical location)
#   ~/.asm/                               - settings, index, lifecycle sidecars, sync log
#   ~/Library/LaunchAgents/ (macOS) or
#     ~/.config/systemd/user/ (Linux)     - symlink only; real plist/unit files
#                                           live in ~/opt/agent-session-manager/
#   ~/.claude/settings.json               - lifecycle hooks (auto-registered)
#
# First install:
#   git clone <repo-url> && cd agent-session-manager && bash install.sh
#
# Re-install after update (from deployed copy):
#   ~/opt/agent-session-manager/install.sh

set -euo pipefail

# Resolve source directory (where this script lives)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/src"
MACOS_DIR="$SRC_DIR/macos"
LINUX_DIR="$SRC_DIR/linux"

SERVICE_DIR="$HOME/opt/agent-session-manager"
SETTINGS_JSON="$HOME/.claude/settings.json"
IS_MACOS=$( [[ "$(uname -s)" == "Darwin" ]] && echo true || echo false )

echo "Installing Agent Session Manager..."
echo ""

# -- Pre-flight: check fzf and python3 ---------------------------------------
# python3 isn't optional: asm itself is a Python script (see src/asm's shebang),
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

mkdir -p "$HOME/.asm"

# -- Service scripts -> ~/opt/agent-session-manager/ ----------

mkdir -p "$SERVICE_DIR"

# Cross-platform: lifecycle hook, scheduled reindex+sync wrapper, install/uninstall
cp "$SRC_DIR/lifecycle_generation.sh" "$SERVICE_DIR/lifecycle_generation.sh"
chmod +x "$SERVICE_DIR/lifecycle_generation.sh"
echo "  $SERVICE_DIR/lifecycle_generation.sh"

cp "$SRC_DIR/asm-reindex-sync.sh" "$SERVICE_DIR/asm-reindex-sync.sh"
chmod +x "$SERVICE_DIR/asm-reindex-sync.sh"
echo "  $SERVICE_DIR/asm-reindex-sync.sh"

for script in install.sh uninstall.sh; do
    cp "$SCRIPT_DIR/$script" "$SERVICE_DIR/$script"
    chmod +x "$SERVICE_DIR/$script"
    echo "  $SERVICE_DIR/$script"
done

# -- asm, asm-sync, status -> ~/opt/agent-session-manager/bin/, symlinked --
# -- from ~/.local/bin/. ~/opt/.../ is the canonical deployment location;   --
# -- ~/.local/bin/ only ever holds PATH-visible entry points, no real files.

OPT_BIN_DIR="$SERVICE_DIR/bin"
mkdir -p "$OPT_BIN_DIR"
BIN_DIR="$HOME/.local/bin"
mkdir -p "$BIN_DIR"

for bin in asm asm-sync status; do
    cp "$SRC_DIR/$bin" "$OPT_BIN_DIR/$bin"
    chmod +x "$OPT_BIN_DIR/$bin"
    ln -sf "$OPT_BIN_DIR/$bin" "$BIN_DIR/$bin"
    echo "  $OPT_BIN_DIR/$bin  (symlinked from $BIN_DIR/$bin)"
done

# Warn about stale copies elsewhere (e.g. from an older install that used
# ~/bin, /usr/local/bin, or a plain ~/.local/bin copy instead of a symlink)
for bin in asm asm-sync status; do
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

# -- settings.json -> ~/.asm/ --------------------------------------------------

if [ ! -f "$HOME/.asm/settings.json" ]; then
    cp "$SRC_DIR/settings.json" "$HOME/.asm/settings.json"
    echo "  $HOME/.asm/settings.json (created - fill in remote_ssh_* to enable sync)"
else
    echo "  $HOME/.asm/settings.json (already exists, not overwritten)"
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
    # The real file lives in $SERVICE_DIR (~/opt/...) alongside everything else
    # ASM owns; ~/Library/LaunchAgents/ only ever holds a symlink to it, same
    # convention as ~/.local/bin/asm symlinking into $SERVICE_DIR/bin/.
    LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
    mkdir -p "$LAUNCH_AGENTS"

    plist="com.asm.reindex-sync.plist"
    REAL_PLIST="$SERVICE_DIR/$plist"
    LINK_PLIST="$LAUNCH_AGENTS/$plist"

    # A prior install may have written a real file straight into LaunchAgents
    # (pre-symlink layout) - unload and clear it before switching to a symlink.
    if [ -e "$LINK_PLIST" ] && [ ! -L "$LINK_PLIST" ]; then
        launchctl unload "$LINK_PLIST" 2>/dev/null || true
        rm -f "$LINK_PLIST"
    fi

    sed -e "s|__WRAPPER_SCRIPT__|$SERVICE_DIR/asm-reindex-sync.sh|g" -e "s|__LOG_DIR__|$SERVICE_DIR|g" \
        "$MACOS_DIR/$plist" > "$REAL_PLIST"
    ln -sf "$REAL_PLIST" "$LINK_PLIST"
    launchctl unload "$LINK_PLIST" 2>/dev/null || true
    launchctl load "$LINK_PLIST"
    echo "  $REAL_PLIST  (symlinked from $LINK_PLIST, loaded)"
else
    # Linux: systemd --user timer. Unit files use systemd's native %h
    # specifier for the home directory, so no templating is needed here.
    # Real files live in $SERVICE_DIR; ~/.config/systemd/user/ only holds
    # symlinks to them, mirroring the macOS layout above.
    if command -v systemctl &>/dev/null; then
        SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
        mkdir -p "$SYSTEMD_USER_DIR"

        for unit in com.asm.reindex-sync.service com.asm.reindex-sync.timer; do
            REAL_UNIT="$SERVICE_DIR/$unit"
            LINK_UNIT="$SYSTEMD_USER_DIR/$unit"
            cp "$LINUX_DIR/$unit" "$REAL_UNIT"
            # A prior install may have written a real file here directly
            # (pre-symlink layout) - clear it before switching to a symlink.
            [ -e "$LINK_UNIT" ] && [ ! -L "$LINK_UNIT" ] && rm -f "$LINK_UNIT"
            ln -sf "$REAL_UNIT" "$LINK_UNIT"
        done

        if systemctl --user daemon-reload 2>/dev/null && \
           systemctl --user enable --now com.asm.reindex-sync.timer 2>/dev/null; then
            echo "  $SERVICE_DIR/com.asm.reindex-sync.{service,timer}  (symlinked from $SYSTEMD_USER_DIR, enabled)"
        else
            echo "  WARNING: could not enable the systemd timer. Run manually later:"
            echo "    systemctl --user daemon-reload && systemctl --user enable --now com.asm.reindex-sync.timer"
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
        echo "        Run $SERVICE_DIR/asm-reindex-sync.sh via cron yourself if you want scheduling."
    fi
fi

# -- Register lifecycle hooks in settings.json --------------------------------

# Uses $HOME so the path resolves correctly on any machine.
HOOK_CMD_START='HOOK_EVENT=start "$HOME/opt/agent-session-manager/lifecycle_generation.sh"'
HOOK_CMD_END='HOOK_EVENT=end "$HOME/opt/agent-session-manager/lifecycle_generation.sh"'

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

set_hook("SessionStart", cmd_start, "agent-session-manager/lifecycle_generation.sh")
set_hook("SessionEnd", cmd_end, "agent-session-manager/lifecycle_generation.sh")

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
