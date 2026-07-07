#!/usr/bin/env bash
#
# precompact-hook.sh
# Optional PreCompact hook for statusline-ctx.sh.
#
# Claude Code fires PreCompact just before it compacts the conversation, and
# pipes JSON on stdin that includes the session_id and a "trigger" field set to
# "manual" (you ran /compact) or "auto" (the window filled up). This hook records
# that trigger to a per-session flag file so the status line can show ⟲M or ⟲A on
# the next tick instead of guessing from the size of the token drop.
#
# Requires: bash + jq.
#
# Install:
#   1. cp precompact-hook.sh ~/.claude/precompact-hook.sh && chmod +x ~/.claude/precompact-hook.sh
#   2. Add a PreCompact hook to ~/.claude/settings.json (see README.md). No matcher
#      is needed: this script reads the trigger itself and handles both cases.

set -u

# One jq call: pull session_id and trigger from the hook payload on stdin.
IFS=$'\t' read -r SID TRIG < <(
  jq -r '[(.session_id // "default"), (.trigger // "auto")] | @tsv' 2>/dev/null
)

[ -z "${SID:-}" ] && exit 0   # malformed payload, nothing to record

case "$TRIG" in
  manual) FLAG=M ;;
  *)      FLAG=A ;;   # auto, or anything unexpected, treated as auto
esac

printf '%s\n' "$FLAG" > "/tmp/ccstatus-compact-${SID}"

# Emit nothing on stdout so we don't inject text into the compaction.
exit 0
