import ServiceManagement
import SwiftUI
import TokenUsageCore

struct SettingsView: View {
    let model: UsageViewModel
    let preferences: Preferences

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var shimError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Token Usage").font(.title3).bold()

            display
            Divider()
            thresholds
            Divider()
            claudeReporting
            Divider()

            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    try? enabled ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                }
        }
        .padding(20)
        .frame(width: 380)
    }

    private var display: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Menu bar shows", selection: Binding(
                get: { preferences.displayMode },
                set: { preferences.displayMode = $0 }
            )) {
                ForEach(DisplayMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            // Live preview, so the choice is made by seeing rather than reading.
            MenuBarLabelView(spec: model.labelSpec)
                .padding(6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var thresholds: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Thresholds").font(.headline)
            slider("Warning", value: Binding(
                get: { preferences.warningThreshold },
                set: { preferences.warningThreshold = $0 }
            ))
            slider("Critical", value: Binding(
                get: { preferences.criticalThreshold },
                set: { preferences.criticalThreshold = $0 }
            ))
            Text("Severity is shown by shape as well as colour, so it stays readable without relying on hue.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func slider(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label).frame(width: 60, alignment: .leading)
            Slider(value: value, in: 10...100, step: 5)
            Text("\(Int(value.wrappedValue))%").monospacedDigit().frame(width: 44)
        }
    }

    private var claudeReporting: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Claude reporting").font(.headline)

            switch model.shimStatus {
            case .installed(let delegate):
                Label("Helper installed", systemImage: "checkmark.circle")
                if let delegate {
                    Text("Your statusline still runs: \(delegate)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Button("Remove helper") { perform(model.uninstallShim) }

            case .notInstalled(let existing):
                Text("Claude Code reports quota only to its statusline command. The helper captures it and passes your statusline through unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
                if let existing {
                    Text("Will chain in front of: \(existing)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Button("Install helper") { perform(model.installShim) }

            case .modifiedExternally(let current):
                Label("Statusline changed outside this app", systemImage: "exclamationmark.triangle")
                Text("statusLine.command now points at \(current). Reinstalling will chain in front of it.")
                    .font(.caption2).foregroundStyle(.secondary)
                Button("Reinstall helper") { perform(model.installShim) }
            }

            if let shimError {
                Text(shimError).font(.caption2).foregroundStyle(.red)
            }
        }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            shimError = nil
        } catch {
            shimError = error.localizedDescription
        }
    }
}
