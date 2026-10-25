/// Everything in settings.json (ADR-001 §6.1). A later slice adds the tools section. A field
/// missing from the file takes its default, so a file written by an older version still loads.
public struct Settings: Equatable, Codable, Sendable {
    /// The file format's version, for migrations.
    public static let currentVersion = 1

    public var version: Int = Settings.currentVersion
    public var general = General()
    public var focus = FocusSettings()
    public var caffeine = CaffeineSettings()
    /// The models to chat with, in the user's order (§8.1). Tokens are in the Keychain.
    public var endpoints: [Endpoint] = []
    /// The model chat starts with; nil, or the id of one of `endpoints`.
    public var defaultEndpointID: Endpoint.ID?

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Settings.currentVersion
        general = try container.decodeIfPresent(General.self, forKey: .general) ?? General()
        focus = try container.decodeIfPresent(FocusSettings.self, forKey: .focus) ?? FocusSettings()
        caffeine = try container.decodeIfPresent(CaffeineSettings.self, forKey: .caffeine) ?? CaffeineSettings()
        endpoints = try container.decodeIfPresent([Endpoint].self, forKey: .endpoints) ?? []
        // A default that names no endpoint is dropped (§6.1).
        let defaultID = try container.decodeIfPresent(String.self, forKey: .defaultEndpointID)
        defaultEndpointID = endpoints.contains { $0.id == defaultID } ? defaultID : nil
    }
}

/// Settings → General.
public struct General: Equatable, Codable, Sendable {
    public var appearance: Appearance = .system
    /// The terminal Commands open in, by bundle id; nil means the first one installed.
    public var terminalBundleID: String?
    /// Show seconds in the menu bar timers.
    public var menuSeconds = false
    /// Clear an unpinned chat when the HUD closes.
    public var clearOnClose = false
    /// Close the HUD on a click elsewhere.
    public var closeOnClickOutside = true
    public var shortcut = Shortcut.wakeDefault
    /// The first-run welcome was shown.
    public var welcomeDone = false
    /// The macOS version on which the user dismissed the Services isolation notice (R10).
    public var isolationWarningDismissedForOS: String?

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = General()
        appearance = try container.decodeIfPresent(Appearance.self, forKey: .appearance) ?? defaults.appearance
        terminalBundleID = try container.decodeIfPresent(String.self, forKey: .terminalBundleID)
        menuSeconds = try container.decodeIfPresent(Bool.self, forKey: .menuSeconds) ?? defaults.menuSeconds
        clearOnClose = try container.decodeIfPresent(Bool.self, forKey: .clearOnClose) ?? defaults.clearOnClose
        closeOnClickOutside =
            try container.decodeIfPresent(Bool.self, forKey: .closeOnClickOutside) ?? defaults.closeOnClickOutside
        shortcut = try container.decodeIfPresent(Shortcut.self, forKey: .shortcut) ?? defaults.shortcut
        welcomeDone = try container.decodeIfPresent(Bool.self, forKey: .welcomeDone) ?? defaults.welcomeDone
        isolationWarningDismissedForOS = try container.decodeIfPresent(
            String.self, forKey: .isolationWarningDismissedForOS)
    }
}

/// HeadsUp's appearance: the system's, or always light or dark.
public enum Appearance: String, Codable, CaseIterable, Sendable {
    case system, light, dark
}
