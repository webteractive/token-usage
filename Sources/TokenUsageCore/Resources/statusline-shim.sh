#!/usr/bin/env bash
# Token Usage statusline shim — installed by the Token Usage menu bar app.
#
# Claude Code passes session JSON on stdin, including rate_limits (the 5-hour
# and 7-day quota), which it does not write anywhere else. This captures that
# payload and then hands stdin to the user's real statusline unchanged.
#
# Every failure path still delegates: losing a usage update is acceptable,
# losing the user's statusline is not.
#
# The delegated command is read from a sidecar file rather than baked into this
# script, so a command containing quotes or $(...) cannot corrupt this file.
#
# Uninstall by restoring statusLine.command in ~/.claude/settings.json.

input="$(cat)"

# One file per session. Each session reports the quota as of its own last
# request, so a single shared file would hold whichever session rendered last
# rather than whichever knows the most.
dir="__STATE_DIR__"

re_session='"session_id"[[:space:]]*:[[:space:]]*"([A-Za-z0-9_-]+)"'
re_limits='"rate_limits"[[:space:]]*:[[:space:]]*(\{([^{}]|\{[^{}]*\})*\})'
re_api='"total_api_duration_ms"[[:space:]]*:[[:space:]]*([0-9.]+)'

# The parts of a payload that move only when the API has answered: the limits
# themselves, and the time spent waiting on it.
stamp() {
  local limits="" api=""
  [[ $1 =~ $re_limits ]] && limits="${BASH_REMATCH[1]}"
  [[ $1 =~ $re_api ]] && api="${BASH_REMATCH[1]}"
  printf '%s|%s' "$limits" "$api"
}

if [[ $input =~ $re_session ]]; then
  state="$dir/${BASH_REMATCH[1]}.json"
  new="$(stamp "$input")"
  # An idle session re-renders the figures it already has. Rewriting them would
  # date an old reading as new, so the file is left alone and its modification
  # date stays the date of the reading. A payload with nothing to compare is
  # written every time, as it always was.
  if [ "$new" = "|" ] || [ ! -f "$state" ] \
    || [ "$new" != "$(stamp "$(cat "$state" 2>/dev/null)")" ]; then
    tmp="${state}.$$"
    mkdir -p "$dir" 2>/dev/null
    printf '%s' "$input" > "$tmp" 2>/dev/null && chmod 600 "$tmp" 2>/dev/null \
      && mv -f "$tmp" "$state" 2>/dev/null
    rm -f "$tmp" 2>/dev/null
  fi
fi

delegate=""
if [ -f "__DELEGATE_FILE__" ]; then
  delegate="$(cat "__DELEGATE_FILE__" 2>/dev/null)"
fi

if [ -n "$delegate" ]; then
  printf '%s' "$input" | exec /bin/sh -c "$delegate"
fi
exit 0
