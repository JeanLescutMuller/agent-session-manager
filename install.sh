#!/usr/bin/env bash
# install.sh - Agent Session Manager
#
# Installs ASM from this source checkout to system locations:
#   ~/opt/agent-session-manager/bin/     - canonical deployment: asm, asm-sync, status
#   ~/.local/bin/                         - PATH entry points, symlinked into the above
#   ~/.claude/skills/inject/SKILL.md      - /inject skill
#   ~/opt/agent-session-manager/         - service scripts + logs (canonical location)
#   ~/opt/agent-session-manager/data/     - settings, index, lifecycle sidecars, sync log
#   ~/Library/LaunchAgents/ (macOS) or
#     ~/.config/systemd/user/ (Linux)     - symlink only; real plist/unit files
#                                           live in ~/opt/agent-session-manager/
#   ~/.claude/settings.json               - lifecycle hooks (auto-registered)
#   ~/.codex/config.toml                  - lifecycle hooks, if Codex is detected
#                                           (registered as a plugin via `codex plugin`,
#                                           requires a one-time trust approval on first run)
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

mkdir -p "$SERVICE_DIR/data"

# -- Service scripts -> ~/opt/agent-session-manager/ ----------

mkdir -p "$SERVICE_DIR"

# Cross-platform: lifecycle hook, scheduled reindex+sync wrapper, install/uninstall
cp "$SRC_DIR/lifecycle_generation.sh" "$SERVICE_DIR/lifecycle_generation.sh"
chmod +x "$SERVICE_DIR/lifecycle_generation.sh"
echo "  $SERVICE_DIR/lifecycle_generation.sh"

cp "$SRC_DIR/asm-reindex-and-rsync.sh" "$SERVICE_DIR/asm-reindex-and-rsync.sh"
chmod +x "$SERVICE_DIR/asm-reindex-and-rsync.sh"
rm -f "$SERVICE_DIR/asm-reindex-sync.sh"  # former name
echo "  $SERVICE_DIR/asm-reindex-and-rsync.sh"

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

# -- settings.json -> ~/opt/agent-session-manager/data/ ----------------------

if [ ! -f "$SERVICE_DIR/data/settings.json" ]; then
    cp "$SRC_DIR/settings.json" "$SERVICE_DIR/data/settings.json"
    echo "  $SERVICE_DIR/data/settings.json (created - fill in remote_ssh_* to enable sync)"
else
    echo "  $SERVICE_DIR/data/settings.json (already exists, not overwritten)"
fi

