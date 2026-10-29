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

    /// The tab `delta` places away in the bar, wrapping at the ends: ⌘← (-1) and ⌘→ (+1).
    public func step(_ delta: Int) -> Tab {
        let tabs = Tab.allCases
        let count = tabs.count
        return tabs[((tabs.firstIndex(of: self)! + delta) % count + count) % count]
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

extension SettingsSection {
    public var title: String { Strings.SettingsSections.title(self) }

    public var glyph: Glyph {
        switch self {
        case .models: .cpu
        case .tools: .folder
        case .focus: .timer
        case .general: .sliders
        case .services: .servers
        case .commands: .terminal
        }
    }

    /// The sub-nav's groups, with a gap between them.
    public static let groups: [[SettingsSection]] = [[.models, .tools], [.focus, .services, .commands], [.general]]
}
