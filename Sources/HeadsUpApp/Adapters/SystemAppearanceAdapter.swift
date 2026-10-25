import AppKit
import HeadsUpCore

/// Whether macOS itself is in Dark Mode, whatever HeadsUp's own appearance setting.
@MainActor
final class SystemAppearanceAdapter: SystemAppearance {
    var isDark: Bool {
        // The global setting (the standard defaults search the global domain), not
        // NSApp.effectiveAppearance, which follows our own override.
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }
}
