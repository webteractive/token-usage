import AppKit
import SwiftUI

/// Owns the settings window directly, via AppKit.
///
/// A `.sheet` presented from inside the `MenuBarExtra` popover was the original
/// approach and is wrong: the popover dismisses on focus loss, which can strand
/// anything modal presented from it.
///
/// AppKit is used rather than a `Settings` scene or `SettingsLink` for one
/// reason worth keeping: this app is `LSUIElement`, so it is an accessory and
/// never activates itself. `NSApp.activate` before `makeKeyAndOrderFront` is
/// what stops the window opening behind whatever the user was looking at, and
/// owning the window makes that explicit rather than something to hope for.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show(model: UsageViewModel, preferences: Preferences) {
        let window = window ?? makeWindow()
        self.window = window

        // Rebuilt each time so the view reflects current usage and preferences
        // rather than a snapshot from whenever the window was first opened.
        window.contentViewController = NSHostingController(
            rootView: SettingsView(model: model, preferences: preferences)
        )
        window.setContentSize(window.contentViewController?.view.fittingSize ?? .init(width: 380, height: 520))
        window.center()

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Token Usage Settings"
        // Closing must not deallocate it — the controller keeps the reference so
        // reopening is cheap and preserves position.
        window.isReleasedWhenClosed = false
        return window
    }
}
