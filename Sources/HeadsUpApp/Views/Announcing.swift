import SwiftUI

extension View {
    /// Has VoiceOver announce `text` when this view appears, and again whenever the text changes
    /// while it shows: a problem line replaced by a different one is news too. The same text is
    /// not repeated.
    func announcing(_ text: String) -> some View {
        onAppear { AccessibilityNotification.Announcement(text).post() }
            .onChange(of: text) { _, new in AccessibilityNotification.Announcement(new).post() }
    }
}
