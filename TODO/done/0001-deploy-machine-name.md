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
status: done
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
- 2026-10-10: claimed, done (chan-lescut-macbook-pro, claude, e64c2382-32f1-4948-9b43-9133bf9b2192). The grey UUID column turned out to be the user's own request of 2026-09-15 (session e09dc060), deployed then but never committed; committed as is.

## Links

- `~/AGENTS.md` "Machine name"; bootstrap-home `43957ec`

## Result

- `src/asm` committed: `afe926b` (machine name), `b13d20c` (UUID column), pushed.
- `install.sh` exit 0 on the Mac and on H-Frank-1 (VM from `git archive HEAD`).
- `test/smoke_test.sh`: Mac 41 passed / 0 failed; VM 37 passed / 0 failed / 4 warnings (no Codex on the VM).
- `status` on the Mac: `Hostname: chan-lescut-macbook-pro`. On the VM `status` needs a live Claude session, so checked `asm`'s `LOCAL_HOSTNAME` there instead: `H-Frank-1`.
