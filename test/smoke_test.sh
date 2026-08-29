#!/usr/bin/env bash
# smoke_test.sh - Non-destructive health check for an ASM install.
#
# Run this on each machine (laptop, VM) to confirm indexing, lifecycle
# hooks, and cross-machine sync are actually working, not just installed.
# Read-only / additive wherever possible:
#   - never deletes or overwrites real index/lifecycle files
#   - the one write it performs (a lifecycle sidecar for a fake test UUID)
#     is cleaned up at the end, even on failure (trap)
#   - `asm reindex` and `asm-sync` are real commands, but both are designed
#     to be safely re-run any time (mtime-skip / mtime-wins) - this is the
#     same reindex+sync pair the scheduled job already runs every 30 min.
#
# Usage:
#   bash test/smoke_test.sh            # full run, including live asm-sync
#   bash test/smoke_test.sh --offline  # skip anything that touches the network
#
# Exit status: 0 if every check passed, 1 if any failed.

set -uo pipefail

OFFLINE=false
[[ "${1:-}" == "--offline" ]] && OFFLINE=true

PASS=0
FAIL=0
WARN=0

pass() { echo -e "  \033[32mPASS\033[0m  $1"; PASS=$((PASS+1)); }
fail() { echo -e "  \033[31mFAIL\033[0m  $1"; FAIL=$((FAIL+1)); }
warn() { echo -e "  \033[33mWARN\033[0m  $1"; WARN=$((WARN+1)); }
section() { echo ""; echo "== $1 =="; }

ASM_HOME="$HOME/.asm"
DEPLOY_DIR="$HOME/opt/agent-session-manager"
BIN_DIR="$DEPLOY_DIR/bin"
LOCAL_BIN="$HOME/.local/bin"

# A non-interactive shell (e.g. `ssh host command`) doesn't source ~/.bashrc,
# so ~/.local/bin may not be on PATH even though it is in real interactive
# use. Make sure it's there so asm/asm-sync/status resolve either way.
case ":$PATH:" in
    *":$LOCAL_BIN:"*) ;;
    *) export PATH="$LOCAL_BIN:$PATH" ;;
esac
SETTINGS_JSON="$ASM_HOME/settings.json"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"

# ---------------------------------------------------------------------------
section "Preflight"

command -v python3 &>/dev/null && pass "python3 available" || fail "python3 not found"
command -v fzf &>/dev/null && pass "fzf available" || fail "fzf not found"
command -v jq &>/dev/null && pass "jq available (asm-sync/lifecycle hook fast path)" || warn "jq not found (falls back to python3, slower but OK)"
[[ -f "$SETTINGS_JSON" ]] && python3 -c "import json; json.load(open('$SETTINGS_JSON'))" 2>/dev/null \
    && pass "settings.json exists and is valid JSON" \
    || fail "settings.json missing or invalid: $SETTINGS_JSON"

REMOTE_HOST=$(python3 -c "import json,os; print(json.load(open('$SETTINGS_JSON')).get('remote_ssh_host',''))" 2>/dev/null)
REMOTE_USER=$(python3 -c "import json,os; print(json.load(open('$SETTINGS_JSON')).get('remote_ssh_user',''))" 2>/dev/null)
REMOTE_PORT=$(python3 -c "import json,os; print(json.load(open('$SETTINGS_JSON')).get('remote_ssh_port','22'))" 2>/dev/null)
if [[ -n "$REMOTE_HOST" ]]; then
    echo "  (role: spoke - remote_ssh_host=$REMOTE_HOST)"
else
    echo "  (role: hub - remote_ssh_host empty, sync is a no-op here by design)"
fi

# ---------------------------------------------------------------------------
section "Deployment layout"

for f in asm asm-sync status; do
    if [[ -L "$LOCAL_BIN/$f" ]]; then
        target=$(readlink "$LOCAL_BIN/$f")
        [[ "$target" == "$BIN_DIR/$f" ]] \
            && pass "$LOCAL_BIN/$f -> $BIN_DIR/$f" \
            || fail "$LOCAL_BIN/$f symlink points to unexpected target: $target"
    else
        fail "$LOCAL_BIN/$f is missing or not a symlink"
    fi
