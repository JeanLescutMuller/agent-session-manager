---
# ── What
id: agent-session-manager#1
type: one-off
title: Deploy the machine-name rule (once src/asm is committed)
category: ops
# ── Who
owner: claude
autonomy: auto_mode
# ── Urgency
priority: 7 days
estimated_work_duration: 10 min
# ── When
not_before: 2026-10-11[Europe/Zurich]
planned_at: 2026-10-11[Europe/Zurich]
not_after:
# ── Status and claim
status: in-progress
claimed_since: 2026-10-10T20:46+02:00[Europe/Zurich]
claimed_by: chan-lescut-macbook-pro, claude, e64c2382-32f1-4948-9b43-9133bf9b2192
# ── Links
depends_on: []
todoist_id: 6hjCx2q8F3R264GV
# ── Origin
created_at: 2026-10-10T18:52+02:00[Europe/Zurich]
created_by: chan-lescut-macbook-pro, claude, ee3c8ee2-75f8-4935-9858-034a4100e230
---
## Context

On 2026-10-10 every project took one rule for the machine's name ("Machine name" in `~/AGENTS.md`). Here `src/lifecycle_generation.sh` and `src/status` are committed (`7a4f327`); `src/asm` has the same change (`machine_name()`, `LOCAL_HOSTNAME`) but is left **uncommitted**, because another session's unfinished edit (a grey UUID column, `C_UUID`) is in the same file. `install.sh` deploys the working tree, so nothing is deployed yet.

## Done when

`src/asm` is committed (the other session's edit finished or set aside), `bash install.sh` has run on the Mac and the VM, and `bash test/smoke_test.sh` passes on both; `status` prints `Hostname: chan-lescut-macbook-pro` / `H-Frank-1`.

## History

- 2026-10-10: created

## Links

- `~/AGENTS.md` "Machine name"; bootstrap-home `43957ec`

## Result
