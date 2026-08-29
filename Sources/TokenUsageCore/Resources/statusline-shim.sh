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
# Uninstall by restoring statusLine.command in ~/.claude/settings.json.

input="$(cat)"

state="__STATE_FILE__"
tmp="${state}.$$"
mkdir -p "$(dirname "$state")" 2>/dev/null
printf '%s' "$input" > "$tmp" 2>/dev/null && chmod 600 "$tmp" 2>/dev/null \
  && mv -f "$tmp" "$state" 2>/dev/null
rm -f "$tmp" 2>/dev/null

delegate="__DELEGATE__"
if [ -n "$delegate" ]; then
  printf '%s' "$input" | exec /bin/sh -c "$delegate"
fi
exit 0
