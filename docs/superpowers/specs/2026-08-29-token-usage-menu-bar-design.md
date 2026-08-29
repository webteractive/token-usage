# Token Usage — macOS menu bar app

**Date:** 2026-08-29
**Status:** Approved, ready for implementation planning

## Purpose

Answer one question at a glance: **how much of my 5-hour and 7-day quota have I
used, and when does each reset** — for Claude Code and Codex together.

Explicitly out of scope: cost analytics, per-project breakdowns, per-model
attribution, historical trends. Quota windows only.

## Key finding

The premise this project started from was wrong in our favour.

Claude Code was believed to expose no local quota telemetry, forcing either an
estimated percentage or a shell-out to the interactive `/usage` command. Both
were unappealing; neither is necessary.

Claude Code passes a `rate_limits` object to the configured **statusline
command** on stdin. The contract is documented inside the binary
(`~/.local/share/claude/versions/2.1.251`):

```
"rate_limits": {          // Only present for subscribers, after first API response
  "five_hour": { "used_percentage": number, "resets_at": number },
  "seven_day": { "used_percentage": number, "resets_at": number },
  "spend_limit": { "used_percentage": number, "resets_at": number }  // gateway only
}
```

Grepping the session JSONL found nothing because the data is **pushed to the
statusline, never written to disk**.

Both providers therefore supply exact, authoritative figures. No estimation, no
calibration, no derived percentage anywhere in this app.

| | 5-hour | 7-day | Reset |
|---|---|---|---|
| Claude | `rate_limits.five_hour.used_percentage` | `.seven_day.used_percentage` | `resets_at` (epoch s) |
| Codex | `rate_limits.primary.used_percent` | `.secondary.used_percent` | `resets_at` (epoch s) |

Verified on this machine 2026-08-29: Claude Code 2.1.251, Codex `plan_type:
"plus"`, `window_minutes` 300 / 10080.

### Consequence: no corpus parsing

`~/.claude/projects` (763 MB, 1,594 files) and `~/.codex/sessions` (1.0 GB, 444
files) are **never scanned**. Percentages need no token math. Claude's data
arrives pushed; Codex needs only the tail of the newest rollout — measured at
**18 ms** despite a 328 MB file in the corpus. The incremental cache this
project originally anticipated is not built.

## Architecture

Two independent collectors write small state files. The app watches them.

```
Claude Code ──stdin JSON──▶ shim ──┬──▶ claude-raw.json (atomic, 0600)
                                   └──▶ statusline.sh (untouched) ──▶ stdout

~/.codex/sessions ──FSEvents──▶ CodexCollector ──▶ codex.json
                                (newest by mtime → tail → parse)

                    both files ──FSEvents──▶ MenuBarExtra app
```

No network. No credentials. No API calls. No scraping.

### The shim

Installed as `statusLine.command`, delegating to the user's existing script:

```bash
input="$(cat)"
printf '%s' "$input" > "$TMP" 2>/dev/null && mv -f "$TMP" "$STATE/claude-raw.json" 2>/dev/null
printf '%s' "$input" | exec "$HOME/.claude/statusline.sh"
```

`$STATE` and the delegate path are written as literals by `ShimInstaller` at
install time, not resolved at runtime — the shim reads no configuration of its
own. `$TMP` is a sibling of the state file so `mv` stays atomic within one
filesystem. `$STATE` is
`~/Library/Application Support/TokenUsage/`.

Design constraints, in priority order:

1. **It can never break the statusline.** The passthrough `exec` is the final
   statement and runs regardless of whether the state write succeeded. Worst
   realistic case is a missed usage update.
2. **Zero dependencies.** It does no parsing — not even `jq` — so there is
   nothing to be missing. All parsing happens in Swift, where it is unit-tested.
3. **Plain script in `~/.claude/`, deliberately not a binary inside the app
   bundle.** A bundle path in `statusLine.command` would be orphaned if the app
   were moved or deleted, breaking the status bar. A standalone script cannot be.

The raw payload contains session metadata (cwd, branch, session id, model)
already present elsewhere on disk. Written `0600`, overwritten each render.

This is the only part of the system that modifies user configuration and
requires explicit consent.

## Components

Everything above the IO line is pure and testable with an injected clock.

**Core (pure):**

```
UsageWindow     usedPercent, resetsAt, observedAt
  └ state(now:) → WindowState
WindowState     .live(pct) | .stale(pct, since:) | .reset | .unknown
ProviderUsage   fiveHour: UsageWindow?, sevenDay: UsageWindow?
Severity        .normal | .warning | .critical   (pct + thresholds)
```

**Parsers (pure):** `ClaudeStatuslineParser`, `CodexRolloutParser` — both emit
`ProviderUsage`. Vendor key differences (`used_percentage` vs `used_percent`,
`five_hour`/`seven_day` vs `primary`/`secondary`) are normalised here and
nowhere else. Nothing downstream knows which tool a number came from; a third
provider is one new parser, not a change everywhere.

**IO (thin):** `StateStore` (atomic read/write), `FileWatcher` (FSEvents),
`CodexCollector`, `ShimInstaller`.

