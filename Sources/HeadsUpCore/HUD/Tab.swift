/// The HUD's six tabs, in their fixed order.
public enum Tab: String, CaseIterable, Codable, Sendable {
    case chat, focus, caffeine, services, commands, settings

    /// 1…6: the tab's place in the bar, and its ⌘ number.
    public var number: Int { Tab.allCases.firstIndex(of: self)! + 1 }

    /// The tab for ⌘1…6, or nil for any other number.
    public init?(number: Int) {
        guard (1...Tab.allCases.count).contains(number) else { return nil }
        self = Tab.allCases[number - 1]
    }

    public var title: String { Strings.Tabs.title(self) }
    public var glyph: Glyph {
        switch self {
        case .chat: .chat
        case .focus: .timer
        case .caffeine: .cup
        case .services: .servers
        case .commands: .terminal
        case .settings: .sliders
        }
    }
}

/// What a tab's activity dot shows. A tab with no activity has no entry in `AppModel.tabActivity`.
public enum TabActivity: Equatable, Sendable {
    /// The accent dot: something on this tab is running.
    case active
    /// The red dot: something on this tab failed and the user hasn't looked yet.
    case alert
}

/// Which view the Chat tab shows.
public enum ChatView: Equatable, Sendable {
    case conversation, pinned
}

/// The sections of the Settings tab, in sub-nav order.
public enum SettingsSection: String, CaseIterable, Sendable {
    case models, tools, focus, general, services, commands
}