# Settings are in place now, so this reflects any codex_enabled override the
# user already had - reused below for both the inject skill and the plugin
# registration, rather than re-detecting Codex twice.
CODEX_ENABLED=$(python3 -c "
from importlib.machinery import SourceFileLoader
m = SourceFileLoader('asm_mod', '$OPT_BIN_DIR/asm').load_module()
print('true' if m.CODEX_ENABLED else 'false')
" 2>/dev/null || echo false)
CODEX_PRESENT=false
[ "$CODEX_ENABLED" = "true" ] && command -v codex &>/dev/null && CODEX_PRESENT=true

# -- inject skill -> ~/.claude/skills/inject/ (+ ~/.codex/skills/ if Codex) ---

mkdir -p "$HOME/.claude/skills/inject"
cp "$SRC_DIR/inject/SKILL.md" "$HOME/.claude/skills/inject/SKILL.md"
echo "  $HOME/.claude/skills/inject/SKILL.md"

if $CODEX_PRESENT; then
    mkdir -p "$HOME/.codex/skills/inject"
    cp "$SRC_DIR/inject/SKILL.md" "$HOME/.codex/skills/inject/SKILL.md"
    echo "  $HOME/.codex/skills/inject/SKILL.md"
fi

# -- Clean up old /info skill (replaced by ~/.local/bin/status) --------------

if [ -d "$HOME/.claude/skills/info" ]; then
    rm -rf "$HOME/.claude/skills/info"
    echo "  Removed old ~/.claude/skills/info/ (replaced by ~/.local/bin/status)"
fi

# -- Scheduled reindex + sync ---------------------------------------------------

# Run through multi-host-orchestrator (separate project, ~/opt/multi-host-orchestrator): this machine's own
# scheduler starts its mho_entrypoint.sh on mho_var.sh every 30 min (the whole schedule; mho_var.sh adds a
# timeout). Real plist / unit files here, symlinks where the OS looks.
cp "$SRC_DIR/mho_var.sh" "$SERVICE_DIR/mho_var.sh"
echo "  $SERVICE_DIR/mho_var.sh"
# Self-migrating: the job files of the Python multi-host-orchestrator (until 2026-10-09) and of smart-orchestrator
rm -f "$SERVICE_DIR/multi-host-orchestrator.conf" "$HOME/opt/multi-host-orchestrator/jobs/asm-reindex-and-rsync.conf" \
      "$SERVICE_DIR/smart-orchestrator.conf" "$HOME/opt/smart-orchestrator/jobs/asm-reindex-and-rsync.conf"

# Self-migrating: remove the former launchd / systemd scheduling of this job
# (com.csm.* is the name from before the claude -> agent-session-manager rename; com.asm.reindex-and-rsync /
# asm-reindex-and-rsync the trigger names from before the standard com.jeanlescut.<repo>, 2026-10-09).
for name in com.asm.reindex-sync com.csm.reindex-sync com.asm.reindex-and-rsync asm-reindex-and-rsync; do
    if $IS_MACOS; then
        if [ -e "$HOME/Library/LaunchAgents/$name.plist" ] || [ -L "$HOME/Library/LaunchAgents/$name.plist" ]; then
            launchctl unload "$HOME/Library/LaunchAgents/$name.plist" 2>/dev/null || true
            rm -f "$HOME/Library/LaunchAgents/$name.plist" "$SERVICE_DIR/$name.plist"
            echo "  Removed former scheduling: $name (launchd)"
        fi
    elif command -v systemctl &>/dev/null && { [ -e "$HOME/.config/systemd/user/$name.timer" ] || [ -L "$HOME/.config/systemd/user/$name.timer" ]; }; then
        systemctl --user disable --now "$name.timer" 2>/dev/null || true
        rm -f "$HOME/.config/systemd/user/$name.service" "$HOME/.config/systemd/user/$name.timer" \
              "$SERVICE_DIR/$name.service" "$SERVICE_DIR/$name.timer"
        systemctl --user daemon-reload 2>/dev/null || true
        echo "  Removed former scheduling: $name (systemd)"
    fi
done

MHO="$HOME/opt/multi-host-orchestrator/mho_entrypoint.sh"
LABEL=com.jeanlescut.agent-session-manager   # the trigger's name: com.jeanlescut.<repo>, the same on macOS and Linux
if $IS_MACOS; then
    cat > "$SERVICE_DIR/$LABEL.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$MHO</string><string>$SERVICE_DIR/mho_var.sh</string></array>
  <key>StartInterval</key><integer>1800</integer><key>RunAtLoad</key><true/><key>AbandonProcessGroup</key><true/>
</dict></plist>
PLIST
    ln -sfn "$SERVICE_DIR/$LABEL.plist" "$HOME/Library/LaunchAgents/$LABEL.plist"
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/$LABEL.plist" && echo "  LaunchAgent $LABEL (every 30 min)"
elif command -v systemctl &>/dev/null; then
    printf '[Unit]\nDescription=asm: reindex + rsync (through multi-host-orchestrator)\n[Service]\nType=oneshot\nExecStart=/bin/bash %s %s\nKillMode=process\nTimeoutStartSec=infinity\n' \
        "$MHO" "$SERVICE_DIR/mho_var.sh" > "$SERVICE_DIR/$LABEL.service"
    printf '[Unit]\nDescription=asm: reindex + rsync every 30 min\n[Timer]\nOnCalendar=*:0/30\nPersistent=true\n[Install]\nWantedBy=timers.target\n' > "$SERVICE_DIR/$LABEL.timer"
    mkdir -p "$HOME/.config/systemd/user"
    ln -sfn "$SERVICE_DIR/$LABEL.service" "$HOME/.config/systemd/user/$LABEL.service"
    ln -sfn "$SERVICE_DIR/$LABEL.timer" "$HOME/.config/systemd/user/$LABEL.timer"
    systemctl --user daemon-reload && systemctl --user enable --now "$LABEL.timer" 2>/dev/null && echo "  systemd timer $LABEL (every 30 min)"
    loginctl enable-linger "$USER" 2>/dev/null || true
fi
[ -x "$MHO" ] || echo "  NOTE: multi-host-orchestrator is not installed ($MHO missing): the trigger runs nothing until it is (github.com/JeanLescutMuller/multi-host-orchestrator)."

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

# -- Codex plugin: same lifecycle hooks, registered a different way ----------
#
# Codex has no single settings.json to hand-edit; hooks are shipped as a
# plugin (src/codex-plugin/) published through a local marketplace, both
# registered into ~/.codex/config.toml by Codex's own `codex plugin`
# subcommands - real, non-interactive, and safe to re-run (confirmed live:
# both commands are idempotent, exit 0 and leave config.toml unchanged on a
# second run). The hook payload Codex delivers on SessionStart/SessionEnd is
# byte-for-byte the same shape Claude Code's is (session_id, transcript_path,
# cwd via stdin JSON) - confirmed live - so it points at the exact same
# lifecycle_generation.sh above, unmodified.
#
# Reuses $CODEX_PRESENT computed above (asm's own CODEX_ENABLED, auto-detect
# or the codex_enabled override in ~/opt/agent-session-manager/data/settings.json, plus `codex` being
# on $PATH) rather than re-implementing that detection here.

if $CODEX_PRESENT; then
    CODEX_PLUGIN_DIR="$SERVICE_DIR/codex-plugin"
    rm -rf "$CODEX_PLUGIN_DIR"
    mkdir -p "$CODEX_PLUGIN_DIR"
    cp -R "$SRC_DIR/codex-plugin/." "$CODEX_PLUGIN_DIR/"
    echo "  $CODEX_PLUGIN_DIR"

    CODEX_MARKET_DIR="$SERVICE_DIR/codex-marketplace"
    mkdir -p "$CODEX_MARKET_DIR/.agents/plugins" "$CODEX_MARKET_DIR/plugins"
    ln -sf "$CODEX_PLUGIN_DIR" "$CODEX_MARKET_DIR/plugins/asm"
    cat > "$CODEX_MARKET_DIR/.agents/plugins/marketplace.json" <<EOF
{
  "name": "asm-local",
  "interface": {"displayName": "ASM Local"},
  "plugins": [
    {
      "name": "asm",
      "source": {"source": "local", "path": "./plugins/asm"},
      "policy": {"installation": "AVAILABLE", "authentication": "ON_INSTALL"},
      "category": "Productivity"
    }
  ]
}
EOF

    if MARKET_OUT=$(codex plugin marketplace add "$CODEX_MARKET_DIR" 2>&1) && \
       PLUGIN_OUT=$(codex plugin add asm@asm-local 2>&1); then
        echo "  asm@asm-local registered in ~/.codex/config.toml"
        echo "  NOTE: Codex requires a one-time trust approval before hooks actually run."
        echo "        Start any 'codex' session and approve asm's hooks when prompted -"
        echo "        this only happens once."
    else
        echo "  WARNING: could not register the Codex plugin:"
        echo "$MARKET_OUT" | sed 's/^/    /'
        echo "${PLUGIN_OUT:-}" | sed 's/^/    /'
        echo "  Run manually: codex plugin marketplace add \"$CODEX_MARKET_DIR\" && codex plugin add asm@asm-local"
    fi
else
    echo "  Codex not detected or disabled - skipping Codex lifecycle hooks"
    echo "    (Claude Code's lifecycle hooks above are unaffected)"
fi

echo ""
echo "Done."
