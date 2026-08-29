import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class UpdateController {
    private(set) var availableUpdate: AvailableUpdate?
    private(set) var isChecking = false
    private(set) var isInstalling = false

    let currentVersion: String

    private let preferences: Preferences
    private let checker: UpdateChecker
    private let installer = UpdateInstaller()
    private var timer: Timer?
    private var started = false
    private var progressAlert: NSAlert?

    private static let checkInterval: TimeInterval = 6 * 3600
    private static let lastCheckKey = "lastUpdateCheck"

    init(preferences: Preferences) {
        self.preferences = preferences
        currentVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
        checker = UpdateChecker(currentVersion: currentVersion)
    }

    func start() {
        guard !started else { return }
        started = true
        runAutomaticCheckIfDue()
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runAutomaticCheckIfDue() }
        }
    }

    func automaticCheckPreferenceChanged() {
        if preferences.automaticallyChecksForUpdates { runAutomaticCheckIfDue() }
    }

    func checkForUpdates() {
        runCheck(manual: true)
    }

    func presentAvailableUpdate() {
        guard let availableUpdate else { return }
        present(availableUpdate)
    }

    private func runAutomaticCheckIfDue() {
        guard preferences.automaticallyChecksForUpdates, !isChecking else { return }
        let defaults = UserDefaults.standard
        let lastCheck = defaults.double(forKey: Self.lastCheckKey)
        let now = Date().timeIntervalSince1970
        guard now - lastCheck >= Self.checkInterval else { return }
        defaults.set(now, forKey: Self.lastCheckKey)
        runCheck(manual: false)
    }

    private func runCheck(manual: Bool) {
        guard !isChecking else { return }
        isChecking = true
        Task {
            do {
                let update = try await checker.check()
                isChecking = false
                availableUpdate = update
                if manual {
                    if let update { present(update) }
                    else { showInfo("You're up to date.") }
                }
            } catch {
                isChecking = false
                if manual { showInfo("Couldn't check for updates.") }
            }
        }
    }

    private func present(_ update: AvailableUpdate) {
        let alert = NSAlert()
        alert.messageText = "Update to \(update.version)?"
        if update.isInstallable {
            alert.informativeText = "Token Usage will download the update and restart."
            alert.addButton(withTitle: "Install & Restart")
            alert.addButton(withTitle: "View Release Notes")
            alert.addButton(withTitle: "Later")
        } else {
            alert.informativeText = "A newer version is available on the releases page."
            alert.addButton(withTitle: "View Release Notes")
            alert.addButton(withTitle: "Later")
        }

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if update.isInstallable {
            if response == .alertFirstButtonReturn {
                startInstall(update)
            } else if response == .alertSecondButtonReturn {
                NSWorkspace.shared.open(update.releasePage)
            }
        } else if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(update.releasePage)
        }
    }

    private func startInstall(_ update: AvailableUpdate) {
        guard !isInstalling else { return }
        isInstalling = true

        let alert = NSAlert()
        alert.messageText = "Updating to \(update.version)…"
        alert.informativeText = "Downloading…"
        let progress = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 260, height: 16))
        progress.minValue = 0
        progress.maxValue = 1
        progress.isIndeterminate = false
        alert.accessoryView = progress
        progressAlert = alert

        NSApp.activate(ignoringOtherApps: true)
        alert.window.center()
        alert.window.makeKeyAndOrderFront(nil)

        installer.install(update) { [weak alert, weak progress] state in
            switch state {
            case .downloading(let fraction):
                progress?.doubleValue = fraction
                alert?.informativeText = "Downloading…"
            case .verifying:
                progress?.isIndeterminate = true
                progress?.startAnimation(nil)
                alert?.informativeText = "Verifying…"
            case .preparing:
                alert?.informativeText = "Preparing…"
            case .relaunching:
                alert?.informativeText = "Restarting…"
            }
        } completion: { [weak self] result in
            guard let self else { return }
            progressAlert?.window.orderOut(nil)
            progressAlert = nil
            isInstalling = false
            if case .failure(let error) = result { showInfo(error.description) }
        }
    }

    private func showInfo(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "Token Usage"
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
