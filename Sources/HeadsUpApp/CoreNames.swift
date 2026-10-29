import HeadsUpCore

// Core types whose names the macOS SDK also uses: SwiftUI has `Tab` (macOS 15) and
// ApplicationServices has `Pasteboard`. A name declared in this module wins over the imported
// ones, so these make the plain name mean the core type everywhere in the app.
typealias Tab = HeadsUpCore.Tab
typealias Pasteboard = HeadsUpCore.Pasteboard

// Views keep their state in `State(initialValue:)`, not the @State attribute: in the new SDK
// that is a macro, and the Command Line Tools have no SwiftUI macro plugin (tools/lint.sh, 6).
