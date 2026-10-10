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
    /// it. Both providers have a complete source and a partial one, so they
    /// share one type rather than two near-identical ones.
    private(set) var sourceStatus: [SourceID: SourceStatus] = [:]

    enum SourceStatus: Equatable {
        /// Complete and current.
        case live
        /// Working, but not from every source — fewer windows, possibly stale.
        /// `detail` says what is missing and why.
        case degraded(String, detail: String? = nil)
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
    private let captures: ClaudeSessionCaptures
    /// The last complete answer the API gave for each login. Kept between
    /// polls because it is the only source of the scoped weekly limits.
    private var apiReadings: [SourceID: ProviderUsage] = [:]
    /// Why the API has nothing newer for a login. Absent once it answers.
    private var apiFailures: [SourceID: String] = [:]
    /// One per login, because the endpoint throttles each token on its own.
    private var schedules: [SourceID: PollSchedule] = [:]
    private let codexAppServer: CodexAppServerClient
    private let preferences: Preferences

    private var watcher: FileWatcher?
    private var ticker: Timer?

    /// Each Codex read spawns a process, and refreshes are triggered by
    /// FSEvents, which fires repeatedly during active work, so reads are
    /// throttled and the previous reading is kept in between. The Claude usage
    /// endpoint needs far more room than this and has `PollSchedule` instead.
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
        self.captures = ClaudeSessionCaptures(directory: paths.claudeSessions)
        self.codexAppServer = CodexAppServerClient()
    }

    var labelSpec: LabelSpec {
        MenuBarLabelRenderer.render(
            usage: usage,
            sources: sources,
            mode: preferences.displayMode,
            thresholds: preferences.thresholds,
            hidesEmptySources: preferences.hidesEmptySources,
            now: .now
        )
    }

    func start() {
        // An update can ship a new shim. Sessions run whatever is on disk, so
        // the installed copy has to follow the app rather than wait for a
        // reinstall nobody knows to do.
        _ = try? installer.refreshScript()
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
        // Discovery must settle before the accounts are fetched, so the two
        // share a task rather than racing.
        Task {
            await rediscoverAccounts()
            await refreshClaude()
        }
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

    /// Rebuilds the source list only when the account set actually changed, so
    /// a steady state costs nothing and no Keychain item is re-read.
    private func rediscoverAccounts() async {
        // A directory listing is cheap; discovery is a subprocess. Pay for the
        // second only when the first says something moved.
        let fingerprint = locator.fingerprint()
        guard fingerprint != accountsFingerprint || sources.isEmpty else { return }
        accountsFingerprint = fingerprint

        // Off the main actor: discovery shells out to zetty, and a menu bar app
        // that blocks on a child process is a menu bar app that stops redrawing.
        let found = await Task.detached { [locator] in locator.discover() }.value
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
        schedules = schedules.filter { live.contains($0.key) }
        apiReadings = apiReadings.filter { live.contains($0.key) }
        apiFailures = apiFailures.filter { live.contains($0.key) }
    }

    /// Session captures come first: they cost nothing, cannot be throttled,
    /// and move with every request a session makes. The API is asked far less
    /// often, for the scoped weekly limits no statusline carries and for
    /// logins with no session open.
    private func refreshClaude() async {
        publishClaude()

        // Each login is its own account as far as this app is concerned, with
        // its own token and its own throttle, so they are polled independently.
        let now = Date.now
        await withTaskGroup(of: Void.self) { group in
            for account in accounts {
                group.addTask { @MainActor [weak self] in
                    await self?.pollAPI(account, now: now)
                }
            }
        }
        publishClaude()
    }

    private func pollAPI(_ account: ClaudeAccount, now: Date) async {
        let id = SourceID.claude(account.id)
        guard let api = apis[id], schedules[id, default: PollSchedule()].isDue(now: now) else { return }
        schedules[id, default: PollSchedule()].began(now: now)

        do {
            apiReadings[id] = try await api.fetch()
            apiFailures[id] = nil
            schedules[id]?.succeeded()
        } catch ClaudeUsageAPIError.rateLimited(let retryAfter) {
            schedules[id]?.refused(now: now, retryAfter: retryAfter)
            apiFailures[id] = "rate limited — retrying later"
        } catch ClaudeUsageAPIError.unauthorized, CredentialError.expired {
            apiFailures[id] = "sign-in expired — \(account.owner == .tinker ? "open Tinker" : "run claude")"
        } catch CredentialError.notFound, CredentialError.malformed {
            // An item holding only MCP tokens has no Claude login in it.
            apiFailures[id] = "not signed in"
        } catch {
            apiFailures[id] = "usage API unavailable"
        }
    }

    /// Rebuilds every Claude row from what is on disk and what the API last
    /// said for that login.
    private func publishClaude() {
        captures.reload()

        for account in accounts {
            let id = SourceID.claude(account.id)
            let local = localUsage(account)
            let merged = ProviderUsage.merged([local] + [apiReadings[id]].compactMap { $0 })

            let status: SourceStatus?
            if let reason = apiFailures[id] {
                // The statusline carries only two windows, so a partial view
                // is never presented as if it were the whole picture.
                if !local.windows.isEmpty {
                    status = .degraded("statusline only", detail: "Usage API: \(reason)")
                } else if !merged.windows.isEmpty {
                    status = .degraded("last known", detail: "Usage API: \(reason)")
                } else {
                    status = .unavailable(reason)
                }
            } else {
                // Before the first answer there is nothing to claim either way.
                status = apiReadings[id] == nil ? nil : .live
            }

            // Assigning an equal value still redraws the menu bar.
            if usage[id] != merged { usage[id] = merged }
            if sourceStatus[id] != status { sourceStatus[id] = status }
        }
    }

    /// What a login's own sessions last reported. Tinker's sessions run its
    /// statusline rather than the shim, so its snapshot file stands in for
    /// their captures.
    private func localUsage(_ account: ClaudeAccount) -> ProviderUsage {
        guard account.owner == .tinker else { return captures.usage(for: account.directory) }
        guard let file = try? store.read(paths.tinkerUsage) else { return .empty }
        return (try? TinkerUsageParser.parse(file.data, modifiedAt: file.modifiedAt)) ?? .empty
    }

    func installShim() throws { try installer.install(); refresh() }
    func uninstallShim() throws { try installer.uninstall(); refresh() }
}