**UI:** `UsageViewModel` (`@Observable`) → `MenuBarLabelRenderer` (pure:
`[ProviderUsage] + DisplayMode → label`) → `DropdownView`, `SettingsView`.

## Staleness

Both sources only report while a session runs. `resets_at` makes most staleness
self-healing — only one of three states is uncertain.

| Condition | Reading |
|---|---|
| `now >= resetsAt` | **0%** — window provably rolled over. Certain despite stale data. |
| `now - observedAt <= liveWindow` | Live figure |
| Otherwise | Last figure, **marked stale** + "as of HH:MM" |

`liveWindow` is **10 minutes**. The statusline re-renders on every session
update, so gaps under 10 minutes are normal within active work (a long tool
call, extended thinking); beyond that the session has almost certainly ended.
Chosen high enough not to flap mid-session, low enough to catch a closed
terminal. A single named constant, trivially tuned after real use.

`state(now:)` is a pure function; the entire decision is one testable
expression with no mocking.

## Display

Four modes, switchable in Settings with live preview. Default: **per-tool**.

| Mode | Menu bar | Shows |
|---|---|---|
| Worst-of | `● 47%` | Highest of all four windows |
| **Per-tool** (default) | **`C 47% · X 3%`** | Each tool's higher window |
| Rings | `◔ ◑` | One ring per tool, arc filled to that tool's higher window |
| Full | `C 47/31 · X 3/1` | All four, as `5h/7d` pairs |

Every mode reduces to each tool's **higher** window, not its 5-hour one — the
nearest wall is the one worth showing. Rings are drawn, not glyphs: a stroked
arc rendered at menu bar point size, filled proportionally, taking severity
colour and carrying the same shape cue at threshold.

### Signalling

No notifications. Nothing steals focus. Severity is shown passively — but
**never by colour alone**: amber-vs-red is the pair red-green colour deficiency
collapses (~8% of men), and translucent menu bars sit over arbitrary
wallpapers. Every severity carries a redundant shape cue.

```
normal    C 47%      default label colour, adapts to light/dark bar
warning   C ▲ 78%    amber + triangle
critical  C ■ 93%    red + filled square
stale     C ‹47%     dimmed + ‹ prefix
```

### Dropdown

All four numbers with countdowns, regardless of display mode:

```
Claude
  5h    47%   resets in 2h 14m
  7d    31%   resets in 4d 3h
Codex
  5h     0%   window reset 3h ago
  7d   ‹ 1%   as of Aug 26, 15:28
──────────────────────────────
Settings…                  Quit
```

**Settings:** display mode · warning threshold (default 75) · critical
threshold (default 90) · launch at login · shim status with Install/Uninstall.

### No data ≠ no usage

A provider that has never reported shows `—`, never `0%`. Conflating "no data"
with "no usage" is the exact dishonesty this design exists to avoid. The
dropdown row states which case applies, with a one-click fix for the shim.

## Failure modes

`ShimInstaller` must handle four states, each of which fails quietly if
mishandled:

| Situation | Behaviour |
|---|---|
| No statusline configured | Shim delegates to nothing, prints nothing |
| Existing statusline | Original command recorded; shim delegates to it |
| Already installed | Idempotent — no double-wrap |
| Manually edited since install | Detect, do not clobber, ask |

`settings.json` is backed up before any write. Uninstall restores
`statusLine.command` verbatim.

Others, each with a defined answer rather than a crash:

- **Not a subscriber** — `rate_limits` is documented as subscriber-only.
  API/Console users legitimately have no quota. Shows `—` with the reason.
- Malformed or half-written state file → `.unknown`. Atomic rename on write,
  tolerant parse on read.
- Codex tail chunk contains no `rate_limits` → widen the read once, then `—`.
- FSEvents coalescing → debounced.
- `resets_at` is epoch UTC → rendered in local time; countdowns survive
  timezone changes and DST.

## Distribution

Reading `~/.claude` and `~/.codex` is incompatible with the App Store sandbox.
Ships through **appdater**: unsandboxed, hardened runtime, notarized. Recorded
because it forecloses App Store distribution later.

Swift 6.3.3 / Xcode 26.6, SwiftUI `MenuBarExtra`.

Pre-ship pass is `prepare-for-release` (Swift project, not `prepare-for-production`).

## Testing

The pure core carries the interesting logic, so most tests need no mocking.

- `WindowState` transitions with an injected clock, at the boundaries:
  just-stale, just-reset, reset-while-stale, never-seen.
- Both parsers against **fixtures captured from real data on 2026-08-29**,
  including awkward cases: `<synthetic>` model entries, the passed-`resets_at`
  Codex reading, absent `rate_limits`.
- `MenuBarLabelRenderer` across 4 modes × 3 severities × stale/live.
- `ShimInstaller` against a temp `HOME`: install → assert stdout byte-identical
  to the unwrapped statusline → uninstall → assert `settings.json` restored.

---

# Revision — 2026-08-29: the usage API supersedes the statusline

## What was wrong

