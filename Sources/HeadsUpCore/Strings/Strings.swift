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

    /// The menu bar item and its menu (App shell spec; UX part 2, §14 and §16).
    public enum MenuBar {
        public static let appName = "HeadsUp"
        public static let openHUD = "Open HUD"
        public static let pinnedChats = "Pinned chats"
        public static let settings = "Settings…"
        public static let quit = "Quit HeadsUp"
        public static let paused = "Paused"
        public static let snoozed = "Snoozed"
        public static let caffeineOn = "caffeine on"
        public static let caffeinePaused = "caffeine paused on battery"

        public static func startFocus(_ minutes: Int) -> String { "Start \(minutes) min" }
        /// "2 running", or "None" when nothing runs.
        public static func running(_ count: Int) -> String { count == 0 ? "None" : "\(count) running" }

        /// "Break due" or "Break over": the words the item and the menu show for a waiting prompt.
        public static func promptWords(_ prompt: FocusSnapshot.Prompt) -> String {
            switch prompt {
            case .breakDue: "Break due"
            case .breakOver: "Break over"
            }
        }

        /// "Focus" or "Break", as a menu value starts.
        public static func kindTitle(_ kind: FocusSnapshot.Kind) -> String {
            kind == .focus ? "Focus" : "Break"
        }

        /// "focus" or "break", inside a VoiceOver sentence.
        public static func kindName(_ kind: FocusSnapshot.Kind) -> String {
            kind == .focus ? "focus" : "break"
        }
    }

    /// The shortcut recorder (UX part 2, §13; amendment 5).
    public enum Recorder {
        public static let prompt = "Type a shortcut…"
        /// The ×'s VoiceOver label.
        public static let cancel = "Cancel"
        public static func reset(_ shortcut: String) -> String { "Reset to \(shortcut)" }
        public static let accessibilityLabel = "Wake shortcut"
        public static let needsModifier = "Add ⌘, ⌥ or ⌃."
        public static let usedByHeadsUp = "HeadsUp uses this shortcut. Choose another."

        /// Why the keys can't be a wake shortcut, before registering them.
        public static func keysProblem(_ problem: ShortcutProblem) -> String {
            switch problem {
            case .needsModifier: needsModifier
            case .usedByHeadsUp: usedByHeadsUp
            case .reservedBySystem, .taken, .failed: "That shortcut can't be used. Choose another."
            }
        }

        /// Why a shortcut wasn't saved, or nil when it was.
        public static func problem(_ status: HotkeyStatus, shortcut: Shortcut) -> String? {
            switch status {
            case .ok: nil
            case .taken: "Another app already uses this shortcut. Choose another."
            case .reservedBySystem, .failed: Hotkey.problem(status, shortcut: shortcut)
            }
        }
    }

    /// The first-run welcome (UX part 1, §3; addendum 4).
    public enum Welcome {
        public static let title = "Welcome to HeadsUp"
        public static func pressShortcut(_ name: String) -> String {
            "Press \(name) in any app to open this. Press it again, or Esc, to hide it."
        }
        public static let pressYourShortcut = "Press your shortcut in any app to open this."
        /// The line before the welcome's recorder when the shortcut doesn't work: the reason for
        /// its state, then "Choose a shortcut:" (Rev 5).
        public static func problemLine(_ status: HotkeyStatus, shortcut: Shortcut) -> String? {
            Hotkey.reason(status, shortcut: shortcut).map { "\($0) Choose a shortcut:" }
        }
        public static let addModel = "Add a model to chat with"
        public static let setUpModel = "Set up a model"
        public static let openAtLogin = "Open HeadsUp when you log in"
        public static let changeLater = "You can change both later in Settings."
    }

    /// Settings → General (Settings spec; UX part 2, §12, §19, §20).
    public enum General {
        public static let title = "General"
        public static let openAtLogin = "Open at Login"
        public static let openAtLoginHelp = "Starts HeadsUp in the menu bar when you log in."
        public static let loginNeedsApproval = "Allow HeadsUp in System Settings → General → Login Items."
        public static let openLoginItems = "Open Login Items"
        /// The note under Open at Login (Yuki, msg-207): guidance, in --ink-2, not an error.
        public static func loginNote(_ note: OpenAtLoginNote) -> String {
            switch note {
            case .needsApproval: loginNeedsApproval
            case .moveToApplications:
                "To open at login, HeadsUp must be in your Applications folder. Move it there, then open it from there."
            case .couldNotAdd:
                "macOS couldn't add HeadsUp to your login items. Quit HeadsUp, open it again, then try once more."
            }
        }
        public static let showInFinder = "Show in Finder"
        public static let loginCouldNotChange =
            "HeadsUp couldn't change Open at Login. Try again in System Settings → General → Login Items."
        public static let wakeShortcut = "Wake shortcut"
        public static let appearance = "Appearance"
        public static func appearanceName(_ appearance: Appearance) -> String {
            switch appearance {
            case .system: "System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }
        public static let menuSeconds = "Show seconds in the menu bar"
        public static let menuSecondsHelp = "Off: focus and caffeine timers show minutes only"
        public static let clearOnClose = "Clear unpinned chat when the HUD closes"
        public static let clearOnCloseHelp = "Off: the chat stays until ⌘N or quit"
        public static let closeOnClickOutside = "Close the HUD when you click elsewhere"
        public static func closeOnClickOutsideHelp(shortcut: String) -> String {
            "Off: it stays open until you press Esc or \(shortcut)."
        }
        public static let openKeyboardSettings = "Open Keyboard Settings"
        public static let tryAgain = "Try Again"
    }

    /// Settings' sub-nav (Settings spec).
    public enum SettingsSections {
        public static func title(_ section: SettingsSection) -> String {
            switch section {
            case .models: "Models"
            case .tools: "Tools"
            case .focus: "Focus"
            case .general: "General"
            case .services: "Services"
            case .commands: "Commands"
            }
        }
    }

    /// Notifications (UX part 2, "Notifications (copy)"; addendum 4).
    public enum Notifications {
        public static func focusDoneTitle(_ minutes: Int) -> String { "Focus done · \(minutes) min" }
        public static let focusDoneBody = "Time for a break."
        public static let breakOverTitle = "Break over"
        public static let breakOverBody = "Ready to get back to it?"
        /// A snoozed prompt returns (Yuki).
        public static let snoozeOverBreakTitle = "Time for a break"
        public static func snoozeOverBreakBody(focusMinutes: Int?) -> String {
            guard let focusMinutes else { return "Snooze is over." }
            return "Snooze is over. Your \(focusMinutes) min focus is done."
        }
        public static let snoozeOverBackBody = "Snooze is over. Ready to get back to it?"
        public static func focusStartedBody(_ minutes: Int) -> String { Focus.focusStarted(minutes) }

        public static func actionTitle(_ action: NotificationAction) -> String {
            switch action {
            case .startBreak: "Start break"
            case .startFocus: "Start focus"
            case .snooze: "Snooze"
            case .stop: "Stop"
            }
        }
    }

    /// The Focus tab, its toasts, pill and actions (Focus spec; footer spec).
    public enum Focus {
        // Toasts
        public static func focusStarted(_ minutes: Int) -> String { "Focus started · \(minutes) min" }
        public static func breakStarted(_ minutes: Int) -> String { "Break started · \(minutes) min" }
        public static func snoozed(_ minutes: Int) -> String { "Snoozed for \(minutes) min" }
        /// The toast when a session ends while the user works in the open HUD (Yuki).
        public static let focusDoneAnnouncement = "Focus done · time for a break"
        public static let breakOverAnnouncement = "Break over"
        /// The toast when a snoozed break prompt returns to an open HUD in use.
        public static let snoozeOverBreakAnnouncement = "Time for a break"

        // Footer pill
        public static func pillFocus(_ clock: String) -> String { "Focus \(clock)" }
        public static func pillBreak(_ clock: String) -> String { "Break \(clock)" }
        public static func pillSnoozed(_ clock: String) -> String { "Snoozed \(clock)" }

        // Actions
        public static func startAction(_ minutes: Int) -> String { "Start \(minutes) min focus" }
        public static let startSubtitle = "pomodoro · focus session"
        public static let stopAction = "Stop timer"
        public static func stopSubtitle(break isBreak: Bool) -> String { "pomodoro · \(isBreak ? "break" : "focus")" }
        public static let breakNowAction = "Take a break now"
        public static let breakNowSubtitle = "pomodoro · break options"

        // Idle
        public static let idleLabel = "Focus session"
        /// The manual break prompt's label before any session today (Yuki).
        public static let noSessionsYet = "No sessions yet today"
        /// "2 sessions · 1h 05m focused today"
        public static func todayStats(_ day: FocusDay) -> String {
            let sessions = day.sessions == 1 ? "1 session" : "\(day.sessions) sessions"
            let minutes = day.minutes == 0 ? "0m" : Format.minutes(Double(day.minutes) * 60, rounding: .nearest)
            return "\(sessions) · \(minutes) focused today"
        }
        public static func lengthHint(_ minutes: Int) -> String {
            switch minutes {
            case 25: "Classic pomodoro"
            case 40: "Steady block"
            default: "Deep work"
            }
        }
        public static func minutes(_ minutes: Int) -> String { "\(minutes) min" }
        /// "Breaks offer: look elsewhere, drink water, stretch your arms…"
        public static func breaksOffer(_ options: [BreakOption]) -> String {
            let first = options.prefix(3).map { $0.label.lowercased() }.joined(separator: ", ")
            return "Breaks offer: \(first)\(options.count > 3 ? "…" : "")"
        }
        public static let startFocus = "Start focus"

        // Running
        public static let focusing = "Focusing"
        public static let focusPaused = "Focus · paused"
        public static let breakPaused = "Break · paused"
        /// VoiceOver for the big timer: "18 minutes left".
        public static func timeLeftAccessibility(_ spoken: String) -> String { "\(spoken) left" }
        public static func breakLabel(_ activity: String) -> String { "Break · \(activity)" }
        /// "25 min session · break at 3:30 PM"
        public static func sessionSubtitle(minutes: Int, breakAt: String) -> String {
            "\(minutes) min session · break at \(breakAt)"
        }
        public static let breakSubtitle = "Step away. The HUD will call you back."
        public static let stop = "Stop"
        public static let endBreak = "End break"
        public static let pause = "Pause"
        public static let resume = "Resume"

        // Break prompt
        public static func sessionDone(minutes: Int, today: Int) -> String {
            "\(minutes) min session done · \(today) today"
        }
        public static let timeForABreak = "Time for a break"
        public static let length = "Length"
        public static let keepWorking = "Keep working"
        public static let keepWorkingHelp = "Skip the break and start the next focus session"
        public static func snooze(_ minutes: Int) -> String { "Snooze \(minutes) min" }
        public static func startBreak(_ minutes: Int) -> String { "Start \(minutes) min break" }

        // Back prompt
        public static let breakFinished = "Break finished"
        public static let readyToGetBack = "Ready to get back to it?"
        public static let doneForNow = "Done for now"
        public static func startFocusOf(_ minutes: Int) -> String { "Start \(minutes) min focus" }

        // Snoozed
        public static let snoozedLabel = "Snoozed"
        public static func promptReturns(_ clock: String) -> String { "Prompt returns in \(clock)" }
        public static let showNow = "Show now"
    }

    /// Settings → Focus (Settings spec "Focus"; UX part 2, §11).
    public enum FocusSettings {
        public static let title = "Focus & breaks"
        public static let intro = "Options shown when a focus session ends."
        public static let focusLength = "Focus length"
        public static let autoStart = "Start the next focus after a break"
        public static let autoStartHelp = "Skips “Ready to get back to it?”"
        public static let snoozeLength = "Snooze length"
        public static let openHud = "Open the HUD when a session ends"
        public static let openHudHelp = "Otherwise only a notification is sent"
        public static let addPlaceholder = "Add an option, e.g. Walk around the block"
        public static let add = "Add"
        public static let length = "Length"
        public static let lengthHint = "Click a length on an option to change it."
        /// The length pill's tooltip.
        public static let changeLength = "Change length"
        /// The ×'s VoiceOver label.
        public static let remove = "Remove"
        /// The disabled ×'s tooltip on the last option.
        public static let keepOne = "Keep at least one option"
        /// "5m"
        public static func minutesShort(_ minutes: Int) -> String { "\(minutes)m" }
        /// The segmented choices: "25 min", "2 min".
        public static func minutes(_ minutes: Int) -> String { "\(minutes) min" }
    }

    /// The Caffeine tab, its toasts, pill and actions (Caffeine spec; footer spec; UX §15).
    public enum Caffeine {
        // Toasts
        public static let onBySwitch = "Caffeine on. Your Mac stays awake"
        /// Turned on while "Only on power adapter" holds it on battery.
        public static let onPausedBySwitch = "Caffeine on · paused until you plug in"
        /// "Caffeine on · 1 hour · paused until you plug in"
        public static func onPaused(_ label: String) -> String { "Caffeine on · \(label) · paused until you plug in" }
        public static let off = "Caffeine off"
        /// A duration card picked while off: "Caffeine on · 15 min".
        public static func onByCard(_ duration: CaffeineDuration) -> String { "Caffeine on · \(cardTitle(duration))" }
        /// An autocomplete action: "Caffeine on · for 1 hour".
        public static func onByAction(_ duration: CaffeineDuration) -> String {
            "Caffeine on · \(actionSuffix(duration))"
        }
        public static func extended(_ minutes: Int) -> String {
            minutes == 60 ? "Caffeine extended by 1 hour" : "Caffeine extended by \(minutes) min"
        }

        // Footer pill
        public static func pillAwake(_ left: String?) -> String { left.map { "Awake \($0)" } ?? "Awake" }
        public static func pillPaused(_ left: String?) -> String { left.map { "Paused \($0)" } ?? "Paused" }

        // Header
        public static let titleOn = "Staying awake"
        public static let titleOff = "Caffeine is off"
        public static let titlePaused = "Paused on battery"
        public static let subtitleOff = "Your Mac sleeps and starts the screensaver as usual."
        public static let subtitleUntilOff = "Until you turn it off"
        /// "45m left · ends at 3:30 PM"
        public static func subtitleLeft(_ left: String, endsAt: String) -> String { "\(left) left · ends at \(endsAt)" }
        public static let resumesOnPower = "Resumes on power"
        /// "Resumes on power · 45m left · ends at 3:30 PM"
        public static func subtitlePaused(_ left: String, endsAt: String) -> String {
            "\(resumesOnPower) · \(subtitleLeft(left, endsAt: endsAt))"
        }
        public static let switchLabel = "Caffeine"

        // Extend row
        public static let needLonger = "Need a bit longer?"
        public static let plusTen = "+10 min"
        public static let plusHour = "+1 h"

        // Durations
        public static let keepAwakeFor = "Keep awake for"
        public static func cardTitle(_ duration: CaffeineDuration) -> String {
            switch duration {
            case .fifteenMinutes: "15 min"
            case .oneHour: "1 hour"
            case .twoHours: "2 hours"
            case .untilOff: "Until off"
            }
        }

        // Options
        public static let keepDisplayOn = "Keep the display on"
        public static let keepDisplayOnHelp = "Blocks the screensaver and display sleep"
        public static let preventSystemSleep = "Prevent system sleep"
        public static let preventSystemSleepHelp = "Keeps background jobs and services running"
        public static let onlyOnAC = "Only on power adapter"
        public static let onlyOnACHelp = "Pauses automatically on battery"
        /// The tooltip on the one option that can't be turned off.
        public static let keepOneOn = "Keep at least one on."
        /// The --danger note under the header when macOS refuses (Yuki), with Try Again.
        public static func assertionNote(_ problem: CaffeineAssertionProblem) -> String {
            switch problem {
            case .refused: "macOS didn't let HeadsUp keep your Mac awake."
            case .displayRefused: "macOS didn't let HeadsUp keep the display on."
            case .systemRefused: "macOS didn't let HeadsUp keep your Mac from sleeping."
            }
        }
        public static let tryAgain = "Try Again"

        // Actions
        public static func keepAwakeAction(_ duration: CaffeineDuration) -> String {
            "Keep awake \(actionSuffix(duration))"
        }
        public static let keepAwakeSubtitle = "caffeine · prevent sleep"
        public static func extendAction(_ minutes: Int) -> String {
            minutes == 60 ? "Add 1 hour to caffeine" : "Add \(minutes) min to caffeine"
        }
        public static let extendSubtitle = "caffeine · extend current timer"
        public static let offAction = "Caffeine off"
        public static let offSubtitle = "allow sleep again"

        static func actionSuffix(_ duration: CaffeineDuration) -> String {
            switch duration {
            case .fifteenMinutes: "for 15 min"
            case .oneHour: "for 1 hour"
            case .twoHours: "for 2 hours"
            case .untilOff: "until turned off"
            }
        }
    }

    public enum Hotkey {
        /// What is wrong with the wake shortcut, in one sentence, or nil when it works.
        public static func reason(_ status: HotkeyStatus, shortcut: Shortcut) -> String? {
            let name = shortcut.displayName
            switch status {
            case .ok: return nil
            case .taken: return "\(name) is used by another app."
            case .reservedBySystem: return "\(name) is used by macOS."
            case .failed: return "HeadsUp couldn't set up \(name)."
            }
        }

        /// The lasting note under General → Wake shortcut (UX addendum 4).
        public static func problem(_ status: HotkeyStatus, shortcut: Shortcut) -> String? {
            guard let reason = reason(status, shortcut: shortcut) else { return nil }
            switch status {
            case .ok, .taken: return "\(reason) Choose another."
            case .reservedBySystem:
                return "\(reason) Choose another, or turn it off in System Settings → Keyboard → Keyboard Shortcuts."
            case .failed: return "\(reason) Choose another shortcut, or try again."
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
    /// File names in this copy are wrapped in backticks, so the view can show them in mono.
    public enum SettingsFile {
        public static func title(_ problem: SettingsFileProblem) -> String {
            switch problem {
            case .keptAside: "HeadsUp started with default settings"
            case .unreadable: "Your settings aren't being saved"
            case .newerVersion: "These settings are from a newer version of HeadsUp"
            case .defaultsChosen: "HeadsUp is using default settings"
            case .saveFailed: "Settings couldn't be saved"
            }
        }

        public static func text(_ problem: SettingsFileProblem) -> String {
            switch problem {
            case .keptAside(let kept):
                "Your settings file couldn't be read, so HeadsUp kept it as `\(kept.lastPathComponent)` and started fresh."
            case .unreadable:
                "HeadsUp couldn't read your settings file or move it aside. It's using default settings for now."
            case .newerVersion:
                "HeadsUp is using default settings and won't change the file, so the newer version keeps its settings."
            case .defaultsChosen(let kept):
                "Your old file is kept as `\(kept.lastPathComponent)`."
            case .saveFailed(let reason, nil):
                "\(reason) Changes are kept until you quit."
            case .saveFailed(let reason, let kept?):
                "\(reason) Your old file is kept as `\(kept.lastPathComponent)`. Changes are kept until you quit."
            }
        }

        public static let savingOffLine = "Changes aren't saved right now. See General."
        public static let saved = "Settings saved"
        public static let showInFinder = "Show in Finder"
        public static let useDefaultsAndSave = "Use Defaults and Save…"
        public static let cancel = "Cancel"
        /// The confirm's button (no longer red: nothing is lost).
        public static let useDefaults = "Use Defaults"
        public static let tryAgain = "Try Again"
        /// The ×'s VoiceOver label on a card about a file kept aside.
        public static let dismiss = "Dismiss"

        /// The inline question before Use Defaults (Yuki's update for Scan L2), naming the file
        /// the old one will be kept as. `SettingsStore.useDefaultsConfirmation` fills it in.
        public static func confirm(_ problem: SettingsFileProblem, keptAs name: String) -> String {
            switch problem {
            case .newerVersion:
                "Use default settings? The newer version's file is kept as `\(name)`. "
                    + "That version will also start with these defaults until you put its file back."
            case .keptAside, .unreadable, .defaultsChosen, .saveFailed:
                "Start over with default settings? Your current file is kept as `\(name)`."
            }
        }
    }

    /// The once-per-launch notice bar at the top of the HUD body.
    public enum SettingsNotice {
        public static let openSettings = "Open Settings"
        /// The × button's VoiceOver label.
        public static let dismiss = "Dismiss"
    }
}
