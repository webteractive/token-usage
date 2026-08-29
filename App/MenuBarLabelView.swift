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
struct MenuBarLabelView: View {
    let spec: LabelSpec

    var body: some View {
        switch spec {
        case .segments(let segments):
            HStack(spacing: 4) {
                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    if index > 0 {
                        Text("·").foregroundStyle(.tertiary)
                    }
                    Text(segment.text)
                        .foregroundStyle(segment.severity.color)
                        .opacity(segment.isStale ? 0.55 : 1)
                }
            }
        case .rings(let rings):
            HStack(spacing: 4) {
                ForEach(Array(rings.enumerated()), id: \.offset) { _, ring in
                    RingView(ring: ring)
                }
            }
        }
    }
}
