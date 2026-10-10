# Token Usage

A macOS menu bar app showing 5-hour and 7-day quota usage, with reset
countdowns, for **Claude Code** and **Codex** side by side.

```
C 47% · X 3%
```

With several Claude logins — the default one, any zetty accounts, and Tinker's —
the bar collapses Claude to whichever account is closest to a wall, so it stays the same
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

Once another tool keeps logins of its own, the list is grouped by the tool each
login belongs to. Every login is its own row with its own sources, even when
two of them are signed in as the same person:

```
Default
  Claude
  Codex
─────────
Zetty
  Devops
  Warda
─────────
Tinker
  Acme
```

## Nothing here is estimated

Both providers publish exact figures, and the app displays only those. A
provider that has never reported shows `—`, never `0%`. "No data" and "no
usage" are different claims, and the app never conflates them.

## Where the numbers come from

Claude has two sources and the app uses both. The **statusline captures** are
what keeps the 5-hour and 7-day figures moving: Claude Code hands them to the
statusline on every request, so they cost nothing and cannot be throttled. The
**usage API** is asked every five minutes for what the statusline never carries
— the per-model weekly limits — and for logins with no session open. Per limit,
whichever source knows the most wins (see [Merging readings](#merging-readings)).

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
ask for access, and an ad-hoc-signed development build would ask again after
every rebuild, even after "Always Allow". If the server rejects
the cached token, the app rereads the Keychain and retries once. Claude Code
continues to own token refresh; if the retry is also rejected, the app reports
**"sign-in expired — run `claude`"**.

Claude Code names each item's account after `$USER`, or `unknown` when it is
unset, so a process started without `$USER` leaves a second item under the same
service that holds only MCP tokens. The app asks for the current user's item
first and falls back to any item for the service, so that stray item cannot
shadow the login.

The endpoint is undocumented. If it changes shape or disappears, the app says
so and shows what the statusline captures carry — it never shows a number it
cannot justify.

It also throttles hard, and **per token**: polled once a minute it answered
`429` to two logins for most of a day while a third token on the same account
was still being served. So each login is polled on its own schedule (see
[Polling](#polling)), and while it is refused the row reads `statusline only`.

**Claude — several accounts.** zetty runs agent panes under named accounts, each
a separate Claude login with its own config directory. Tinker keeps one too, in
`~/Library/Application Support/Tinker/claude`. Every one is tracked, listed
under the tool it belongs to, and treated as an account in its own right.

Accounts come from `zetty accounts --json` when zetty is installed, and from a
scan of `~/.zetty/accounts` for directories containing `.claude.json` when it is
not. Asking zetty matters because that folder also holds **Codex** accounts, and
only zetty knows which is which — a naive scan invents a Claude account that
reports "not signed in" forever.

Each account's credential is a separate Keychain item: `Claude Code-credentials`
for the default login, and `Claude Code-credentials-<first 8 hex of sha256 of the
config directory path>` for the rest. An account is therefore the same usage API
pointed at a different item — no new endpoint, no new parser.

macOS asks once per account before this app may read its item.

**Claude — the statusline captures.** Optional and off by default. A shim
installed as your `statusLine.command` captures the payload Claude Code passes
it and hands stdin to your real statusline unchanged.

The shim is installed into `~/.claude/settings.json`, and any other login whose
`settings.json` names the same script runs it too — a zetty account created by
copying the default settings does. Every session writes its own file,
`claude-sessions/<session id>.json`, and a capture counts toward a login only
when its `transcript_path` lies inside that login's config directory, so one
login's quota is never shown under another's name.

One file per session matters because each session reports the quota as of *its
own* last request, and an idle one goes on repeating that figure for days.
Sharing a file is how a login at 75% came to be shown as 19%: seven sessions
took turns overwriting it and the one that rendered last was the one that knew
least. For the same reason the shim rewrites a session's file only when the API
has answered that session again — the limits moved, or `total_api_duration_ms`
grew — so a file's modification date is the date of its reading. Captures older
than eight days are deleted; nothing they describe can still be current.

Tinker's sessions run Tinker's own statusline rather than the shim, so for that
login the app reads the snapshot Tinker keeps in its `usage.json` instead.

- **It cannot break your statusline.** The passthrough is the final statement on
  every path, so a failed capture costs a usage update, never your status bar.
- **It chains, it does not replace**, has no dependencies (plain bash, no `jq`),
  and lives in `~/.claude/` rather than the app bundle so it cannot be orphaned.
- The delegated command is stored in a sidecar file as **data**, never
  interpolated into the script — a command containing quotes or `$(...)` would
  otherwise corrupt it, and Claude Code's own documented example contains both.
- **It is partial**: the statusline payload carries only `five_hour` and
  `seven_day`, and only what this machine's sessions have seen. Scoped weekly
  limits are invisible to it, so a row with no API answer behind it is labelled
  `statusline only`; hover for the reason.

`~/.claude/settings.json` is backed up before any change, and **Remove helper**
restores the original command verbatim. An update that ships a newer shim
replaces the installed script on launch — the script is the app's own file —
without touching any `settings.json`.

### Merging readings

A login can have a dozen readings at once: one per session, plus the API's. For
each limit the app keeps the reading for the **latest window** (an earlier one
has already reset) and, within it, the **highest percentage**. Usage only climbs
inside a window, so the highest figure is the newest whatever its timestamp
says, which is what makes the result immune to an idle session's stale number.
A reading is as fresh as the most recent one that agrees with it to within a
percent. The one thing this cannot follow is usage being lowered mid-window; a
row would then stay high until the window resets.

The captures are a floor, not a live figure: usage from claude.ai or another
machine reaches them only with the next request a local session makes.

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

Statusline captures are read whenever one changes; that is a directory listing
and the files that moved. Codex is read at most once a minute, since each read
spawns a process and FSEvents can fire repeatedly during active work.

The Claude usage API is asked once every **five minutes** per login. A `429`
doubles that login's wait — 10, 20, then 30 minutes, or the server's
`Retry-After` when that is longer — and the next success resets it. The endpoint
sends `retry-after: 0` while it goes on refusing, so a zero is not taken as
permission. On any failure the previous reading is kept rather than blanked;
its staleness marking already tells the truth about its age.

## Staleness

The API is current as of the last poll. Captures only move while a session is
making requests, so a login nobody is using has age on its readings. `resets_at`
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
Applications. Builds are Developer ID signed and notarized, so the download opens
without a Gatekeeper prompt. v0.1.4 was the last ad-hoc signed release; a fresh
download of it or anything earlier may need its quarantine attribute removed once:

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

Packaging signs the app with the hardened runtime, notarizes and staples it,
then signs, notarizes and staples the DMG around it. The release machine needs
two things for that, both in the keychain and neither in this repo: a
`Developer ID Application` certificate, and a notarytool profile named `notary`,
created once with `xcrun notarytool store-credentials notary`.
`scripts/package.sh --preflight` checks both without building, and `release.sh`
runs it before the version bump, so a signing problem stops the release before
anything is pushed. Set `TOKEN_USAGE_SIGN_IDENTITY` (a name or SHA-1 hash) when
the keychain holds more than one such certificate, and
`TOKEN_USAGE_NOTARY_PROFILE` to use a profile with another name.

On a machine without the certificate, `scripts/package.sh --adhoc` packages an
ad-hoc signed DMG that is not notarized. It is for local testing only and must
not be shipped.

## Privacy

The only network calls are to Anthropic's own usage endpoint — one per Claude
account — each authenticated with the token Claude Code already stores for that
account on this machine. Nothing is sent anywhere else, nothing is cached to
disk, and no token is ever written back.

Locally the app reads `~/.zetty/accounts` and each account's `.claude.json` (or
`~/.claude.json` for the default login) to learn which accounts exist and what to
call them, and Tinker's `usage.json` for that login's quota. It never reads a
session transcript. Codex data never leaves the
filesystem. Running with the API source disabled makes the app fully offline and
credential-free.
