---
name: inject
description: Inject the content of a past Claude Code session into the current conversation. Use when csm resume determined true resume is not possible, or when the user asks to inject a past session by UUID or keywords.
allowed-tools: Read, Bash(cat *)
---

Inject the content of a past Claude Code session into the current conversation.

Use this when `csm resume` determined that true resume is not possible (the
original working directory does not exist on this machine).

## Instructions

1. **Parse the argument** from the user's message (passed after `/inject`):
   - If it looks like a UUID (hex with dashes, 36 chars), treat it as a session ID directly.
   - Otherwise, treat it as a search query: search `~/.claude/session-index-local/*.json`
     for sessions whose `custom_title` or conversation text contains the keywords,
     pick the most recently active match, and confirm with the user before loading.

2. **Load the index file**: `~/.claude/session-index-local/<uuid>.json`

3. **Display session metadata** to the user:
   - Title, working directory, hostname, last active timestamp, session state.

4. **Inject the conversation** into the current context by presenting it as a
   structured summary. Include:
   - Each message in chronological order, prefixed with role and timestamp.
   - Truncate very long messages to ~500 chars with a note if truncated.
   - If the conversation is short enough to fit fully, include it verbatim.

5. **Announce context injection** clearly:

   > **Context injected from session**: `<title>` (`<uuid>`)
   > Last active: `<last_active>` on `<hostname>` in `<working_dir>`
   > ⚠ This is NOT a true resume. This is a new session with injected context.
   >   The original session history is not extended.

6. **Resume assistance** as if you had been in the original session. Use the
   injected conversation to understand the prior work and continue from where
   it left off.

## Notes

- The JSON index is updated by `csm reindex` on a schedule (every 30 min via launchd).
  If the session is very recent, the index may not yet include its latest messages.
- If the UUID is not found, suggest running `csm resume "<keywords>"` from the
  terminal to identify the correct session.
- This creates a new `.jsonl` for the current session. The original session history
  is not modified or extended.
