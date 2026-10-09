# multi-host-orchestrator job: reindex local agent sessions, then rsync the index with the remote host.
# Deployed by install.sh to ~/opt/agent-session-manager/mho_var.sh; this machine's scheduler (launchd / systemd --user)
# starts ~/opt/multi-host-orchestrator/mho_entrypoint.sh on it every 10 min, which runs the job at most every 30 min.
# The job is named after this folder (agent-session-manager). Options: github.com/JeanLescutMuller/multi-host-orchestrator.
COMMAND='./asm-reindex-and-rsync.sh'
TIMEOUT_MIN=15
SUMMARY='^[[:space:]]*(Step 3b|Done):'
SKIP_IF_SUCCESS_SINCE=$((NOW - 30 * 60))
SKIP_IF_FAILURE_WITHIN_MIN=30
mho_skip() { online || echo offline; }
