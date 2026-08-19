#!/usr/bin/env bash
# csm-reindex-sync.sh - scheduled job (launchd/systemd): reindex, then sync.
#
# Deployed alongside this script, under bin/: csm, csm-sync. Uses absolute
# paths rather than relying on $PATH, since launchd/systemd invoke this with a
# minimal environment that usually doesn't include ~/.local/bin.
#
# No `set -e`: a failed reindex must never skip the sync step below it - sync
# has its own independent success/failure handling (and logs to
# ~/.csm/sync-log.jsonl), so it must always get a chance to run.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$SCRIPT_DIR/bin/csm" reindex || true
"$SCRIPT_DIR/bin/csm-sync" || true
