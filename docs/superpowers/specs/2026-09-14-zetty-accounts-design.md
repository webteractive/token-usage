# Tracking zetty accounts

**Date:** 2026-09-14
**Status:** Approved, ready for implementation planning

## Purpose

Show quota for **every Claude login on this machine**, not just the default one.

zetty runs agent panes under named accounts, each a separate Claude login with
its own config directory. Today Token Usage reads only `~/.claude` and is blind
to the rest — which means the account you are actually burning quota in can be
the one the menu bar never mentions.

Out of scope, deliberately: multi-account Codex, per-account opt-out settings,
`zetty accounts --probe`, statusline capture for non-default accounts,
notifications.

## Key findings

Everything needed already exists; nothing has to be invented. Verified on this
machine 2026-09-12.

### Credentials are per-account Keychain items

Claude Code stores each config directory's OAuth credential under its own
generic-password service:

| Config directory | Keychain service |
|---|---|
| `~/.claude` (default) | `Claude Code-credentials` |
| `~/.zetty/accounts/warda` | `Claude Code-credentials-654d2b27` |
| `~/.zetty/accounts/devops` | `Claude Code-credentials-7bb31e54` |

The suffix is the **first 8 hex characters of the SHA-256 of the config
directory's absolute path**, with no trailing newline. Confirmed against the
live Keychain: `sha256("/Users/<user>/.zetty/accounts/warda")` begins `654d2b27`
and `…/devops` begins `7bb31e54`, matching the items present.

Consequence: an account is the **existing** `ClaudeUsageAPI` built against a
different Keychain service. `KeychainCredentials(service:)` and
`ClaudeUsageAPI(credentials:)` are already public and parameterized, so the
fetch layer needs no new networking, no new endpoint, and no new parser.

A Keychain item for a deleted account (`…-3e0a0753` is present here) is simply
never queried, because discovery is driven by directories that exist.

### `~/.zetty/accounts/` is not all Claude

This directory mixes agents. `personal-test` on this machine is a **Codex**
account (`config.toml` with `model = "gpt-5.6-sol"`, no `.claude.json`).

`zetty accounts --json` tags each entry with `"agent": "claude"` and omits the
Codex one. A naive directory scan would invent a phantom Claude account that
reports "not signed in" forever. The agent classification is zetty's contract,
so this design asks zetty rather than reimplementing it.

### The default account's identity is not in its config directory

`~/.claude/.claude.json` **does not exist**. The default login's `oauthAccount`
lives at `~/.claude.json`, beside the config directory rather than inside it —
a legacy layout quirk. Non-default accounts do keep theirs inside
(`<dir>/.claude.json`). `zetty accounts --json` reports `defaultDirectory` and
resolves this correctly.

### Discovery cost is negligible either way

`zetty accounts --json` measured at ~28ms per invocation (10 runs, 0.28s total,
~0% CPU). A filesystem scan is a sub-millisecond listing plus ~1ms per
`.claude.json` (47–60KB each). At launch-and-on-change cadence both are free,
so correctness decides, not speed.

## Identity

The app's central key stops being `Provider`. `Provider` survives unchanged — it
answers *which vendor* — but the dictionary key becomes a composite:

```swift
public struct SourceID: Hashable, Sendable {
    public let provider: Provider
    public let account: String?     // nil for Codex; "default" or the zetty account id
}

public struct SourceDescriptor: Sendable {
    public let id: SourceID
    public let displayName: String   // "Claude · Warda", or "Claude" when alone
    public let shortLabel: String    // "C", or "G"/"W"/"D" when several
    public let keychainService: String?
}
```

`usage`, `sourceStatus` and `lastFetch` are rekeyed from `Provider` to
`SourceID`.

**Order is data, and fixed:** default Claude account first, then zetty accounts
alphabetically by account id, then Codex. Never ordered by percentage — the menu
bar must not reshuffle as numbers move.

**Short labels:** Codex keeps `X`. A single Claude account keeps `C`, and its
dropdown header keeps reading plain "Claude". With several, each takes the
shortest unique uppercase prefix of its display name (`G`/`W`/`D`), computed
once at discovery from the ordered list so it is deterministic. Uniqueness is
resolved among Claude accounts only — Codex's fixed `X` does not participate. A
machine without zetty accounts therefore looks **identical to today**.

## Discovery

New `ClaudeAccountLocator` in `TokenUsageCore`, taking the injectable `Paths` so
it tests against a temporary home. `Paths` gains `zettyAccounts`
(`~/.zetty/accounts`) and `defaultClaudeConfigJSON` (`~/.claude.json`).

**Primary source — `zetty accounts --json`,** when the binary is on `PATH`
(resolved the way `CodexAppServerClient.locateBinary()` already resolves Codex).
Entries with `agent == "claude"` become accounts; `defaultDirectory` becomes the
default one. `~` in reported paths is expanded against the injected home.

**Fallback — filesystem,** when the binary is absent, errors, or returns
unparseable output: list `~/.zetty/accounts/*` and keep only directories
containing `.claude.json`. This excludes Codex account directories correctly. It
misses a Claude account that has never been signed into, which has nothing to
report anyway.

