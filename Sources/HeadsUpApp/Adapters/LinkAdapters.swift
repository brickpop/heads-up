import AppKit
import HeadsUpCore

/// Opens a link from a reply in the user's default app.
@MainActor
final class WorkspaceLinkOpener: LinkOpener {
    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

/// The general pasteboard, plain text only.
@MainActor
final class GeneralPasteboard: Pasteboard {
    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
