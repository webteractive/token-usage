import Foundation
import Observation
import TokenUsageCore

@Observable
@MainActor
final class UsageViewModel {

    private(set) var usage: [SourceID: ProviderUsage] = [:]
    private(set) var shimStatus: ShimStatus = .notInstalled(existingCommand: nil)
    /// The ordered render list, rebuilt only when the set of accounts changes.
    private(set) var sources: [SourceDescriptor] = []
    /// How each source's figures were obtained, so the UI can be honest about
    /// it. Both providers have a live source and a degraded fallback, so they
    /// share one type rather than two near-identical ones.
    private(set) var sourceStatus: [SourceID: SourceStatus] = [:]

    enum SourceStatus: Equatable {
        /// Complete and current.
        case live
        /// Working, but from the fallback — fewer windows, possibly stale.
        case degraded(String)
        /// Nothing usable, with the reason.
        case unavailable(String)
    }

    let paths: Paths
    private let store: StateStore
    private let codex: CodexCollector
    private let installer: ShimInstaller
    private let locator: ClaudeAccountLocator
    /// The last seen shape of `~/.zetty/accounts`, so the 60s tick can skip the
    /// subprocess when nothing has changed.
    private var accountsFingerprint: Set<String>?
    /// One API per account, kept alive across refreshes. This is load-bearing:
    /// each owns a `KeychainCredentials` actor holding the cached token, so
    /// rebuilding them per refresh would re-read every Keychain item — once per
    /// account, every minute — and undo the fix in 74e9bbb.
    private var apis: [SourceID: ClaudeUsageAPI] = [:]
    private var accounts: [ClaudeAccount] = []
    private let codexAppServer: CodexAppServerClient
    private let preferences: Preferences

    private var watcher: FileWatcher?
    private var ticker: Timer?

    /// Live sources are expensive and rate-limited: the Claude usage endpoint
    /// answers 429 if polled hard, and each Codex read spawns a process. Both
    /// are triggered by FSEvents, which fires repeatedly during active work, so
    /// they are throttled and the previous reading is kept in between.
    private var lastFetch: [SourceID: Date] = [:]
    private static let minimumFetchInterval: TimeInterval = 60

    private func shouldFetch(_ source: SourceID, now: Date = .now) -> Bool {
        guard let last = lastFetch[source] else { return true }
        return now.timeIntervalSince(last) >= Self.minimumFetchInterval
    }

    init(paths: Paths = .live, preferences: Preferences) {
        self.paths = paths
        self.preferences = preferences
        self.store = StateStore(paths: paths)
        self.codex = CodexCollector(paths: paths)
        self.installer = ShimInstaller(paths: paths)
        self.locator = ClaudeAccountLocator(paths: paths)
        self.codexAppServer = CodexAppServerClient()
    }

    var labelSpec: LabelSpec {
        MenuBarLabelRenderer.render(
            usage: usage,
            sources: sources,
            mode: preferences.displayMode,
            thresholds: preferences.thresholds,
            now: .now
        )
    }