Identity (`displayName`, `emailAddress`, `organizationName`) comes from the
zetty entry when present, else from `oauthAccount` in the account's
`.claude.json` — `~/.claude.json` for the default, `<dir>/.claude.json`
otherwise. An account with no resolvable identity is still listed, named from
its directory, and reports "not signed in": it exists, and silence about it
would be the same failure as printing `0%` for "no data".

The Keychain service is derived locally in both paths, since zetty does not
report it: unsuffixed for the default directory, otherwise
`"Claude Code-credentials-" + sha256(directory.path).hex.prefix(8)` via
CryptoKit.

**Cadence:** full discovery runs at launch and when `~/.zetty/accounts` changes
— that directory joins the existing `FileWatcher` when it exists. The 60s tick
only compares the current directory listing against the known account set, so a
subprocess is spawned solely when that set has changed. This also catches
`~/.zetty` appearing after launch, which the watcher alone would miss.

## Fetching

`UsageViewModel` holds `sources: [SourceDescriptor]` and
`apis: [SourceID: ClaudeUsageAPI]`, rebuilt **only when the discovered account
set changes** (compared by id and Keychain service).

This is load-bearing. Each `ClaudeUsageAPI` owns a `KeychainCredentials` actor
holding the cached token; rebuilding them per refresh would re-read every
Keychain item and undo the fix in `74e9bbb` — once per account, every minute.

Accounts are fetched concurrently in a task group, each throttled independently
at the existing 60s minimum. Accounts are distinct logins, so their server-side
rate limits are independent.

## Rendering

`MenuBarLabelRenderer.render` takes `sources: [SourceDescriptor]` in place of
its hardcoded `private static let order`.

| Mode | Behaviour | Example |
|---|---|---|
| `worstOf` | Worst across every source | `▲ 80%` |
| `perTool` (default) | Claude collapses to the worst dominant window across its accounts, labelled `C` | `C ▲ 80% · X 3%` |
| `perAccount` (**new**) | One segment per source | `G 47% · W 12% · D ▲ 80% · X 3%` |
| `full` | Every window of every source | `G 47/31/4 · W 12/8 · D 80/64 · X 0/1` |

`perTool` staying the default is what keeps the menu bar a fixed width as
accounts are added. `DisplayMode` gains `perAccount` (raw value `perAccount`,
title "One per account"), ordered between `perTool` and `full`. Unknown
persisted raw values already fall back to `perTool`, so the preference is
forward- and backward-safe.

One targeted fix in the same file: `DisplayMode.full.title` reads "All four",
which the README already contradicts with "Every window" and which stopped being
true when scoped weekly limits appeared. Aligned to "Every window".

## User interface

`DropdownView` iterates `model.sources` instead of `Provider.allCases`. Each
section's header is the descriptor's `displayName`; the source badge reads
`sourceStatus[source.id]`. Every account shows every window it reports, flat and
expanded — no disclosure rows.

The stack moves into a `ScrollView` with a maximum height so a machine with many
accounts degrades to scrolling rather than a dropdown taller than the screen.

`SettingsView` gains "One per account" in the picker automatically via
`DisplayMode.allCases`; its live preview already renders through the same
renderer and needs no change.

## Error handling

Status is per-source, using the existing `SourceStatus` cases.

| Condition | Shown |
|---|---|
| Default account, API fails, statusline capture present | `degraded("statusline · partial")` |
| Non-default account, API fails, previous reading exists | `degraded("last known")` |
| Non-default account, API fails, no previous reading | `unavailable(reason)` |
| Account with no credential | `unavailable("not signed in")` |
| Account directory removed | Row and usage entry drop at next discovery |

Non-default accounts have **no fallback**: the statusline shim is installed into
`~/.claude/settings.json` and captures the default login only. This asymmetry is
reported honestly rather than hidden.

## Keychain prompts

Each account is a Keychain item this app has never accessed, so macOS prompts
once per item on first fetch — unavoidable, and once per item rather than once
per refresh thanks to the in-memory credential cache.

Ad-hoc signing ties that grant to the build's cdhash, so it is invalidated by
every update: today that costs one re-prompt, and with three accounts it costs
three. A stable Developer ID identity would make the grant persist across
updates. **To verify empirically before the next release** — this is an ACL
behaviour reasoned from the model, not yet tested on this app.

## Testing

New `ClaudeAccountLocatorTests`, against a temporary home:

- zetty JSON parsed into accounts; `agent != "claude"` entries excluded
- `~` expansion in reported paths, and `defaultDirectory` handling
- fallback scan when the binary is absent: dirs with `.claude.json` only, Codex
  dirs excluded
- Keychain-service derivation asserted against a fixed literal path and its
  precomputed digest
- identity read from `~/.claude.json` for the default and `<dir>/.claude.json`
  otherwise
- an account with no identity still listed, named from its directory
- no `~/.zetty` at all yields exactly today's single-account behaviour

`MenuBarLabelRendererTests` extends its two private helpers (`usage(claude:codex:)`
and `render(_:_:)`) and gains:

- `perAccount` rendering across three accounts plus Codex
- `perTool` collapsing several accounts to the worst
- single Claude account rendering `C`, unchanged from today
- short-label disambiguation, including a collision needing a two-character
  prefix

`ProviderUsageTests` is updated for the rekeying. `swift test` must stay green
throughout; the core remains SwiftUI-free.
