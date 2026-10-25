// The app's entry point. HeadsUp runs as an accessory: no Dock icon (LSUIElement in
// Info.plist). Slice 1 adds the hidden Edit menu, slice 2 the menu bar item.

import AppKit

@main
@MainActor
enum HeadsUpMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // NSApplication holds its delegate weakly: keep it alive while the app runs.
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
