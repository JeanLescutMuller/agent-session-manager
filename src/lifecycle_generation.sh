#!/usr/bin/env bash
# lifecycle_generation.sh
#
# Claude Code hook for session lifecycle tracking + duplicate detection.
#
# SessionStart:
#   1. Check for duplicate session (PID still alive from last start/resume)
#   2. Warn on cross-machine/cross-directory resume
#   3. Append start/resume event to local sidecar
#
# SessionEnd:
#   1. Append end event to local sidecar
#   2. Reindex this session and best-effort push it to the remote (asm-sync),
#      if one is configured
#
# Registered in ~/.claude/settings.json via install.sh.
# HOOK_EVENT env var is set by the caller entry in settings.json.

set -euo pipefail

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
HOOK_EVENT="${HOOK_EVENT:-start}"

# --- Parse stdin payload ---
PAYLOAD=$(cat)

if command -v jq &>/dev/null; then
    SESSION_ID=$(echo "$PAYLOAD"      | jq -r '.session_id      // empty')
    TRANSCRIPT_PATH=$(echo "$PAYLOAD" | jq -r '.transcript_path // empty')
    CWD=$(echo "$PAYLOAD"             | jq -r '.cwd             // empty')
else
    SESSION_ID=$(echo "$PAYLOAD"      | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id',''))")
    TRANSCRIPT_PATH=$(echo "$PAYLOAD" | python3 -c "import sys,json; print(json.load(sys.stdin).get('transcript_path',''))")
    CWD=$(echo "$PAYLOAD"             | python3 -c "import sys,json; print(json.load(sys.stdin).get('cwd',''))")
fi

[[ -z "$SESSION_ID" || -z "$TRANSCRIPT_PATH" ]] && exit 0

# --- Derive sidecar path ---
SIDECAR_PATH="$HOME/opt/agent-session-manager/data/lifecycles/${SESSION_ID}.jsonl"

# --- Infer event type ---
if [[ "$HOOK_EVENT" == "end" ]]; then
    EVENT="end"
elif [[ -f "$SIDECAR_PATH" ]]; then
    EVENT="resume"
else
    EVENT="start"
fi

# --- Collect context ---
# Short hostname only: `hostname` returns whatever DNS domain the current
# network appends ("mac.home"), which would make the same machine look like
# two hosts in the index. asm compares and colors hosts on this short form.
HOSTNAME_VAL=$(hostname -s 2>/dev/null || hostname)
HOSTNAME_VAL="${HOSTNAME_VAL%%.*}"
WORKING_DIR="${CWD:-$PWD}"

TMUX_SESSION=""
TMUX_WINDOW=""
TMUX_PANE=""
if [[ -n "${TMUX:-}" ]]; then
    TMUX_SESSION=$(tmux display-message -p '#S' 2>/dev/null || true)
    TMUX_WINDOW=$(tmux display-message -p '#I'  2>/dev/null || true)
    TMUX_PANE=$(tmux display-message -p '#P'    2>/dev/null || true)
fi

PID_VAL=""
[[ "$EVENT" != "end" ]] && PID_VAL="$PPID"

# --- SessionStart: duplicate detection + resume warnings ---
ADDITIONAL_CONTEXT=""
if [[ "$EVENT" == "start" || "$EVENT" == "resume" ]] && [[ -f "$SIDECAR_PATH" ]]; then
    ADDITIONAL_CONTEXT=$(python3 - "$SIDECAR_PATH" "$HOSTNAME_VAL" "$WORKING_DIR" "$PPID" <<'CHECKPY'
import json, sys, os

sidecar_path, current_host, current_wd, my_pid = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])

try:
    lines = open(sidecar_path).read().strip().splitlines()
    if not lines:
        sys.exit(0)
    last = json.loads(lines[-1])
except Exception:
    sys.exit(0)

warnings = []

# Duplicate detection: scan ALL start/resume events for live PIDs (not just last).
# A short-lived resume attempt can push the original start event off the last line,
# so checking only the last line misses the actual running session.
def safe_event(l):
    try:
        return json.loads(l).get("event")
    except Exception:
        return None
last_event = safe_event(lines[-1])
if last_event != "end":
    seen_pids = set()
    for line in lines:
        try:
            ev = json.loads(line)
        except Exception:
            continue
        if ev.get("event") not in ("start", "resume"):
            continue
        if ev.get("hostname", "") and ev.get("hostname") != current_host:
            continue
        prev_pid = ev.get("pid")
        if not prev_pid or prev_pid == my_pid or prev_pid in seen_pids:
            continue
        seen_pids.add(prev_pid)
        try:
            os.kill(prev_pid, 0)
            tmux = ""
            ts = ev.get("tmux_session", "")
            tw = ev.get("tmux_window", "")
            tp = ev.get("tmux_pane", "")
            if ts:
                tmux = f" (tmux: {ts}:{tw}.{tp})"
            warnings.append(
                f"DUPLICATE SESSION: this session is already running in PID {prev_pid}{tmux}. "
                f"Consider using --fork-session instead."
            )
        except (OSError, ProcessLookupError):
            pass

# Cross-machine / cross-directory warnings (use last event for context)
prev_host = last.get("hostname", "")
prev_wd = last.get("working_dir", "")

if prev_host and prev_host != current_host:
    warnings.append(
        f"Cross-machine resume: previous session ran on '{prev_host}', "
        f"now resuming on '{current_host}'."
    )