    func start() {
        refresh()

        watcher = FileWatcher(
            urls: [paths.stateDirectory, paths.codexSessions, paths.zettyAccounts]
        ) { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        watcher?.start()

        // A window can roll over with nobody writing anything, so re-evaluate on
        // a slow tick as well. State is derived from an injected clock, so this
        // only needs to fire often enough for a countdown to look alive.
        ticker = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        ticker?.invalidate()
        ticker = nil
    }

    func refresh() {
        shimStatus = installer.status()
        rediscoverAccounts()
        Task { await refreshClaude() }
        Task { await refreshCodex() }
    }

    /// The app-server is preferred over the rollout files for the same reasons
    /// the API is preferred for Claude: it is live, and it carries scoped
    /// buckets (such as `base_model_inference`) that a session file never
    /// contains. Calling the ChatGPT usage endpoint directly is not an option —
    /// that host answers a plain client with a Cloudflare challenge.
    private func refreshCodex() async {
        guard shouldFetch(.codex) else { return }
        lastFetch[SourceID.codex] = .now

        let fetched = await Task.detached { [codexAppServer] in
            try? codexAppServer.fetch()
        }.value

        if let fetched, !fetched.windows.isEmpty {
            usage[SourceID.codex] = fetched
            sourceStatus[SourceID.codex] = .live
            return
        }

        if let fallback = codex.collect() {
            usage[SourceID.codex] = fallback
            sourceStatus[SourceID.codex] = .degraded("rollout file")
        } else if usage[SourceID.codex]?.windows.isEmpty == false {
            // Keep the last good reading rather than blanking the row over a
            // transient failure; its own staleness marking already tells the
            // truth about its age.
            sourceStatus[SourceID.codex] = .degraded("last known")
        } else {
            usage[SourceID.codex] = .empty
            sourceStatus[SourceID.codex] = .unavailable(
                CodexAppServerClient.locateBinary() == nil ? "Codex not installed" : "no data"
            )
        }
    }

    /// Rebuilds the source list only when the account set actually changed, so
    /// a steady state costs nothing and no Keychain item is re-read.
    private func rediscoverAccounts() {
        // A directory listing is cheap; discovery is a subprocess. Pay for the
        // second only when the first says something moved.
        let fingerprint = locator.fingerprint()
        guard fingerprint != accountsFingerprint || sources.isEmpty else { return }
        accountsFingerprint = fingerprint

        let found = locator.discover()
        guard found != accounts || sources.isEmpty else { return }

        accounts = found
        sources = SourceCatalog.descriptors(claudeAccounts: found)

        var rebuilt: [SourceID: ClaudeUsageAPI] = [:]
        for account in found {
            let id = SourceID.claude(account.id)
            // Reuse the existing client — and its cached token — where the
            // account is unchanged.
            rebuilt[id] = apis[id] ?? ClaudeUsageAPI(
                credentials: KeychainCredentials(service: account.keychainService)
            )
        }
        apis = rebuilt

        // Drop state belonging to accounts that no longer exist.
        let live = Set(sources.map(\.id))
        usage = usage.filter { live.contains($0.key) }
        sourceStatus = sourceStatus.filter { live.contains($0.key) }
        lastFetch = lastFetch.filter { live.contains($0.key) }
    }

    private func refreshClaude() async {
        // Separate logins have separate server-side limits, so they are fetched
        // concurrently and throttled independently.
        await withTaskGroup(of: Void.self) { group in
            for account in accounts {
                group.addTask { @MainActor [weak self] in
                    await self?.refreshClaudeAccount(account)
                }
            }
        }
    }

    /// The API is preferred because it is complete — it carries scoped weekly
    /// limits the statusline never sends — and because it is live rather than
    /// only arriving while a session happens to be running. The statusline
    /// capture stays as a fallback, but it covers the default account only: the
    /// shim is installed into ~/.claude/settings.json and sees nothing else.
    private func refreshClaudeAccount(_ account: ClaudeAccount) async {
        let id = SourceID.claude(account.id)
        guard let api = apis[id], shouldFetch(id) else { return }
        lastFetch[id] = .now

        var reason = "unavailable"
        do {
            usage[id] = try await api.fetch()
            sourceStatus[id] = .live
            return
        } catch ClaudeUsageAPIError.unauthorized {
            reason = "sign-in expired — run claude"
        } catch CredentialError.expired {
            reason = "sign-in expired — run claude"
        } catch CredentialError.notFound {
            reason = "not signed in"
        } catch ClaudeUsageAPIError.http(429) {
            // The usage endpoint rate-limits its own callers. Backing off and
            // keeping the last reading beats thrashing it.
            reason = "rate limited — retrying shortly"
        } catch {
            reason = "usage API unavailable"
        }

        // The statusline capture carries only two windows, so a partial view is
        // never presented as if it were the whole picture.
        if account.isDefault, let fallback = readClaude() {
            usage[id] = fallback
            sourceStatus[id] = .degraded("statusline · partial")
        } else if usage[id]?.windows.isEmpty == false {
            sourceStatus[id] = .degraded("last known")
        } else {
            usage[id] = .empty
            sourceStatus[id] = .unavailable(reason)
        }
    }

    func installShim() throws { try installer.install(); refresh() }
    func uninstallShim() throws { try installer.uninstall(); refresh() }

    private func readClaude() -> ProviderUsage? {
        guard let result = try? store.read(paths.claudeRawState) else { return nil }
        // The statusline payload carries no timestamp, so the file's own
        // modification date is when the reading was produced.
        return try? ClaudeStatuslineParser.parse(result.data, observedAt: result.modifiedAt)
    }
}
