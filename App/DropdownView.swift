import SwiftUI
import TokenUsageCore

struct DropdownView: View {
    let model: UsageViewModel
    let preferences: Preferences

    @State private var showingSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Provider.allCases, id: \.self) { provider in
                providerSection(provider)
            }

            if case .notInstalled = model.shimStatus {
                Divider()
                shimPrompt
            }

            Divider()

            HStack {
                Button("Settings…") { showingSettings = true }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: 260)
        .sheet(isPresented: $showingSettings) {
            SettingsView(model: model, preferences: preferences)
        }
    }

    @ViewBuilder
    private func providerSection(_ provider: Provider) -> some View {
        let usage = model.usage[provider] ?? .empty
        VStack(alignment: .leading, spacing: 3) {
            Text(provider.displayName).font(.headline)
            row("5h", usage.fiveHour)
            row("7d", usage.sevenDay)
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ window: UsageWindow?) -> some View {
        let now = Date.now
        let state = window?.state(now: now) ?? .unknown
        let severity = Severity.of(state.percent ?? 0, preferences.thresholds)

        HStack(spacing: 6) {
            Text(label)
                .frame(width: 22, alignment: .leading)
                .foregroundStyle(.secondary)
            Text(percentText(state))
                .frame(width: 44, alignment: .trailing)
                .foregroundStyle(state.hasData ? severity.color : .secondary)
                .opacity(state.isStale ? 0.6 : 1)
            Text(CountdownFormatter.observed(state) ?? CountdownFormatter.reset(for: window, now: now))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .monospacedDigit()
    }

    private func percentText(_ state: WindowState) -> String {
        guard let percent = state.percent else { return "—" }
        return "\(Int(percent.rounded()))%"
    }

    private var shimPrompt: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Claude reporting is off").font(.caption).bold()
            Text("Claude Code only reports quota to its statusline. Installing the helper captures it; your existing statusline keeps working.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button("Install helper") { try? model.installShim() }
        }
    }
}
