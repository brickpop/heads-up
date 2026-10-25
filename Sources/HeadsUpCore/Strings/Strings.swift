import Foundation

#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

/// Every string HeadsUp shows (ADR-001 amendment 1): titles, placeholders, hints, toasts,
/// tooltips and VoiceOver labels. Views contain no literals; they read them from here.
/// The copy comes from the specs and the UX design.
public enum Strings {
    public enum Tabs {
        public static func title(_ tab: Tab) -> String {
            switch tab {
            case .chat: "Chat"
            case .focus: "Focus"
            case .caffeine: "Caffeine"
            case .services: "Services"
            case .commands: "Commands"
            case .settings: "Settings"
            }
        }

        /// "Focus · ⌘2"
        public static func tooltip(_ tab: Tab) -> String { "\(title(tab)) · ⌘\(tab.number)" }

        /// VoiceOver hint for a tab: "⌘2".
        public static func accessibilityHint(_ tab: Tab) -> String { "⌘\(tab.number)" }

        /// VoiceOver value for a tab (UX part 2, §21): "selected", or what its dot means,
        /// e.g. "timer running". Empty when there is nothing to say.
        public static func accessibilityValue(_ tab: Tab, selected: Bool, activity: TabActivity?) -> String {
            if selected { return "selected" }
            switch (tab, activity) {
            case (_, nil): return ""
            case (.focus, .active): return "timer running"
            case (.caffeine, .active): return "on"
            case (.services, .active): return "running"
            case (.services, .alert): return "failed"
            case (_, .active): return "active"
            case (_, .alert): return "needs attention"
            }
        }
    }

    public enum Prompt {
        public static let chatEmpty = "Ask anything, or type /"
        public static let chatReply = "Reply…"
        public static let chatNoModel = "Add a model to chat, or type /"
        public static let otherTab = "Search actions or ask…"
        /// The prompt field, for VoiceOver.
        public static let accessibilityLabel = "Ask or search"
    }

    public enum Suggestions {
        public static let noMatch = "No matching actions"
        /// The suggestion list, for VoiceOver.
        public static let accessibilityLabel = "Suggestions"
        /// The keycap on the selected row.
        public static let runKey = "⏎"
        public static func ask(_ model: String) -> String { "Ask \(model)" }
        public static let setUpModel = "Set up a model to chat"
        public static let setUpModelSubtitle = "Settings → Models"

        /// The input in curly quotes, cut to `limit` characters plus "…".
        public static func quote(_ text: String, limit: Int) -> String {
            let cut = text.count > limit ? String(text.prefix(limit)) + "…" : text
            return "“\(cut)”"
        }

        /// VoiceOver: "Start 25 min focus, Focus, 1 of 6".
        public static func accessibilityRow(title: String, kind: String, position: Int, count: Int) -> String {
            "\(title), \(kind), \(position) of \(count)"
        }
    }

    public enum Hints {
        public static let suggestions = [
            Hint(keys: ["↑", "↓"], label: "navigate"),
            Hint(keys: ["⏎"], label: "run"),
            Hint(keys: ["esc"], label: "clear"),
        ]
        public static let noMatch = [
            Hint(keys: ["↓"], label: "ask instead"),
            Hint(keys: ["esc"], label: "clear"),
        ]
        public static let chat = [
            Hint(keys: ["⏎"], label: "send"),
            Hint(keys: ["/"], label: "actions"),
            Hint(keys: ["⌘P"], label: "pin"),
            Hint(keys: ["⌘N"], label: "new"),
        ]
        public static let otherTab = [
            Hint(keys: ["⌘1–6"], label: "switch"),
            Hint(keys: ["/"], label: "actions"),
            Hint(keys: ["esc"], label: "close"),
        ]
    }

    public enum ActionKinds {
        public static func label(_ kind: ActionKind) -> String {
            switch kind {
            case .chat: "Chat"
            case .focus: "Focus"
            case .caffeine: "Caffeine"
            case .model: "Model"
            case .service: "Service"
            case .command: "Command"
            case .view: "View"
            case .action: "Action"
            }
        }
    }

