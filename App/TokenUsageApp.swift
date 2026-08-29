import SwiftUI
import TokenUsageCore

@main
struct TokenUsageApp: App {
    @State private var preferences: Preferences
    @State private var model: UsageViewModel

    init() {
        // One Preferences instance shared by the view model and the settings
        // UI, so a mode change re-renders the menu bar immediately.
        let preferences = Preferences()
        _preferences = State(initialValue: preferences)
        _model = State(initialValue: UsageViewModel(preferences: preferences))
    }

    var body: some Scene {
        MenuBarExtra {
            DropdownView(model: model, preferences: preferences)
        } label: {
            MenuBarLabelView(spec: model.labelSpec)
                .task { model.start() }
        }
        .menuBarExtraStyle(.window)
    }
}
