#!/usr/bin/env bash
#
# statusline-ctx.sh
# Claude Code statusline: context fill + per-turn delta + growth sparkline + rate limits.
#
# Example output:
#   Opus (132k/1M, 13%) ▲+3.4k ▁▂▂▃▅ | 5h 22% | 7d 41%
#
# Design goals:
#   * Exactly ONE subprocess fork per tick (jq). Everything else is pure bash arithmetic.
#   * No git, no date, no stat calls. State is read/written with shell redirection only.
#   * Stateless statusline made stateful via a tiny per-session file keyed by session_id.
#
# Requires: bash + jq. See README.md for install notes (Linux, macOS, WSL, Git Bash).
#
# Install:
#   1. cp statusline-ctx.sh ~/.claude/statusline-ctx.sh && chmod +x ~/.claude/statusline-ctx.sh
#   2. Add to ~/.claude/settings.json:
#        { "statusLine": { "type": "command", "command": "~/.claude/statusline-ctx.sh" } }
#
# Optional env toggles:
#   CTX_SPARK_WIDTH   number of points in the sparkline window (default 8)
#   CTX_COMPACT_MIN   min token drop counted as a compaction, labeled ⟲ (default 5000)
#   CTX_NO_COLOR=1    disable ANSI color
#
# Color thresholds and the idea of surfacing context fill alongside the 5h/7d
# rate limits were inspired by daniel3303/ClaudeCodeStatusLine. No code reused.
# JSON field names come from the official Claude Code statusline docs.
#
# Test with mock input:
#   echo '{"model":{"display_name":"Opus"},"context_window":{"total_input_tokens":132000,"context_window_size":1000000,"used_percentage":13},"rate_limits":{"five_hour":{"used_percentage":22},"seven_day":{"used_percentage":41}},"session_id":"test"}' | ./statusline-ctx.sh

set -u

# jq is required. Without it, show a visible hint instead of a cryptic blank line.
if ! command -v jq >/dev/null 2>&1; then
  echo "[statusline-ctx: jq not installed (see README)]"
  exit 0
fi

SPARK_WIDTH="${CTX_SPARK_WIDTH:-8}"
# A negative delta at least this large is treated as a compaction (or /clear)
# rather than a minor cache wobble, and is labeled with ⟲ instead of ▼.
COMPACT_MIN="${CTX_COMPACT_MIN:-5000}"

# --- single fork: parse everything jq needs in one pass -----------------------
# -1 sentinel marks an absent rate-limit block (only present for Pro/Max subs).
IFS=$'\t' read -r MODEL TOK MAX PCT FIVE_H SEVEN_D SESSION_ID < <(
  jq -r '[
    (.model.display_name // "Claude"),
    (.context_window.total_input_tokens // 0),
    (.context_window.context_window_size // 0),
    (.context_window.used_percentage // 0),
    (.rate_limits.five_hour.used_percentage // -1),
    (.rate_limits.seven_day.used_percentage // -1),
    (.session_id // "default")
  ] | @tsv' 2>/dev/null
)

# jq failed or fed no data: print a minimal line and exit cleanly.
[ -z "${MODEL:-}" ] && { echo "[Claude]"; exit 0; }

# Strip any decimals jq may emit (used_percentage and rate limits can be floats).
TOK=${TOK%%.*}; MAX=${MAX%%.*}; PCT=${PCT%%.*}
FIVE_H=${FIVE_H%%.*}; SEVEN_D=${SEVEN_D%%.*}

# --- pure-bash helpers (no forks) --------------------------------------------

# fmt <int> -> human number: 1320000->1.3M, 132000->132k, 850->850
fmt() {
  local v=$1 whole frac
  if   [ "$v" -ge 1000000 ]; then
    whole=$((v / 1000000)); frac=$(( (v / 100000) % 10 ))
    [ "$frac" -eq 0 ] && printf '%sM' "$whole" || printf '%s.%sM' "$whole" "$frac"
  elif [ "$v" -ge 1000 ]; then
    whole=$((v / 1000)); frac=$(( (v / 100) % 10 ))
    [ "$frac" -eq 0 ] && printf '%sk' "$whole" || printf '%s.%sk' "$whole" "$frac"
  else
    printf '%s' "$v"
  fi
}

# --- state: per-session token history, newest last ---------------------------
STATE="/tmp/ccstatus-ctx-${SESSION_ID}"
HIST=""
[ -r "$STATE" ] && read -r HIST < "$STATE"

# Before the first API response total is 0. Don't record it or it inflates the
# first real delta. Show a placeholder delta until real data arrives.
DELTA_STR="—"
if [ "$TOK" -gt 0 ]; then
  # shellcheck disable=SC2206
  arr=($HIST)
  if [ "${#arr[@]}" -gt 0 ]; then
    last=${arr[${#arr[@]}-1]}
    d=$((TOK - last))
    if   [ "$d" -gt 0 ]; then DELTA_STR="▲+$(fmt "$d")"
    elif [ "$d" -lt 0 ]; then
      ad=$((-d))
      if [ "$ad" -ge "$COMPACT_MIN" ]; then DELTA_STR="⟲ -$(fmt "$ad")"
      else                                  DELTA_STR="▼-$(fmt "$ad")"
      fi
    else                      DELTA_STR="●0"
    fi
  fi
  # Append current, trim to the sparkline window.
  arr+=("$TOK")
  while [ "${#arr[@]}" -gt "$SPARK_WIDTH" ]; do arr=("${arr[@]:1}"); done
  HIST="${arr[*]}"
  printf '%s\n' "$HIST" > "$STATE"
fi

# --- sparkline over the recorded history (pure bash) -------------------------
SPARK=""
# shellcheck disable=SC2206
pts=($HIST)
if [ "${#pts[@]}" -ge 1 ]; then
  blocks=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)
  mn=${pts[0]}; mx=${pts[0]}
  for p in "${pts[@]}"; do
    [ "$p" -lt "$mn" ] && mn=$p
    [ "$p" -gt "$mx" ] && mx=$p
  done
  range=$((mx - mn))
  for p in "${pts[@]}"; do
    if [ "$range" -le 0 ]; then lvl=0
    else lvl=$(( ((p - mn) * 7 + range / 2) / range )); fi
    SPARK+="${blocks[$lvl]}"
  done
fi

# --- color by fill threshold (thresholds match daniel3303/ClaudeCodeStatusLine) ---
if [ "${CTX_NO_COLOR:-0}" = "1" ]; then
  C="" ; R=""
else
  R=$'\033[0m'
  if   [ "$PCT" -ge 90 ]; then C=$'\033[31m'       # red
  elif [ "$PCT" -ge 70 ]; then C=$'\033[38;5;208m' # orange
  elif [ "$PCT" -ge 50 ]; then C=$'\033[33m'       # yellow
  else                         C=$'\033[32m'       # green
  fi
fi

# --- rate limit segment (only if present) ------------------------------------
RL=""
[ "$FIVE_H"  -ge 0 ] 2>/dev/null && RL=" | 5h ${FIVE_H}%"
[ "$SEVEN_D" -ge 0 ] 2>/dev/null && RL="${RL} | 7d ${SEVEN_D}%"

# --- render ------------------------------------------------------------------
printf '%b\n' "${MODEL} (${C}$(fmt "$TOK")/$(fmt "$MAX"), ${PCT}%${R}) ${DELTA_STR} ${SPARK}${RL}"
