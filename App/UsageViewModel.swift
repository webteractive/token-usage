import Foundation
import Observation
import TokenUsageCore

@Observable
@MainActor
final class UsageViewModel {

    private(set) var usage: [Provider: ProviderUsage] = [:]
    private(set) var shimStatus: ShimStatus = .notInstalled(existingCommand: nil)
    /// How each provider's figures were obtained, so the UI can be honest about
    /// it. Both providers have a live source and a degraded fallback, so they
    /// share one type rather than two near-identical ones.
    private(set) var sourceStatus: [Provider: SourceStatus] = [:]

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
    private let api: ClaudeUsageAPI
    private let codexAppServer: CodexAppServerClient
    private let preferences: Preferences

    private var watcher: FileWatcher?
    private var ticker: Timer?

    /// Live sources are expensive and rate-limited: the Claude usage endpoint
    /// answers 429 if polled hard, and each Codex read spawns a process. Both
    /// are triggered by FSEvents, which fires repeatedly during active work, so
    /// they are throttled and the previous reading is kept in between.
    private var lastFetch: [Provider: Date] = [:]
    private static let minimumFetchInterval: TimeInterval = 60

    private func shouldFetch(_ provider: Provider, now: Date = .now) -> Bool {
        guard let last = lastFetch[provider] else { return true }
        return now.timeIntervalSince(last) >= Self.minimumFetchInterval
    }

    init(paths: Paths = .live, preferences: Preferences) {
        self.paths = paths
        self.preferences = preferences
        self.store = StateStore(paths: paths)
        self.codex = CodexCollector(paths: paths)
        self.installer = ShimInstaller(paths: paths)
        self.api = ClaudeUsageAPI()
        self.codexAppServer = CodexAppServerClient()
    }

    var labelSpec: LabelSpec {
        MenuBarLabelRenderer.render(
            usage: usage,
            mode: preferences.displayMode,
            thresholds: preferences.thresholds,
            now: .now
        )
    }

    func start() {
        refresh()

        watcher = FileWatcher(urls: [paths.stateDirectory, paths.codexSessions]) { [weak self] in
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
        lastFetch[.codex] = .now

        let fetched = await Task.detached { [codexAppServer] in
            try? codexAppServer.fetch()
        }.value

        if let fetched, !fetched.windows.isEmpty {
            usage[.codex] = fetched
            sourceStatus[.codex] = .live
            return
        }

        if let fallback = codex.collect() {
            usage[.codex] = fallback
            sourceStatus[.codex] = .degraded("rollout file")
        } else if usage[.codex]?.windows.isEmpty == false {
            // Keep the last good reading rather than blanking the row over a
            // transient failure; its own staleness marking already tells the
            // truth about its age.
            sourceStatus[.codex] = .degraded("last known")
        } else {
            usage[.codex] = .empty
            sourceStatus[.codex] = .unavailable(
                CodexAppServerClient.locateBinary() == nil ? "Codex not installed" : "no data"
            )
        }
    }

    /// The API is preferred because it is complete — it carries scoped weekly
    /// limits the statusline never sends — and because it is live rather than
    /// only arriving while a session happens to be running. The statusline
    /// capture stays as a fallback for when the undocumented endpoint changes.
    private func refreshClaude() async {
        guard shouldFetch(.claude) else { return }
        lastFetch[.claude] = .now

        var reason = "unavailable"
        do {
            usage[.claude] = try await api.fetch()
            sourceStatus[.claude] = .live
            return
        } catch ClaudeUsageAPIError.unauthorized {
            reason = "sign-in expired — run claude"
        } catch CredentialError.expired {
            reason = "sign-in expired — run claude"
        } catch CredentialError.notFound {
            reason = "not signed in to Claude Code"
        } catch ClaudeUsageAPIError.http(429) {
            // The usage endpoint rate-limits its own callers. Backing off and
            // keeping the last reading beats thrashing it.
            reason = "rate limited — retrying shortly"
        } catch {
            reason = "usage API unavailable"
        }

        // The statusline capture carries only two windows, so a partial view is
        // never presented as if it were the whole picture.
        if let fallback = readClaude() {
            usage[.claude] = fallback
            sourceStatus[.claude] = .degraded("statusline · partial")
        } else if usage[.claude]?.windows.isEmpty == false {
            sourceStatus[.claude] = .degraded("last known")
        } else {
            usage[.claude] = .empty
            sourceStatus[.claude] = .unavailable(reason)
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
