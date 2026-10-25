import AppKit
import HeadsUpCore

/// Shows a file in Finder, selected (Show in Finder).
@MainActor
final class FinderRevealer: FileRevealer {
    func reveal(_ file: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }
}
