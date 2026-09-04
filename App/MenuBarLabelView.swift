import SwiftUI
import TokenUsageCore

extension Severity {
    var color: Color {
        switch self {
        case .normal: .primary
        case .warning: .orange
        case .critical: .red
        }
    }
}

/// Renders a LabelSpec. Colour is only ever a secondary cue — the shape marker
/// baked into the segment text carries the same information.
///
/// The whole label is a single concatenated `Text`. `MenuBarExtra` flattens
/// its label into the status item's attributed title and keeps only the first
/// `Text` it finds, so an `HStack` of several `Text`s shows just the first
/// provider and silently drops the rest. Concatenation keeps every run's own
/// colour and opacity while producing the one `Text` the menu bar will honour.
struct MenuBarLabelView: View {
    let spec: LabelSpec

    var body: some View {
        spec.enumerated().reduce(Text("")) { label, item in
            let (index, segment) = item
            let separator = index > 0 ? Text(" · ").foregroundStyle(.tertiary) : Text("")
            let color = segment.severity.color.opacity(segment.isStale ? 0.55 : 1)
            return label + separator + Text(segment.text).foregroundStyle(color)
        }
    }
}
