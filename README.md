# Token Usage

A macOS menu bar app showing 5-hour and 7-day quota usage, with reset
countdowns, for **Claude Code** and **Codex** side by side.

```
C 47% · X 3%
```

With several Claude logins — the default one plus any zetty accounts — the bar
collapses Claude to whichever account is closest to a wall, so it stays the same
width however many you add:

```
C ▲ 80% · X 3%
```

Switch to **One per account** to see them side by side:

```
G 47% · W 12% · D ▲ 80% · X 3%
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

Token handling: read from the Keychain once, through `/usr/bin/security` rather
than the Keychain API, and cached only in process memory until expiry, never
cached to disk and never written back. Claude Code writes the item with
`security`, so reading it the same way never prompts; reading it directly would
ask again after every ad-hoc-signed build, even after "Always Allow". If the server rejects
the cached token, the app rereads the Keychain and retries once. Claude Code
continues to own token refresh; if the retry is also rejected, the app reports
**"sign-in expired — run `claude`"**.

The endpoint is undocumented. If it changes shape or disappears, the app says
so and falls back — it never shows a number it cannot justify.

**Claude — several accounts.** zetty runs agent panes under named accounts, each
a separate Claude login with its own config directory. Every one is tracked.

Accounts come from `zetty accounts --json` when zetty is installed, and from a
scan of `~/.zetty/accounts` for directories containing `.claude.json` when it is
not. Asking zetty matters because that folder also holds **Codex** accounts, and
only zetty knows which is which — a naive scan invents a Claude account that
reports "not signed in" forever.

Each account's credential is a separate Keychain item: `Claude Code-credentials`
for the default login, and `Claude Code-credentials-<first 8 hex of sha256 of the
config directory path>` for the rest. An account is therefore the same usage API
pointed at a different item — no new endpoint, no new parser.

macOS asks once per account before this app may read its item. The statusline
fallback below covers the **default account only** — the shim lives in
`~/.claude/settings.json` and sees nothing else — so a non-default account whose
API call fails reports "last known" or "unavailable" rather than falling back.

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

**Codex — the app-server.** The app speaks JSON-RPC to `codex app-server` over
stdio (`account/rateLimits/read`). Like Claude's API source it is live, and it
carries `rateLimitsByLimitId` — scoped buckets such as `base_model_inference`
("gpt-reserve") that a session file never contains.

Calling `https://chatgpt.com/api/codex/usage` directly the way the Claude source
does **does not work**: that host sits behind Cloudflare bot management and
answers a plain client with `403 cf-mitigated: challenge` no matter how valid
the token. Getting past it would mean impersonating a browser's TLS fingerprint
— circumvention, and brittle. Letting Codex's own binary make the call sidesteps
it, and means this app never handles Codex credentials at all.

**Codex — the rollout fallback.** If the app-server is unavailable, the newest
rollout file is tail-read instead. Partial: one bucket only, and only as fresh
as the last session.

## Polling

Live sources are throttled to at most once a minute per provider. The Claude
usage endpoint rate-limits its own callers (it answers `429` under load) and each
Codex read spawns a process, while FSEvents can fire repeatedly during active
work. On a transient failure the previous reading is kept rather than blanked —
its staleness marking already tells the truth about its age.

## Staleness

The live sources are current as of the last poll. The fallbacks only report
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
| One per account | `G 47% · W 12% · D ▲ 86% · X 1%` |
| Every window | `C ▲ 65/86/4 · X 0/1` |

Severity is **never signalled by colour alone** — `▲` warning, `■` critical —
so it survives red-green colour deficiency and a busy wallpaper behind a
translucent menu bar. A normal reading carries no marker in the per-tool
modes; only *Worst of all windows* shows `●`, where the marker doubles as the
segment's identity glyph. Thresholds default to 75% and 90% and are
configurable. There are no notifications; nothing ever steals focus.

## Building

```bash
tuist generate --no-open
xcodebuild -workspace TokenUsage.xcworkspace -scheme TokenUsage build
swift test          # core library
```

The core (state machine, parsers, renderer, installer) is a plain SPM library
with no SwiftUI dependency, so it is testable with `swift test` alone.

The app icon is drawn in code. `swift scripts/make-icon.swift` regenerates every
size into `App/Resources/Assets.xcassets/AppIcon.appiconset`.

## Download and updates

Reading `~/.claude` and `~/.codex` is incompatible with the App Store sandbox,
so Token Usage ships outside the App Store through
[GitHub Releases](https://github.com/webteractive/token-usage/releases).

Download `TokenUsage-<version>.dmg`, open it, and drag **TokenUsage** into
Applications. Current builds are ad-hoc signed rather than Developer ID signed,
so a fresh download may need its quarantine attribute removed once:

```bash
xattr -dr com.apple.quarantine /Applications/TokenUsage.app
```

Token Usage checks GitHub for a newer release on launch and every six hours.
Automatic checks can be disabled in Settings; **Check Now** remains available.
When an update exists, the app downloads its DMG and `.sha256` sidecar, verifies
the checksum, stages and validates the bundle, then swaps it into place and
restarts. The previous bundle is kept until the replacement is verified and is
restored automatically if the copy fails.

## Releasing

```bash
scripts/package.sh
scripts/release.sh --notes notes.md patch --dry-run
scripts/release.sh --notes notes.md patch
```

`scripts/release.sh` is the release entry point. It requires human-written
notes and a clean `main`, runs the test suite, bumps the version in
`Project.swift`, packages `TokenUsage-<version>.dmg` and its checksum sidecar,
tags the release, and uploads both assets. The sidecar is required by the in-app
updater, so releases should not be assembled manually.

## Privacy

The only network calls are to Anthropic's own usage endpoint — one per Claude
account — each authenticated with the token Claude Code already stores for that
account on this machine. Nothing is sent anywhere else, nothing is cached to
disk, and no token is ever written back.

Locally the app reads `~/.zetty/accounts` and each account's `.claude.json` (or
`~/.claude.json` for the default login) to learn which accounts exist and what to
call them. It never reads a session transcript. Codex data never leaves the
filesystem. Running with the API source disabled makes the app fully offline and
credential-free.
