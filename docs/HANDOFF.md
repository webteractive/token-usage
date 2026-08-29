# Handoff — token-usage menu bar app

## What it is

Native Swift `MenuBarExtra` app showing 5-hour and weekly quota usage plus reset
countdowns for **Claude Code** and **Codex**, side by side. Quota windows only —
cost analytics, per-project breakdowns and historical trends are out of scope.

## State

On `main`, working tree clean, 20 commits. **105 tests passing** (1 opt-in live
test skipped), `xcodebuild` clean, app runs. Layout follows `~/AI/zetty`: Tuist +
local SPM package, XCTest, `co.webteractive.tokenusage`, macOS 14, Swift 6.

- `Sources/TokenUsageCore/` — pure core, testable with `swift test` alone
- `App/` — SwiftUI only, 7 files
- `docs/superpowers/specs/2026-08-29-token-usage-menu-bar-design.md` — design plus
  **two revision sections**; read those, they record why the architecture changed
  twice
- `docs/superpowers/plans/2026-08-29-token-usage-menu-bar.md` — original plan,
  now partly superseded

Build: `tuist generate --no-open` then
`xcodebuild -workspace TokenUsage.xcworkspace -scheme TokenUsage build`.
**Tuist globs `App/**` at generate time — regenerate after adding a file or the
build fails confusingly.**

## Data sources — read this carefully

Every figure is exact. **Nothing is estimated anywhere, deliberately.** A provider
with no data shows an em dash, never `0%`.

**Claude, live:** `GET https://api.anthropic.com/api/oauth/usage`, Bearer token
read fresh from the Keychain (`Claude Code-credentials` -> `claudeAiOauth.accessToken`).
Returns a normalised `limits` **array**: `session`, `weekly_all`, `weekly_scoped`
(with `scope.model.display_name`, e.g. "Fable"). Undocumented endpoint.

**Codex, live:** JSON-RPC over stdio to `codex app-server`
(`account/rateLimits/read`). Returns `rateLimitsByLimitId` — multiple buckets
including scoped ones like `base_model_inference` ("gpt-reserve").

**Do not "simplify" Codex to a direct HTTP call.** `chatgpt.com/api/codex/usage`
exists and is what the CLI calls, but a plain client gets
`403 cf-mitigated: challenge` — Cloudflare bot management, not auth. A valid token
changes nothing. Passing it would mean impersonating a browser TLS fingerprint:
circumvention and brittle. Driving Codex's own binary avoids it and means the app
never handles Codex credentials.

**Fallbacks (both partial, labelled as such in the UI):**
- Claude: a statusline shim capturing the payload Claude Code passes to
  `statusLine.command`. Only `five_hour`/`seven_day` — scoped weekly caps are
  invisible to it. Off by default; currently NOT installed on this machine.
- Codex: tail-read of the newest `~/.codex/sessions/**/rollout-*.jsonl`. One
  bucket, only as fresh as the last session.

**Never scan the session corpora** (~1.7 GB). Percentages need no token math.

## Things that each cost a debugging cycle — don't rediscover them

1. `codex app-server` **exits on stdin EOF**. Keep stdin open until the response
   arrives or you get nothing back.
2. It **interleaves unsolicited notifications with responses** — match on request
   id, never take the first line of output.
3. A GUI app **does not inherit shell `PATH`**. `codex` is located by absolute
   path (`CodexAppServerClient.searchPaths`).
4. The Claude usage endpoint **rate-limits its own callers** (observed `429`).
   Both live sources are throttled to once per provider per minute; FSEvents fires
   constantly during active work. Don't remove the throttle.
5. Quota is modelled as `[QuotaWindow]`, **not a fixed pair of fields**. An earlier
   version had `fiveHour`/`sevenDay` and silently under-reported a per-model weekly
   cap that could have blocked the user. Unknown API `kind`s are preserved as
   `.other(String)` rather than dropped — keep it that way.
6. `MenuBarExtra` labels reliably render only `Text` and `Image`. A drawn-shape
   "rings" mode was built, didn't display, and was removed.
7. Settings is an **AppKit-owned `NSWindow`** with an explicit
   `NSApp.activate(ignoringOtherApps:)`. This is `LSUIElement`, so the app is an
   accessory and never activates itself — without that the window opens behind
   whatever the user was looking at. A `.sheet` from inside the popover is wrong:
   popovers dismiss on focus loss and strand it.

## Design rules that are load-bearing

- **Severity is never signalled by colour alone** — round normal, triangle warning,
  square critical. Amber-vs-red is the pair red-green colour deficiency collapses.
- **"No data" is not "no usage."** Never render an absent provider as `0%`.
- A window whose `resets_at` has passed is **provably 0%**, however old the reading.
  That makes most staleness self-healing; only the pre-reset gap is uncertain, and
  it renders dimmed with a prefix and "as of HH:MM".
- The shim's passthrough `exec` is the last statement on every path — a failed
  capture must never cost the user their status bar. Its delegate is stored in a
  **sidecar file as data**, never interpolated into the script.
- Display format is a **user setting** (3 modes), not a fixed choice.

## Not done

- **No app icon** (no asset catalog).
- **Never released** — appdater packaging, signing, notarization all untouched.
  Ships unsandboxed + hardened runtime (reading `~/.claude` and `~/.codex` rules out
  the App Store sandbox).
- No real-world soak: throttling, token refresh across an expiry boundary, and the
  429 path have not been observed over a long run.
- GUI never verified headlessly — screen recording isn't permitted for the agent
  process, so display modes and the settings window need human eyes.

## Standing rules

- **Never commit or push without asking.** No `Co-Authored-By`. No
  `Claude-Session:` trailer.
- Swift project -> pre-ship pass is **`prepare-for-release`**, not
  `prepare-for-production`.
- Don't install the statusline shim into `~/.claude/settings.json` without asking —
  it rewires the user's live statusline for every running session.

## Suggested next steps

Ask Glen which he wants rather than assuming: app icon + first appdater release, a
soak test of the throttle/refresh paths, or surfacing the `rateLimitResetCredits`
the Codex response already returns (he has one free "Full reset (Weekly + 5 hr)"
credit sitting unused).
