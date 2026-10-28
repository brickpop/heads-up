import HeadsUpCore

// Core types whose names the macOS SDK also uses: SwiftUI has `Tab` (macOS 15) and
// ApplicationServices has `Pasteboard`. A name declared in this module wins over the imported
// ones, so these make the plain name mean the core type everywhere in the app.
typealias Tab = HeadsUpCore.Tab
typealias Pasteboard = HeadsUpCore.Pasteboard
