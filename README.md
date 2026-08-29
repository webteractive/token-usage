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

Both providers publish exact figures, and the app displays only those. A
provider that has never reported shows `—`, never `0%`. "No data" and "no
usage" are different claims, and the app never conflates them.

## Where the numbers come from

**Claude — the OAuth usage API.** The app reads Claude Code's access token from
the login Keychain (`Claude Code-credentials`) and calls
`https://api.anthropic.com/api/oauth/usage`. That returns the same `limits`
list `/usage` renders:

```json
{"kind":"session",       "percent":63, "scope":null}
{"kind":"weekly_all",    "percent":86, "scope":null,                        "is_active":true}
{"kind":"weekly_scoped", "percent":4,  "scope":{"model":{"display_name":"Fable"}}}
```

It is a **list**, so per-model weekly caps and any window Anthropic adds later
appear automatically. Unknown kinds are preserved rather than dropped —
silently discarding a limit is how you fail to warn someone about the one
that is about to block them.

Token handling: read fresh from the Keychain per request, never cached to disk,
never written back. The token is short-lived and Claude Code refreshes it during
normal use, so on a 401 the app reports **"sign-in expired — run `claude`"**
rather than racing Claude Code to refresh the same Keychain item.

The endpoint is undocumented. If it changes shape or disappears, the app says
so and falls back — it never shows a number it cannot justify.

**Claude — the statusline fallback.** Optional and off by default. A shim
installed as your `statusLine.command` captures the payload Claude Code passes
it and hands stdin to your real statusline unchanged.

- **It cannot break your statusline.** The passthrough is the final statement on
  every path, so a failed capture costs a usage update, never your status bar.
- **It chains, it does not replace**, has no dependencies (plain bash, no `jq`),
  and lives in `~/.claude/` rather than the app bundle so it cannot be orphaned.
- The delegated command is stored in a sidecar file as **data**, never
  interpolated into the script — a command containing quotes or `$(...)` would
  otherwise corrupt it, and Claude Code's own documented example contains both.
- **It is partial**: the statusline payload carries only `five_hour` and
  `seven_day`. Scoped weekly limits are invisible to it, so the app labels this
  source `statusline · partial` when it is in use.

`~/.claude/settings.json` is backed up before any change, and **Remove helper**
restores the original command verbatim.

**Codex — the rollout files.** Codex persists `rate_limits` on `token_count`
events, so the newest rollout is tail-read directly. No credentials, no network.

## Staleness

The API source is always live. The statusline fallback and Codex only report
while a session is running, so those readings can have age on them. `resets_at`
makes most of that self-healing:

| Condition | Shown |
|---|---|
| `resets_at` has passed | **0%** — provably reset, however old the reading |
| Reported within 10 min | The live figure |
| Otherwise | Last figure, dimmed and prefixed `‹`, with "as of" |

## Display modes

Switchable in Settings, with a live preview:

| Mode | Menu bar |
|---|---|
| Worst of all windows | `● 86%` |
| One per tool (default) | `C ▲ 86% · X 1%` |
| Rings | `◔ ◑` |
| Every window | `C ▲ 63/86/4 · X 0/1` |

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

The only network call is to Anthropic's own usage endpoint, authenticated with
the token Claude Code already stores on this machine. Nothing is sent anywhere
else, nothing is cached to disk, and the token is never written back. Codex data
never leaves the filesystem. Running with the API source disabled makes the app
fully offline and credential-free.