    public enum Actions {
        public static func goTo(_ tab: Tab) -> String { "Go to \(Tabs.title(tab))" }
        public static func goToSubtitle(_ tab: Tab) -> String { "view · ⌘\(tab.number)" }

        public static let toggleTheme = "Toggle theme"
        public static let useSystemAppearance = "Use system appearance"

        /// "appearance · Dark → Light", or "appearance · System (Dark) → Light".
        public static func toggleThemeSubtitle(current: Appearance, systemIsDark: Bool) -> String {
            let from: String
            switch current {
            case .system: from = "System (\(systemIsDark ? "Dark" : "Light"))"
            case .light: from = "Light"
            case .dark: from = "Dark"
            }
            let effectiveDark = current == .dark || (current == .system && systemIsDark)
            return "appearance · \(from) → \(effectiveDark ? "Light" : "Dark")"
        }

        /// "appearance · Light → System"
        public static func useSystemSubtitle(current: Appearance) -> String {
            "appearance · \(current == .dark ? "Dark" : "Light") → System"
        }

        public static let addModel = "Add a model"
        public static let addModelSubtitle = "model · Settings → Models"
    }

    public enum Hotkey {
        /// The note under General → Wake shortcut and in the welcome (UX addendum 4).
        public static func problem(_ status: HotkeyStatus, shortcut: Shortcut) -> String? {
            let name = shortcut.displayName
            switch status {
            case .ok: return nil
            case .taken: return "\(name) is used by another app. Choose another."
            case .reservedBySystem:
                return "\(name) is used by macOS. Choose another, or turn it off in "
                    + "System Settings → Keyboard → Keyboard Shortcuts."
            case .failed: return "HeadsUp couldn't set up \(name). Choose another shortcut, or try again."
            }
        }
    }

    public enum HUD {
        /// The HUD as one VoiceOver group (UX part 2, §21).
        public static let accessibilityLabel = "HeadsUp"
    }

    /// The hidden main menu's Edit menu, so the standard editing keys work in the prompt.
    public enum EditMenu {
        public static let edit = "Edit"
        public static let undo = "Undo"
        public static let redo = "Redo"
        public static let cut = "Cut"
        public static let copy = "Copy"
        public static let paste = "Paste"
        public static let selectAll = "Select All"
    }

    /// File errors in plain words (ADR-001 amendment 2).
    public enum Files {
        public static func plainWords(errno code: Int32) -> String {
            switch code {
            case ENOSPC, EDQUOT: "The disk is full."
            case EACCES, EPERM: "HeadsUp isn't allowed to write to its settings folder."
            case EROFS: "The disk is read-only."
            default: "The file couldn't be written."
            }
        }
    }

    /// The settings-file problem, in the notice bar and in Settings → General (Yuki's copy).
    public enum SettingsFile {
        public static func title(_ problem: SettingsFileProblem) -> String {
            switch problem {
            case .keptAside: "HeadsUp started with default settings"
            case .unreadable: "Your settings aren't being saved"
            case .newerVersion: "These settings are from a newer version of HeadsUp"
            case .saveFailed: "Settings couldn't be saved"
            }
        }

        public static func text(_ problem: SettingsFileProblem) -> String {
            switch problem {
            case .keptAside(let kept):
                "Your settings file couldn't be read, so HeadsUp kept it as \(kept.lastPathComponent) and started fresh."
            case .unreadable:
                "HeadsUp couldn't read your settings file or move it aside. It's using default settings for now."
            case .newerVersion:
                "HeadsUp is using default settings and won't change the file, so the newer version keeps its settings."
            case .saveFailed(let reason):
                "\(reason) Changes are kept until you quit."
            }
        }

        public static let savingOffLine = "Changes aren't saved right now. See General."
        public static let saved = "Settings saved"
    }

    /// The once-per-launch notice bar at the top of the HUD body.
    public enum SettingsNotice {
        public static let openSettings = "Open Settings"
        /// The × button's VoiceOver label.
        public static let dismiss = "Dismiss"
    }
}