The design above modelled Claude's quota as a **fixed pair** of windows,
`five_hour` and `seven_day`, because that is all the statusline payload carries.

Running `/usage` showed a third: **Current week (Fable), 4%** — a per-model
weekly cap the app could not see. Under-reporting a window is the exact failure
this app exists to prevent: if a scoped weekly limit passed the all-models one,
the app would have shown a comfortable number while the user was blocked.

The per-model fields (`seven_day_opus`, `seven_day_sonnet`) exist in the Claude
Code binary but are **not** exposed to the statusline. Verified against the
documented statusline schema, which lists only `five_hour`, `seven_day`, and
`spend_limit`.

## The better source

`GET https://api.anthropic.com/api/oauth/usage`, authenticated with the OAuth
access token Claude Code stores in the login Keychain
(`Claude Code-credentials` → `claudeAiOauth.accessToken`). Probed live and
confirmed: HTTP 200, returning the same data `/usage` renders.

The valuable part is a normalised, display-ready `limits` **array**:

```json
{"kind":"session",       "percent":62, "severity":"normal",  "resets_at":ISO8601, "scope":null}
{"kind":"weekly_all",    "percent":86, "severity":"warning", "resets_at":ISO8601, "scope":null, "is_active":true}
{"kind":"weekly_scoped", "percent":4,  "severity":"normal",  "resets_at":ISO8601,
 "scope":{"model":{"display_name":"Fable"}}}
```

Self-describing (the model name comes from the server), ordered by `kind`, and
carrying `is_active` to mark the binding limit.

Note the format differs from the statusline: `resets_at` is ISO8601 with
fractional seconds and an offset, not epoch seconds.

## Consequences

**The model generalises.** `ProviderUsage` becomes a list of `QuotaWindow`, each
with a `WindowKind` (`.session`, `.weeklyAll`, `.weeklyScoped(model:)`,
`.other(String)`). Unknown kinds are **preserved, not dropped** — the endpoint's
list is open-ended, and discarding an unrecognised limit reintroduces the
original bug. Codex's `primary`/`secondary` map onto `.session`/`.weeklyAll`.

**The API is more capable *and* less invasive.** It removes the need for the
shim — the riskiest component, the only one that modifies user configuration and
could break the user's terminal. It also eliminates staleness for Claude
entirely, since the data is fetched live rather than arriving only while a
session runs.

**The shim is demoted, not deleted.** The endpoint is undocumented and could
change with any Claude Code release. The shim (already built and tested) remains
as a fallback that degrades to two windows rather than dying, and is uninstalled
by default. The UI labels the active source, marking the fallback
`statusline · partial` so a partial view is never mistaken for a complete one.

**Credentials.** The token is read fresh from the Keychain per request, never
cached to disk and never written back — Claude Code owns that item and refreshes
it during normal use. On 401 the app reports "sign-in expired — run `claude`"
rather than racing Claude Code to refresh it.

**Privacy claim narrowed.** The original spec claimed no network and no
credentials. That now holds only with the API source disabled; the README states
the actual position.

---

# Revision 2 — 2026-08-29: Codex moves to the app-server

## Same gap, same fix

Codex's rollout files carry one bucket. The app-server's
`account/rateLimits/read` returns `rateLimitsByLimitId`, which on this machine
also contains `base_model_inference` ("gpt-reserve") — a scoped weekly limit
invisible to the files, exactly analogous to Claude's Fable window. The
generalised `[QuotaWindow]` model absorbed it without change.

## Why not the HTTP endpoint

`https://chatgpt.com/api/codex/usage` exists and is what the CLI calls, but it
is unreachable from a plain client:

```
HTTP/2 403
cf-mitigated: challenge
server: cloudflare
```

A valid token makes no difference — this is Cloudflare bot management, not
authorisation. Passing it would require impersonating a browser's TLS
fingerprint: circumvention, and brittle against any change on their side.
`api.anthropic.com` has no such gate, which is why the two providers use
different transports.

Speaking JSON-RPC to `codex app-server` over stdio avoids the problem entirely
and means the app never handles Codex credentials.

Two details cost a debugging cycle each and are worth recording:
- **stdin must stay open until the response arrives.** The server treats EOF as
  "client is done" and exits, returning nothing.
- **Responses are interleaved with unsolicited notifications**, so the reader
  must match on the request id rather than taking the first line of output.
- The binary must be located by absolute path: a GUI app does not inherit the
  shell `PATH`.

## Polling discipline

Both live sources are throttled to at most once per provider per minute, and the
tick moved from 30s to 60s. The Claude usage endpoint rate-limits its own callers
— observed `429` while probing — and each Codex read spawns a process, while
FSEvents fires repeatedly during active work. On transient failure the previous
reading is retained rather than blanked; its staleness marking already states
its age honestly.

## Source labelling

`ClaudeSource` generalised to a shared `SourceStatus` (`.live`, `.degraded`,
`.unavailable`) used by both providers, since both now have a live source and a
degraded fallback. The dropdown shows it per provider, so a partial view is
never mistaken for the whole picture.
