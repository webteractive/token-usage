import SwiftUI
import TokenUsageCore

/// A drawn arc sized for the menu bar. Severity changes both the colour and the
/// cap style, so the ring is still readable without colour.
struct RingView: View {
    let ring: Ring

    var body: some View {
        ZStack {
            Circle()
                .stroke(.tertiary, lineWidth: 2)
            Circle()
                .trim(from: 0, to: ring.hasData ? ring.fill : 0)
                .stroke(
                    ring.severity.color,
                    style: StrokeStyle(lineWidth: 2, lineCap: ring.severity == .normal ? .round : .butt)
                )
                .rotationEffect(.degrees(-90))
            if !ring.hasData {
                Text("—").font(.system(size: 7))
            }
        }
        .frame(width: 13, height: 13)
        .opacity(ring.isStale ? 0.55 : 1)
    }
}
