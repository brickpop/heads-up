import AppKit
import HeadsUpCore
import ServiceManagement

/// Open at Login through `SMAppService.mainApp` (macOS 13+): HeadsUp itself is the login
/// item, with no helper app.
@MainActor
final class LoginItemAdapter: LoginItem {
    var appLocation: URL { Bundle.main.bundleURL }

    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .disabled
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

/// Opens System Settings panes.
@MainActor
final class SystemSettingsAdapter: SystemSettingsLinks {
    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func openKeyboardShortcuts() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func openAutomation() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }
}
