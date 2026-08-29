import SwiftUI
import TokenUsageCore

struct DropdownView: View {
    let model: UsageViewModel
    let preferences: Preferences

    @State private var showingSettings = false
    @State private var installError: String?

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
        .frame(width: 300)
        .sheet(isPresented: $showingSettings) {
            SettingsView(model: model, preferences: preferences)
        }
    }

    @ViewBuilder
    private func providerSection(_ provider: Provider) -> some View {
        let usage = model.usage[provider] ?? .empty
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(provider.displayName).font(.headline)
                if provider == .claude { sourceBadge }
            }
            if usage.windows.isEmpty {
                Text("no data").font(.caption).foregroundStyle(.secondary)
            } else {
                // Every window the provider reports, however many that is —
                // dropping one is how you fail to warn about the limit that is
                // about to block you.
                ForEach(usage.windows, id: \.kind) { quota in
                    row(quota)
                }
            }
        }
    }

    /// Says plainly where Claude's numbers came from, because the two sources
    /// differ in completeness.
    @ViewBuilder
    private var sourceBadge: some View {
        switch model.claudeSource {
        case .api:
            Text("live").font(.caption2).foregroundStyle(.secondary)
        case .statusline:
            Text("statusline · partial").font(.caption2).foregroundStyle(.orange)
        case .needsReauth:
            Text("sign-in expired \u{2014} run claude").font(.caption2).foregroundStyle(.orange)
        case .failed:
            Text("unavailable").font(.caption2).foregroundStyle(.orange)
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private func row(_ quota: QuotaWindow) -> some View {
        let now = Date.now
        let window = quota.window
        let state = window.state(now: now)
        let severity = Severity.of(state.percent ?? 0, preferences.thresholds)

        HStack(spacing: 6) {
            Text(quota.label)
                .frame(width: 62, alignment: .leading)
                .foregroundStyle(quota.isActive ? .primary : .secondary)
            Text(state.percentLabel)
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

    private var shimPrompt: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Claude reporting is off").font(.caption).bold()
            Text("Claude Code only reports quota to its statusline. Installing the helper captures it; your existing statusline keeps working.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button("Install helper") {
                // Surfaced rather than swallowed: a failed install otherwise
                // looks identical to a button that simply does nothing.
                do {
                    try model.installShim()
                    installError = nil
                } catch {
                    installError = error.localizedDescription
                }
            }
            if let installError {
                Text(installError).font(.caption2).foregroundStyle(.red)
            }
        }
    }
}
