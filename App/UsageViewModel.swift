import Foundation
import Observation
import TokenUsageCore

@Observable
@MainActor
final class UsageViewModel {

    private(set) var usage: [Provider: ProviderUsage] = [:]
    private(set) var shimStatus: ShimStatus = .notInstalled(existingCommand: nil)

    let paths: Paths
    private let store: StateStore
    private let codex: CodexCollector
    private let installer: ShimInstaller
    private let preferences: Preferences

    private var watcher: FileWatcher?
    private var ticker: Timer?

    init(paths: Paths = .live, preferences: Preferences) {
        self.paths = paths
        self.preferences = preferences
        self.store = StateStore(paths: paths)
        self.codex = CodexCollector(paths: paths)
        self.installer = ShimInstaller(paths: paths)
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
        ticker = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
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
        usage[.claude] = readClaude() ?? .empty
        usage[.codex] = codex.collect() ?? .empty
        shimStatus = installer.status()
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
