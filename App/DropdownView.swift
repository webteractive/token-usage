import SwiftUI
import TokenUsageCore

struct DropdownView: View {
    let model: UsageViewModel
    let preferences: Preferences
    let updates: UpdateController

    @State private var installError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.sources, id: \.id) { source in
                        sourceSection(source)
                    }
                }
            }
            // Enough for four accounts before scrolling, so a machine with many
            // logins degrades to a scroll rather than a dropdown taller than
            // the screen.
            .frame(maxHeight: 360)

            if case .notInstalled = model.shimStatus {
                Divider()
                shimPrompt
            }

            if let update = updates.availableUpdate {
                Divider()
                Button {
                    updates.presentAvailableUpdate()
                } label: {
                    Label("Update to \(update.version)", systemImage: "arrow.down.circle")
                }
                .disabled(updates.isInstalling)
            }

            Divider()

            HStack {
                Button {
                    SettingsWindowController.shared.show(
                        model: model,
                        preferences: preferences,
                        updates: updates
                    )
                } label: {
                    Image(systemName: "gearshape")
                        .imageScale(.large)
                }
                .help("Settings")
                .accessibilityLabel("Settings")
                Spacer()
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                        .imageScale(.large)
                }
                .help("Quit Token Usage")
                .accessibilityLabel("Quit")
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: 300)
    }

    @ViewBuilder
    private func sourceSection(_ source: SourceDescriptor) -> some View {
        let usage = model.usage[source.id] ?? .empty
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(source.displayName).font(.headline)
                sourceBadge(source.id)
            }
            if usage.windows.isEmpty {
                Text("no data").font(.caption).foregroundStyle(.secondary)
            } else {
                // Every window the source reports, however many that is —
                // dropping one is how you fail to warn about the limit that is
                // about to block you.
                ForEach(usage.windows, id: \.kind) { quota in
                    row(quota)
                }
            }
        }
    }

    /// Says plainly where a source's numbers came from, because the live and
    /// fallback sources differ in completeness — and because only the default
    /// account has a fallback at all.
    @ViewBuilder
    private func sourceBadge(_ id: SourceID) -> some View {
        switch model.sourceStatus[id] {
        case .live:
            Text("live").font(.caption2).foregroundStyle(.secondary)
        case .degraded(let how):
            Text(how).font(.caption2).foregroundStyle(.orange)
        case .unavailable(let why):
            Text(why).font(.caption2).foregroundStyle(.orange)
        case nil:
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