done

for f in lifecycle_generation.sh asm-reindex-sync.sh install.sh uninstall.sh; do
    [[ -f "$DEPLOY_DIR/$f" ]] && pass "$DEPLOY_DIR/$f present" || fail "$DEPLOY_DIR/$f missing"
done

[[ -f "$HOME/.claude/skills/inject/SKILL.md" ]] \
    && pass "/inject skill installed" \
    || fail "~/.claude/skills/inject/SKILL.md missing"

# Drift check: if we're running from a git checkout, compare deployed copies
# against src/ to catch "edited src/ but forgot to re-run install.sh".
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -d "$REPO_DIR/src" ]]; then
    drift=0
    for f in asm asm-sync status; do
        if [[ -f "$REPO_DIR/src/$f" && -f "$BIN_DIR/$f" ]]; then
            diff -q "$REPO_DIR/src/$f" "$BIN_DIR/$f" &>/dev/null || drift=1
        fi
    done
    for f in lifecycle_generation.sh asm-reindex-sync.sh install.sh uninstall.sh; do
        if [[ -f "$REPO_DIR/src/$f" && -f "$DEPLOY_DIR/$f" ]]; then
            diff -q "$REPO_DIR/src/$f" "$DEPLOY_DIR/$f" &>/dev/null || drift=1
        elif [[ -f "$REPO_DIR/$f" && -f "$DEPLOY_DIR/$f" ]]; then
            diff -q "$REPO_DIR/$f" "$DEPLOY_DIR/$f" &>/dev/null || drift=1
        fi
    done
    [[ $drift -eq 0 ]] \
        && pass "deployed copies match src/ (no pending install.sh needed)" \
        || warn "deployed copies differ from src/ - run install.sh to redeploy"
else
    warn "not running from a repo checkout - skipping src/ drift check"
fi

