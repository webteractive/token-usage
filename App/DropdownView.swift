import SwiftUI
import TokenUsageCore

struct DropdownView: View {
    let model: UsageViewModel
    let preferences: Preferences

    var body: some View {
        VStack(alignment: .leading) {
            Text("Token Usage")
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding()
    }
}