if prev_wd and prev_wd != current_wd:
    try:
        if os.path.realpath(prev_wd) != os.path.realpath(current_wd):
            warnings.append(
                f"Working directory changed: was '{prev_wd}', now '{current_wd}'. "
                f"File paths from prior context may not resolve correctly."
            )
    except OSError:
        warnings.append(
            f"Working directory changed: was '{prev_wd}', now '{current_wd}'. "
            f"The previous directory may not exist on this machine."
        )

if warnings:
    print(" | ".join(warnings))
CHECKPY
    ) || true
fi

# Output warnings to /dev/tty (visible in terminal before Claude TUI takes over)
if [[ -n "${ADDITIONAL_CONTEXT:-}" ]]; then
    # ANSI: orange background (48;5;208), bold white text (1;97), yellow ⚠️
    ORANGE='\033[48;5;208m\033[1;97m'
    YELLOW='\033[38;5;214m'
    BOLD='\033[1m'
    RST='\033[0m'

    # Pick banner title based on warning content
    if echo "$ADDITIONAL_CONTEXT" | grep -qi "DUPLICATE SESSION"; then
        BANNER_TITLE="DUPLICATE SESSION DETECTED"
    elif echo "$ADDITIONAL_CONTEXT" | grep -qi "Cross-machine"; then
        BANNER_TITLE="CROSS-MACHINE RESUME"
    else
        BANNER_TITLE="SESSION WARNING"
    fi

    {
        printf '\n'
        printf '%s                                                                        %s\n' "$ORANGE" "$RST"
        printf '%s  ⚠️  ASM: %-60s %s\n' "$ORANGE" "$BANNER_TITLE" "$RST"
        printf '%s                                                                        %s\n' "$ORANGE" "$RST"
        printf '\n'
        # Print each warning as a separate line
        echo "$ADDITIONAL_CONTEXT" | tr '|' '\n' | while IFS= read -r warn; do
            warn=${warn#"${warn%%[![:space:]]*}"}
            [ -z "$warn" ] && continue
            printf "  %s⚠️%s%s%s\n" "$YELLOW" "$BOLD" "$warn" "$RST"
        done
        printf '\n'
        printf "  %sPress Ctrl+C to abort, or continue at your own risk.%s\n" "$YELLOW" "$RST"
        printf '\n'
        sleep 3
    } > /dev/tty 2>/dev/null || true

    # Also emit additionalContext JSON (in case Claude Code adds support later)
    ESCAPED=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$ADDITIONAL_CONTEXT")
    echo "{\"hookSpecificOutput\":{\"hookEventName\":\"SessionStart\",\"additionalContext\":${ESCAPED}}}"
fi

# --- Write event line (after checks, so warnings see prior entries only) ---
export LIFECYCLE_EVENT="$EVENT"
export LIFECYCLE_TIMESTAMP="$TIMESTAMP"
export LIFECYCLE_SESSION_ID="$SESSION_ID"
export LIFECYCLE_HOSTNAME="$HOSTNAME_VAL"
export LIFECYCLE_WORKING_DIR="$WORKING_DIR"
export LIFECYCLE_TMUX_SESSION="$TMUX_SESSION"
export LIFECYCLE_TMUX_WINDOW="$TMUX_WINDOW"
export LIFECYCLE_TMUX_PANE="$TMUX_PANE"
export LIFECYCLE_PID="$PID_VAL"
export LIFECYCLE_SIDECAR_PATH="$SIDECAR_PATH"

python3 - <<'PYEOF'
import json, os

event = {
    "event":        os.environ["LIFECYCLE_EVENT"],
    "timestamp":    os.environ["LIFECYCLE_TIMESTAMP"],
    "session_id":   os.environ["LIFECYCLE_SESSION_ID"],
    "hostname":     os.environ["LIFECYCLE_HOSTNAME"],
    "working_dir":  os.environ["LIFECYCLE_WORKING_DIR"],
    "tmux_session": os.environ.get("LIFECYCLE_TMUX_SESSION", ""),
    "tmux_window":  os.environ.get("LIFECYCLE_TMUX_WINDOW", ""),
    "tmux_pane":    os.environ.get("LIFECYCLE_TMUX_PANE", ""),
}

pid = os.environ.get("LIFECYCLE_PID", "")
if pid:
    event["pid"] = int(pid)

sidecar = os.environ["LIFECYCLE_SIDECAR_PATH"]
os.makedirs(os.path.dirname(sidecar), exist_ok=True)

with open(sidecar, "a") as f:
    f.write(json.dumps(event, ensure_ascii=False) + "\n")
PYEOF

# --- Print session info on exit ---
if [[ "$EVENT" == "end" ]]; then
    SNAME=$(grep -o '"session_name":"[^"]*"' "$TRANSCRIPT_PATH" 2>/dev/null | tail -1 | cut -d'"' -f4 || true)
    [ -z "$SNAME" ] && SNAME="(unnamed)"
    printf '\n  Session:  %s\n  ID:       %s\n  Dir:      %s\n\n' "$SNAME" "$SESSION_ID" "$WORKING_DIR" > /dev/tty 2>/dev/null || true
fi

# --- On session end: reindex this session + sync to remote ---
if [[ "$EVENT" == "end" ]]; then
    # Refresh local index for this session (fast, single-session)
    if command -v asm &>/dev/null; then
        asm reindex --uuid "$SESSION_ID" >/dev/null 2>&1 || true
    fi
    # Best-effort push to remote (background, non-blocking)
    command -v asm-sync &>/dev/null && asm-sync --push "$SESSION_ID" >/dev/null 2>&1 &
fi
