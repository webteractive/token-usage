# Token Usage

A macOS menu bar app showing 5-hour and 7-day quota usage, with reset
countdowns, for **Claude Code** and **Codex** side by side.

```
C 47% · X 3%
```

Click for the full picture:

```
Claude
  5h    47%   resets in 2h 14m
  7d    31%   resets in 4d 3h
Codex
  5h     0%   window reset 3h ago
  7d   ‹ 1%   as of Aug 26, 15:28
```

## Nothing here is estimated

Both providers publish exact figures, and the app displays only those.

| | 5-hour | 7-day | Reset |
|---|---|---|---|
| Claude | `rate_limits.five_hour.used_percentage` | `.seven_day.used_percentage` | `resets_at` |
| Codex | `rate_limits.primary.used_percent` | `.secondary.used_percent` | `resets_at` |

A provider that has never reported shows `—`, never `0%`. "No data" and "no
usage" are different claims, and the app never conflates them.

## The Claude helper

Codex writes its quota to its session files, so it is read directly. Claude
Code does **not** — searching `~/.claude/projects` for it finds nothing. It
passes `rate_limits` to whatever command is configured as its **statusline**,
and nowhere else.

So the app installs a small shim as your `statusLine.command`. The shim
captures the payload and hands stdin to your real statusline unchanged.

- **It cannot break your statusline.** The passthrough is the final statement
  on every path, so a failed capture costs you a usage update, never your
  status bar.
- **It chains, it does not replace.** Whatever you had configured keeps running.
- **It has no dependencies** — plain bash, no `jq`. All parsing happens in Swift.
- **It is a standalone script in `~/.claude/`, deliberately not a binary inside
  the app bundle** — a bundle path would break your status bar if the app were
  ever moved or deleted.

`~/.claude/settings.json` is backed up before any change. **Settings → Remove
helper** restores the original `statusLine.command` verbatim.

If you rewire `statusLine.command` yourself afterwards, the app notices and
offers to re-chain rather than clobbering your change.

`rate_limits` is subscriber-only. On an API or Console account Claude
legitimately has no quota, and the app says so instead of showing zero.

## Staleness

Both sources only report while a session is running, so a reading can have age
on it. `resets_at` makes most of that self-healing:

| Condition | Shown |
|---|---|
| `resets_at` has passed | **0%** — provably reset, however old the reading |
| Reported within 10 min | The live figure |
| Otherwise | Last figure, dimmed and prefixed `‹`, with "as of" |

## Display modes

Switchable in Settings, with a live preview:

| Mode | Menu bar |
|---|---|
| Worst of all windows | `● 47%` |
| One per tool (default) | `C 47% · X 3%` |
| Rings | `◔ ◑` |
| All four | `C 47/31 · X 3/1` |

Severity is **never signalled by colour alone** — `●` normal, `▲` warning, `■`
critical — so it survives red-green colour deficiency and a busy wallpaper
behind a translucent menu bar. Thresholds default to 75% and 90% and are
configurable. There are no notifications; nothing ever steals focus.

## Building

```bash
tuist generate --no-open
xcodebuild -workspace TokenUsage.xcworkspace -scheme TokenUsage build
swift test          # core library
```

The core (state machine, parsers, renderer, installer) is a plain SPM library
with no SwiftUI dependency, so it is testable with `swift test` alone.

## Distribution

Reading `~/.claude` and `~/.codex` is incompatible with the App Store sandbox.
Ships unsandboxed, hardened runtime, notarized, via appdater.

## Privacy

No network access, no credentials, no API calls. Everything is read from local
files and stays on the machine.