# Claude Code hooks registered
if [[ -f "$CLAUDE_SETTINGS" ]]; then
    hook_ok=$(python3 -c "
import json
d = json.load(open('$CLAUDE_SETTINGS'))
hooks = d.get('hooks', {})
def has_lifecycle(evt):
    for entry in hooks.get(evt, []):
        for h in entry.get('hooks', []):
            if 'lifecycle_generation.sh' in h.get('command', ''):
                return True
    return False
print('1' if has_lifecycle('SessionStart') and has_lifecycle('SessionEnd') else '0')
" 2>/dev/null)
    [[ "$hook_ok" == "1" ]] \
        && pass "SessionStart/SessionEnd hooks registered in ~/.claude/settings.json" \
        || fail "lifecycle_generation.sh not wired into SessionStart+SessionEnd hooks"
else
    fail "~/.claude/settings.json not found"
fi

# Scheduler
if [[ "$(uname -s)" == "Darwin" ]]; then
    if launchctl list 2>/dev/null | grep -q com.asm.reindex-sync; then
        pass "launchd job com.asm.reindex-sync is loaded"
    else
        fail "launchd job com.asm.reindex-sync not loaded (launchctl list)"
    fi
    [[ -f "$HOME/Library/LaunchAgents/com.asm.reindex-sync.plist" ]] \
        && pass "LaunchAgent plist present" || fail "LaunchAgent plist missing"
else
    if systemctl --user is-enabled com.asm.reindex-sync.timer &>/dev/null; then
        pass "systemd --user timer com.asm.reindex-sync.timer is enabled"
    else
        fail "systemd --user timer not enabled (systemctl --user status com.asm.reindex-sync.timer)"
    fi
    if loginctl show-user "$USER" 2>/dev/null | grep -q "Linger=yes"; then
        pass "loginctl linger enabled (timer survives logout)"
    else
        warn "loginctl linger not enabled - timer may only run while logged in"
    fi
fi

# ---------------------------------------------------------------------------
section "CLI basics"

if out=$(asm --version 2>&1); then
    pass "asm --version -> $out"
else
    fail "asm --version exited non-zero: $out"
fi

if asm --help &>/dev/null; then
    pass "asm --help exits 0"
else
    fail "asm --help exited non-zero"
fi

# ---------------------------------------------------------------------------
section "status script"

unset CLAUDE_CODE_SESSION_ID
out=$(status 2>&1)
if [[ "$out" == *"CLAUDE_CODE_SESSION_ID not set"* ]]; then
    pass "status correctly reports 'not running' when env var unset"
else
    fail "status did not print expected message when env var unset: $out"
fi

# Pick a real, recently-indexed local session to test the populated path.
sample_uuid=$(ls -t "$ASM_HOME/indexes"/*.json 2>/dev/null | head -1 | xargs -I{} basename {} .json)
if [[ -n "${sample_uuid:-}" ]]; then
    out=$(CLAUDE_CODE_SESSION_ID="$sample_uuid" status 2>&1)
    if echo "$out" | grep -q "^Title:" && echo "$out" | grep -q "^UUID: *$sample_uuid$"; then
        pass "status prints populated report for a real session ($sample_uuid)"
    else
        fail "status output missing expected fields for $sample_uuid"
    fi
else
    warn "no local index files found - skipping populated status check"
fi

# ---------------------------------------------------------------------------
section "Reindex (asm reindex)"

if out=$(asm reindex 2>&1); then
    pass "asm reindex exits 0"
    echo "$out" | sed 's/^/    /'
else
    fail "asm reindex exited non-zero"
    echo "$out" | sed 's/^/    /'
fi

# Second run right after should skip everything (nothing new to index).
out2=$(asm reindex 2>&1)
if echo "$out2" | grep -qE "0 to reindex"; then
    pass "second reindex run is a no-op (mtime-skip working)"
else
    warn "second reindex run did not report '0 to reindex' - check output above"
    echo "$out2" | sed 's/^/    /'
fi

# Validate every index file is well-formed JSON with required fields.
bad=0
total=0
for f in "$ASM_HOME"/indexes/*.json; do
    [[ -e "$f" ]] || continue
    total=$((total+1))
    ok=$(python3 -c "
import json, sys
try:
    d = json.load(open('$f'))
except Exception as e:
    print('0'); sys.exit()
required = ['session_id', 'initial_working_dir', 'initial_hostname', 'created_at', 'last_active', 'session_state', 'conversation']
print('1' if all(k in d for k in required) and isinstance(d['conversation'], list) else '0')
" 2>/dev/null)
    [[ "$ok" == "1" ]] || { bad=$((bad+1)); echo "    malformed: $f"; }
done
if [[ $total -eq 0 ]]; then
    warn "no index files found under $ASM_HOME/indexes"
elif [[ $bad -eq 0 ]]; then
    pass "all $total index files are valid JSON with required fields"
else
    fail "$bad / $total index files are malformed (listed above)"
fi

# ---------------------------------------------------------------------------
section "Search (find_sessions, headless - no fzf)"

search_result=$(python3 - <<'PYEOF' 2>&1
import sys, importlib.util, os, glob, json
from importlib.machinery import SourceFileLoader
loader = SourceFileLoader("asm_mod", os.path.expanduser("~/.local/bin/asm"))
spec = importlib.util.spec_from_loader("asm_mod", loader)
asm_mod = importlib.util.module_from_spec(spec)
loader.exec_module(asm_mod)

# Any single distinctive keyword drawn from a session's own title should find
# that exact session without needing fzf. Scan newest-first for a session
# whose title actually yields a keyword: short titles like "CQM" have none,
# and picking one of those would silently skip the check rather than run it.
def usable_keyword(path):
    try:
        idx = json.load(open(path))
    except (OSError, ValueError):
        return None
    title = (idx.get("custom_title") or "").replace("(auto-generated)", "").strip()
    return next((w for w in title.split() if len(w) > 3 and w.isalnum()), None)

indexes = sorted(glob.glob(os.path.expanduser("~/.asm/indexes/*.json")),
                 key=os.path.getmtime, reverse=True)
uuid = keyword = None
for path in indexes:
    keyword = usable_keyword(path)
    if keyword:
        uuid = os.path.basename(path)[:-len(".json")]
        break
if not keyword:
    print("SKIP: no indexed session has a usable title keyword")
    sys.exit(0)

opts = asm_mod.SearchOpts(keywords=[keyword], from_days=90, max_scan=50)
sessions, fuzzy = asm_mod.find_sessions(opts)
found = any(os.path.basename(s[1]) == f"{uuid}.json" for s in sessions)
print("FOUND" if found else f"NOTFOUND keyword={keyword!r} results={len(sessions)}")
PYEOF
)
case "$search_result" in
    FOUND*) pass "keyword search finds a known session by title keyword" ;;
    SKIP*)  warn "no indexed session has a usable title keyword - search check skipped" ;;
    *)      fail "keyword search did not find the sample session ($search_result)" ;;
esac

# --host filter sanity: an impossible hostname substring must return zero
# sessions (confirms the filter is actually applied, not silently ignored).
host_check=$(python3 - <<'PYEOF' 2>&1
import importlib.util, os
from importlib.machinery import SourceFileLoader
loader = SourceFileLoader("asm_mod", os.path.expanduser("~/.local/bin/asm"))
spec = importlib.util.spec_from_loader("asm_mod", loader)
asm_mod = importlib.util.module_from_spec(spec)
loader.exec_module(asm_mod)

# Negative test: an impossible hostname substring must filter everything out.
opts = asm_mod.SearchOpts(keywords=[], from_days=90, host="no-such-host-xyz-123", max_scan=200)
sessions, _ = asm_mod.find_sessions(opts)
print("OK" if not sessions else f"BAD {[s[1] for s in sessions]}")
PYEOF
)
if [[ "$host_check" == "OK" ]]; then
    pass "--host filter correctly excludes all sessions for a nonexistent host"
else
    fail "--host filter did not filter out a nonexistent host: $host_check"
fi

# ---------------------------------------------------------------------------
# Sync runs BEFORE the lifecycle-hook simulation below on purpose: that
# simulation triggers a real backgrounded `asm-sync --push` (R6.3), which
# would otherwise race the sync-log assertions here and produce a spurious
# extra line / timing flake.
section "Sync (asm-sync)"

if [[ -z "$REMOTE_HOST" ]]; then
    pass "hub role: remote_ssh_host empty, asm-sync should no-op"
    out=$(asm-sync 2>&1)
    rc=$?
    [[ $rc -eq 0 ]] && pass "asm-sync exits 0 with no remote configured" || fail "asm-sync exited $rc with no remote configured"
elif $OFFLINE; then
    warn "skipping live sync checks (--offline)"
else
    if ssh -p "$REMOTE_PORT" -o BatchMode=yes -o ConnectTimeout=5 "$REMOTE_USER@$REMOTE_HOST" true 2>/dev/null; then
        pass "SSH reachable: $REMOTE_USER@$REMOTE_HOST:$REMOTE_PORT"

        before_lines=$(wc -l < "$ASM_HOME/sync-log.jsonl" 2>/dev/null || echo 0)
        if out=$(asm-sync --check 2>&1); then
            pass "asm-sync --check (dry run) exits 0"
        else
            fail "asm-sync --check exited non-zero: $out"
        fi
        after_lines=$(wc -l < "$ASM_HOME/sync-log.jsonl" 2>/dev/null || echo 0)
        [[ "$before_lines" == "$after_lines" ]] \
            && pass "--check performed no writes to sync-log.jsonl (true dry run)" \
            || warn "sync-log.jsonl grew during --check (expected 0 new lines)"

        # Real sync: safe by design (mtime-wins, index-only), same as the
        # scheduled job. Confirms end-to-end reachability + rsync auth.
        before_lines=$(wc -l < "$ASM_HOME/sync-log.jsonl" 2>/dev/null || echo 0)
        if out=$(asm-sync 2>&1); then
            pass "asm-sync (live) exits 0"
        else
            fail "asm-sync (live) exited non-zero: $out"
        fi
        after_lines=$(wc -l < "$ASM_HOME/sync-log.jsonl" 2>/dev/null || echo 0)
        if [[ "$after_lines" -gt "$before_lines" ]]; then
            last_line=$(tail -1 "$ASM_HOME/sync-log.jsonl")
            if echo "$last_line" | grep -q '"outcome": *"success"'; then
                pass "sync-log.jsonl recorded a successful sync: $last_line"
            else
                fail "sync-log.jsonl recorded a non-success outcome: $last_line"
            fi
        else
            fail "asm-sync (live) did not append to sync-log.jsonl"
        fi
    else
        warn "SSH unreachable: $REMOTE_USER@$REMOTE_HOST:$REMOTE_PORT (offline spoke - expected sometimes)"
        out=$(asm-sync 2>&1)
        rc=$?
        [[ $rc -eq 0 ]] && pass "asm-sync still exits 0 cleanly when remote is unreachable" || fail "asm-sync exited $rc when remote unreachable (should always exit 0)"
        if tail -1 "$ASM_HOME/sync-log.jsonl" 2>/dev/null | grep -q '"outcome": *"unreachable"'; then
            pass "sync-log.jsonl correctly recorded 'unreachable'"
        else
            warn "sync-log.jsonl last line doesn't show 'unreachable' - check manually"
        fi
    fi
fi

# Staleness check, informational.
if [[ -f "$ASM_HOME/sync-log.jsonl" ]]; then
    last_ts=$(tail -1 "$ASM_HOME/sync-log.jsonl" | python3 -c "import json,sys; print(json.load(sys.stdin).get('timestamp',''))" 2>/dev/null)
    if [[ -n "$last_ts" ]]; then
        age_h=$(python3 -c "
from datetime import datetime, timezone
t = datetime.strptime('$last_ts', '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=timezone.utc)
print(round((datetime.now(timezone.utc) - t).total_seconds() / 3600, 1))
" 2>/dev/null)
        echo "  (last sync-log entry: $last_ts, ${age_h}h ago)"
    fi
fi

# ---------------------------------------------------------------------------
section "Lifecycle hook (simulated, isolated test UUID)"

TEST_UUID="00000000-test-smoke-0000-$(date +%s)"
TEST_SIDECAR="$ASM_HOME/lifecycles/${TEST_UUID}.jsonl"
cleanup_lifecycle() { rm -f "$TEST_SIDECAR"; }
trap cleanup_lifecycle EXIT

start_payload=$(python3 -c "import json; print(json.dumps({'session_id': '$TEST_UUID', 'transcript_path': '/tmp/does-not-exist.jsonl', 'cwd': '$PWD'}))")
if echo "$start_payload" | HOOK_EVENT=start bash "$DEPLOY_DIR/lifecycle_generation.sh" &>/dev/null; then
    if [[ -f "$TEST_SIDECAR" ]] && grep -q '"event": *"start"' "$TEST_SIDECAR"; then
        pass "SessionStart hook writes a start event to the sidecar"
    else
        fail "SessionStart hook ran but sidecar missing/malformed: $TEST_SIDECAR"
    fi
else
    fail "lifecycle_generation.sh (start) exited non-zero"
fi

# Note: on SessionEnd this also fires a backgrounded `asm-sync --push
# $TEST_UUID` (R6.3) - harmless (no matching index file for this fake UUID,
# so asm-sync will find nothing to push) but intentionally last in the
# script so it can't race the sync assertions above.
end_payload=$(python3 -c "import json; print(json.dumps({'session_id': '$TEST_UUID', 'transcript_path': '/tmp/does-not-exist.jsonl', 'cwd': '$PWD'}))")
if echo "$end_payload" | HOOK_EVENT=end bash "$DEPLOY_DIR/lifecycle_generation.sh" &>/dev/null; then
    if grep -q '"event": *"end"' "$TEST_SIDECAR"; then
        pass "SessionEnd hook appends an end event to the sidecar"
    else
        fail "SessionEnd hook ran but no end event found in sidecar"
    fi
else
    fail "lifecycle_generation.sh (end) exited non-zero"
fi

cleanup_lifecycle
trap - EXIT

# ---------------------------------------------------------------------------
section "Summary"

echo ""
echo "  Passed: $PASS   Failed: $FAIL   Warnings: $WARN"
echo ""

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
