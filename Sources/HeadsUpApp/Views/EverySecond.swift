import SwiftUI

/// Redraws its content once a second, on the second, while `isRunning`, and draws it once
/// otherwise. The HUD passes whether it is open, so a hidden HUD costs no CPU.
struct EverySecond<Content: View>: View {
    let isRunning: Bool
    @ViewBuilder let content: (Date) -> Content

    var body: some View {
        if isRunning {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                content(context.date)
            }
        } else {
            content(Date())
        }
    }
}
