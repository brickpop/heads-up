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
        /// While a reply comes (UX part 1, §5).
        public static let chatBusy = [
            Hint(keys: ["⌘."], label: "stop"),
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
        /// The Services row: "2 running · 1 failed", "1 starting", or "None" (UX part 1 §9, addendum 4).
        public static func services(_ snapshot: ServicesSnapshot) -> String {
            var parts: [String] = []
            if snapshot.running > 0 { parts.append("\(snapshot.running) running") }
            if snapshot.starting > 0 { parts.append("\(snapshot.starting) starting") }
            if snapshot.failed > 0 { parts.append("\(snapshot.failed) failed") }
            return parts.isEmpty ? "None" : parts.joined(separator: " · ")
        }

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
            case .showLogs: "Show Logs"
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
        /// The extend buttons: "+10 min", "+1 h".
        public static func plus(_ minutes: Int) -> String { minutes == 60 ? "+1 h" : "+\(minutes) min" }

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

    /// The Services tab, its log, form and quit question (Services spec; UX part 1 §1, §9, §10;
    /// addendum 4; Yuki's Services copy). All of it is Yuki's final copy.
    public enum Services {
        // Form problems (the shared ones are in ListForm)
        public static let portProblem = "Enter a port from 1 to 65535, or leave it empty."
        public static let envKeyProblem = "Use only letters, digits and _, and don't start with a digit."
        /// The --warn meta line of a service from services.json that breaks a rule: the form's
        /// problem note in lower case, "Can't start · enter a command to run".
        public static func cantStart(_ problem: String) -> String { "Can't start · \(ListForm.inline(problem))" }

        // Log lines
        public static func commandLine(_ command: String) -> String { "$ \(command)" }
        public static let starting = "starting…"
        public static func exited(code: Int32) -> String { "process exited (code \(code))" }
        public static func killed(signal: String) -> String { "process exited (\(signal))" }
        public static func shellFallback(_ shell: String) -> String {
            "\(shell) isn't supported for services; running in zsh"
        }
        public static let withoutSeparatePermissions = "started without separate permissions (macOS limitation)"
        public static func couldNotStart(_ reason: String) -> String { "couldn't start: \(reason)" }

        // Toasts
        public static func started(_ name: String) -> String { "Started \(name)" }
        public static func stopped(_ name: String) -> String { "Stopped \(name)" }
        public static func added(_ name: String) -> String { "Added \(name)" }
        public static func saved(_ name: String) -> String { "Saved \(name)" }
        public static func removed(_ name: String) -> String { "Removed \(name)" }

        // The tab
        public static func tabLabel(running: Int) -> String { "Services · \(running) running" }
        public static let tabNote = "Logs are always recorded, hidden until you open them"
        public static let emptyTitle = "No services yet"
        public static let emptyText = "Add a dev server, a database or a local model, then start and stop it here."
        public static let addService = "Add a service…"
        /// The header's button, and the button of a row that can't start.
        public static let edit = "Edit…"
        public static let noOutput = "No output yet. Start the service to see its logs."
        /// Each row's Logs toggle.
        public static let logs = "Logs"
        public static let clear = "Clear"
        public static let ok = "OK"
        public static let isolationTitle = "Services run with HeadsUp's permissions on this version of macOS."
        public static let isolationText = "A service can read your calendar and reminders if HeadsUp can."
        /// "Starting…", or "Starting… waiting for :3000".
        public static func startingMeta(port: Int?) -> String {
            port.map { "Starting… waiting for :\($0)" } ?? "Starting…"
        }
        /// ":3000 · 42m", or "42m" before a port is known.
        public static func runningMeta(port: Int?, uptime: String) -> String {
            port.map { ":\($0) · \(uptime)" } ?? uptime
        }
        /// "Running · nothing on :3000 yet", in --warn: alive for 30 s, but its port is silent.
        public static func silentMeta(port: Int) -> String { "Running · nothing on :\(port) yet" }
        /// "Exited with code 1 · 2 min ago"
        public static func failedMeta(code: Int32, ago: String) -> String { "Exited with code \(code) · \(ago)" }
        /// "just now", "12 min ago", "5 h ago", "yesterday", then the short local date: "Oct 21".
        public static func ago(
            _ date: Date, now: Date, locale: Locale = .current, timeZone: TimeZone = .current
        ) -> String {
            let minutes = Int(now.timeIntervalSince(date) / 60)
            if minutes < 1 { return "just now" }
            if minutes < 60 { return "\(minutes) min ago" }
            if minutes < 24 * 60 { return "\(minutes / 60) h ago" }
            if minutes < 48 * 60 { return "yesterday" }
            var style = Date.FormatStyle.dateTime.month(.abbreviated).day()
            style.locale = locale
            style.timeZone = timeZone
            return date.formatted(style)
        }
        /// VoiceOver: "running", "stopped", "failed" (UX part 2, §21), "starting" (addendum 4).
        public static func statusWord(_ status: ServicesScreen.Status) -> String {
            switch status {
            case .stopped: "stopped"
            case .starting: "starting"
            case .running: "running"
            case .failed: "failed"
            }
        }

        // Actions
        public static func startAction(_ name: String) -> String { "Start \(name)" }
        public static func stopAction(_ name: String) -> String { "Stop \(name)" }
        public static func restartAction(_ name: String) -> String { "Restart \(name)" }
        public static let startVerb = "Start"
        public static let stopVerb = "Stop"
        public static let restartVerb = "Restart"
        /// "npm run dev · ~/code/web-app"
        public static func actionSubtitle(command: String, cwd: String) -> String { "\(command) · \(cwd)" }

        // The quit question (UX part 1, §10)
        public static let quitTitle = "Quit HeadsUp?"
        public static func quitMessage(_ names: [String]) -> String {
            if names.count == 1 { return "\(names[0]) is running. Quitting stops it." }
            let list = names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
            return "\(names.count) services are running: \(list). Quitting stops them."
        }
        public static let quitAlsoStops = "Your focus timer and Caffeine also stop."
        public static let quitAndStop = "Quit and Stop"
        public static let cancel = "Cancel"

        public static func failedTitle(_ name: String) -> String { "\(name) stopped" }
        public static func failedBody(code: Int32) -> String { "It exited with code \(code)." }
    }

    /// services.json and commands.json (Yuki's Services copy, the same for Commands): the card in
    /// the tab and in Settings, and the form's save problem. File names are in backticks, so the
    /// view can show them in mono.
    public enum ListFile {
        public static func title(_ problem: ListFileProblem, kind: ListFileKind) -> String {
            switch problem {
            case .unreadable: "Your \(kind.plural) couldn't be loaded"
            case .newerVersion: "These \(kind.plural) are from a newer version of HeadsUp"
            }
        }
        public static func text(_ problem: ListFileProblem, kind: ListFileKind) -> String {
            let file = "`\(kind.fileName)`"
            switch problem {
            case .unreadable(let reason?):
                return
                    "HeadsUp couldn't read \(file) (\(reason)), so it left the file as it is. Fix it, then try again."
            case .unreadable(nil):
                return "HeadsUp couldn't read \(file), so it left the file as it is. Fix it, then try again."
            case .newerVersion:
                return "HeadsUp left \(file) as it is, so the newer version keeps them."
            }
        }
        public static let showInFinder = "Show in Finder"
        public static let tryAgain = "Try Again"
        /// Why the file couldn't be read, short and plain, inside the parentheses above.
        public static let notJSON = "it isn't valid JSON"
        public static func missing(_ field: String, item: String, number: Int) -> String {
            "\(item) \(number) has no \(field)"
        }
        public static func wrong(_ field: String, item: String, number: Int) -> String {
            "the \(field) of \(item) \(number) isn't valid"
        }
        public static let notAllowedToRead = "HeadsUp isn't allowed to read it"
        /// What saving and removing return, and the line under the Settings title, while the
        /// file can't be read.
        public static func cantEdit(_ kind: ListFileKind) -> String {
            "You can't change \(kind.plural) until `\(kind.fileName)` can be read."
        }
        /// The form's bottom bar, in --danger, when the file couldn't be written.
        public static func saveFailed(_ reason: String) -> String { "Couldn't save: \(reason)" }
    }

    /// The Commands tab, its terminal picker, its rows' problems and actions (Commands spec;
    /// UX part 1, §1, §3, §4; Yuki's Commands copy).
    public enum Commands {
        public static let tabLabel = "Command shortcuts"
        public static let opensIn = "Opens in"
        /// The row in Settings → General.
        public static let terminalApp = "Terminal app"
        public static let emptyTitle = "No commands yet"
        public static let emptyText =
            "Save commands you type often, like ssh or git rebase. They open in your terminal."
        public static let addCommand = "Add a command…"
        /// The header's button, and the button of a row that can't run.
        public static let edit = "Edit…"

        // A row, for VoiceOver: the name is the label.
        /// "ssh deploy@staging.example.dev, in home folder"
        public static func accessibilityValue(command: String, cwd: String) -> String {
            let folder =
                cwd == "~" || cwd.isEmpty ? "home folder" : cwd.hasPrefix("~/") ? "home folder" + cwd.dropFirst() : cwd
            return "\(command), in \(folder)"
        }
        /// "Opens in iTerm2"
        public static func accessibilityHint(terminal: String) -> String { "Opens in \(terminal)" }

        // Toasts
        public static func opened(_ app: String, _ command: String) -> String { "Opened in \(app) · \(command)" }
        public static func added(_ name: String) -> String { "Added \(name)" }
        public static func saved(_ name: String) -> String { "Saved \(name)" }
        public static func removed(_ name: String) -> String { "Removed \(name)" }

        // Under a row, in --danger, in place of the toast.
        public static func runProblem(_ result: TerminalRunResult, terminal: String) -> String {
            switch result {
            case .opened: ""
            case .notAllowed:
                "macOS didn't let HeadsUp open \(terminal). Allow it in Privacy & Security → Automation."
            case .notInstalled: "\(terminal) isn't on this Mac any more. Choose another terminal in Settings → General."
            case .failed(let reason) where reason.isEmpty: "Couldn't open \(terminal)."
            case .failed(let reason): "Couldn't open \(terminal) (\(reason))."
            }
        }
        /// The run problems' buttons.
        public static let openSystemSettings = "Open System Settings"
        public static let openSettings = "Open Settings"
        public static let tryAgain = "Try Again"
        /// The --warn meta line of a command from commands.json that breaks a rule.
        public static func cantRun(_ problem: String) -> String { "Can't run · \(ListForm.inline(problem))" }

        // Actions
        public static func runAction(_ name: String) -> String { "Run \(name)" }
    }

    /// What the Services and Commands editors share (UX part 1, §1): the field labels, the
    /// bottom bar, and the problems both forms have.
    public enum ListForm {
        public static let name = "Name"
        public static let command = "Command"
        public static let folder = "Folder"
        public static let choose = "Choose…"
        public static let remove = "Remove…"
        public static let cancel = "Cancel"
        public static let save = "Save"
        public static func removeQuestion(_ name: String) -> String { "Remove \(name)?" }
        /// The remove bar's button.
        public static let removeConfirm = "Remove"
        public static let discardQuestion = "Discard your changes?"
        public static let keepEditing = "Keep editing"
        public static let discard = "Discard"

        // Problems, under their field
        public static let nameEmpty = "Enter a name."
        public static let nameTooLong = "Use 64 characters or fewer."
        public static let commandProblem = "Enter a command to run."
        public static let folderMissing = "This folder doesn't exist."
        /// A NUL character, which only a hand-edited file can have.
        public static let nulProblem = "This has a hidden character that can't be used. Type it again."

        /// A form's problem note as a row's reason, in lower case and without its full stop:
        /// "enter a command to run".
        static func inline(_ problem: String) -> String {
            var reason = problem.hasSuffix(".") ? String(problem.dropLast()) : problem
            if let first = reason.first { reason = first.lowercased() + reason.dropFirst() }
            return reason
        }
    }

    /// The command form in Settings → Commands (UX part 1, §1; Yuki's Commands copy).
    public enum CommandForm {
        public static let newTitle = "New command"
        public static let back = "Commands"
        public static let namePlaceholder = "SSH into staging"
        public static let commandPlaceholder = "ssh deploy@staging.example.dev"
        public static let add = "Add command"
        public static let intro = "Commands you type often. HeadsUp opens each one in your terminal, in its folder."
        public static let empty = "No commands yet. Add one to open it in your terminal."
    }

    /// The service form in Settings → Services (UX part 1, §1; addenda 3–4).
    public enum ServiceForm {
        public static let newTitle = "New service"
        public static let back = "Services"
        public static let namePlaceholder = "Web dev server"
        public static let commandPlaceholder = "npm run dev"
        public static let commandHelp =
            "Runs in your login shell, like in Terminal. If your shell is fish or nushell, it runs in zsh."
        public static let environment = "Environment"
        public static let noVariables = "No variables"
        /// F11: the warning, then the hint, on two lines.
        public static let environmentWarning = "Stored in a plain file. Don't put secrets here."
        public static let environmentHint =
            "To use a secret, run the command through a secrets tool, e.g. `op run -- npm run dev`."
        public static let port = "Port"
        public static let portHelp = "Leave empty to detect it after start."
        public static let autostart = "Start with HeadsUp"
        public static let autostartHelp = "Starts this service when HeadsUp opens."
        public static let runningNote = "Changes apply the next time it starts."
        public static let add = "Add service"
        public static let intro = "Long-running commands you start and stop from the HUD."
        public static let empty = "No services yet. Add one to start and stop it from the HUD."
        public static func removeRunning(_ name: String) -> String { "\(name) is running. Removing it stops it." }
        // The environment table, for VoiceOver and as placeholders.
        public static let variableName = "Variable name"
        public static func variableValue(_ key: String) -> String { "Value of \(key)" }
        public static let removeVariable = "Remove variable"
        public static let addVariable = "Add variable"
        public static let keyPlaceholder = "NAME"
        public static let valuePlaceholder = "value"
    }

    /// Settings → Models (Model endpoints spec; UX part 1, §2; addendum 3, F7 and F9). Copy
    /// marked "placeholder" waits for Yuki.
    public enum Models {
        public static let title = "Model endpoints"
        public static let intro = "Any OpenAI-compatible URL. Switch from the HUD with “/model”."
        public static let emptyCard = "Add an OpenAI-compatible URL below. Ollama and LM Studio run on this Mac."
        public static func quickAdd(_ kind: QuickAddKind) -> String {
            switch kind {
            case .openAI: "OpenAI"
            case .ollama: "Ollama"
            case .lmStudio: "LM Studio"
            case .other: "Other"
            }
        }
        public static let runningOnThisMac = "Running on this Mac"
        /// The provider tag in Settings, and its tooltip.
        public static func tag(_ tag: ProviderTag) -> String {
            switch tag {
            case .ollama: "Ollama"
            case .lmStudio: "LM Studio"
            case .local: "Local"
            case .custom: "Custom"
            }
        }
        public static let localTag = "Local"
        public static let localTagHelp = "Runs on this Mac"
        public static let noToken = "no token"
        /// The ×'s tooltip, with a saved token, and without.
        public static let removeHelp = "Remove (the token is deleted from the Keychain)"
        public static let removeHelpNoToken = "Remove"
        /// The row's question before removing an endpoint with a saved token.
        public static func removeQuestion(_ name: String) -> String {
            "Remove \(name)? Its token is deleted from the Keychain."
        }
        public static let cancel = "Cancel"
        public static let remove = "Remove"
        /// The radio, for VoiceOver; the value is the row's name.
        public static let defaultModel = "Default model"
        /// "https://api.openai.com/v1 · gpt-4o-mini"
        public static func urlLine(_ url: String, model: String) -> String { "\(url) · \(model)" }

        // Toasts
        public static func added(_ name: String) -> String { "Added \(name)" }
        public static func saved(_ name: String) -> String { "Saved \(name)" }
        public static func removed(_ name: String) -> String { "Removed \(name)" }
        public static func active(_ name: String) -> String { "Model: \(name)" }

        // Actions
        public static func switchAction(_ name: String) -> String { "Switch model to \(name)" }
        /// "Ollama · llama3.1:8b"
        public static func detail(provider: String, model: String) -> String { "\(provider) · \(model)" }
    }

    /// The endpoint form in Settings → Models (UX part 1, §2; addendum 3).
    public enum EndpointForm {
        public static let addLabel = "Add endpoint"
        public static func editLabel(_ name: String) -> String { "Edit \(name)" }
        public static let name = "Name"
        public static let modelID = "Model id"
        public static let baseURL = "Base URL"
        public static let baseURLPlaceholder = "https://api.example.com/v1"
        public static let token = "API token"
        public static let tokenPlaceholder = "API token (stored in Keychain)"
        public static func tokenSavedPlaceholder(_ mask: String) -> String {
            "Saved in Keychain (\(mask)). Type to replace."
        }
        public static let tokenHelp = "Optional. Local servers usually don't need one."
        public static let tokenNeedsHTTPS = "Use https to add a token."
        public static let removeToken = "Remove token"
        public static let images = "Can see images"
        public static let tools = "Can use tools"
        public static let optionsHelp = "Turn off if the model doesn't support it."
        public static let service = "Service"
        public static let serviceNone = "None"
        public static let test = "Test connection"
        public static let add = "Add endpoint"
        public static let save = "Save"
        public static let cancel = "Cancel"
        public static let setDefault = "Set as default"
        public static let details = "Details"

        // Notes under Base URL (F9)
        public static let urlNotValid = "Enter a full URL, like https://api.example.com/v1"
        public static let notEncrypted = "Not encrypted: anyone on this network can read your chats."
        public static let needsHTTPS = "Use https:// for servers outside your Mac and your network."

        // The token-host question (F7)
        public static func tokenHostQuestion(_ host: String) -> String { "Send your saved token to \(host)?" }
        public static let keepToken = "Keep token"

        // Test connection results
        public static let testing = "Testing…"
        public static func ok(model: String, seconds: Double) -> String {
            "Connected · \(model) answered in \(String(format: "%.1f", seconds)) s"
        }
        public static let chooseModel = "Connected. Choose a model:"
        public static func modelNotOnServer(_ model: String) -> String {
            "Connected, but “\(model)” isn't on this server."
        }
        public static let needsToken = "The server needs an API token."
        public static func badToken(status: Int) -> String { "The server rejected the token (\(status))." }
        public static func unreachable(_ hostPort: String) -> String { "Can't reach \(hostPort)." }
        public static func start(_ service: String) -> String { "Start \(service)" }
        public static func starting(_ service: String) -> String { "Starting \(service)…" }
        public static func startTimedOut(_ service: String) -> String {
            "\(service) didn't start. Check its log in Services."
        }
        public static let openServices = "Open Services"
        /// `withToken`: a saved or typed token was sent with the request.
        public static func redirected(_ host: String, withToken: Bool) -> String {
            withToken
                ? "The server redirected to \(host). HeadsUp doesn't follow redirects, so your token isn't sent there. Check the URL."
                : "The server redirected to \(host). HeadsUp doesn't follow redirects. Check the URL."
        }
        /// The keychain refused to give the saved token.
        public static let keychainDenied = "Your keychain didn't let HeadsUp read the token."
        public static let tryAgain = "Try Again"
        /// The first, empty choice of the model popup.
        public static let chooseModelPrompt = "Choose a model"
        public static func serverError(status: Int) -> String { "The server answered with an error (\(status))." }
        /// Under the API token field, when the keychain wouldn't save the token.
        public static let keychainFailed =
            "Couldn't save the token in your keychain, so the endpoint isn't saved. Try again."
        /// Under the API token field, or under the list after removing an endpoint, when the
        /// keychain kept the token.
        public static let removeFailed =
            "Couldn't delete the token from your keychain. Try again, or search for HeadsUp in Keychain Access to delete it."
        /// Under the token field after Remove token, in --ink-2, with Keep Token.
        public static let tokenRemovalNote = "The saved token is deleted when you save."
        public static let keepSavedToken = "Keep Token"
    }

    /// The model menu and its chip (Model endpoints spec; UX part 1, §2).
    public enum ModelMenu {
        public static let label = "Model"
        public static let manage = "Manage endpoints…"
        public static let empty = "No models yet. Add an OpenAI-compatible URL, local or in the cloud."
        public static let notRunning = "not running"
        public static let start = "Start"
        public static let noModel = "No model"
        public static func chipLabel(_ name: String) -> String { "Model: \(name)" }
    }

    /// The conversation (Chat spec; UX part 1, §4, §5, §8; addenda 3–4). Copy marked
    /// "placeholder" waits for Yuki.
    /// The local tools: Settings → Tools, tool rows and approval cards (Local tools spec; Chat
    /// spec; UX addendum 3).
    public enum Tools {
        // Settings → Tools
        public static let title = "Local tools"
        public static let intro = "What the model may access on this Mac. “Ask” shows an approval card in the chat."
        public static func label(_ tool: ToolID) -> String {
            switch tool {
            case .calendar: "Calendar"
            case .remindersRead: "Reminders"
            case .remindersCreate: "Add reminders"
            case .clipboard: "Clipboard"
            }
        }
        public static func description(_ tool: ToolID) -> String {
            switch tool {
            case .calendar: "Read events"
            case .remindersRead: "Read your reminders"
            case .remindersCreate: "Create new reminders"
            case .clipboard: "Read the current clipboard"
            }
        }
        public static func permission(_ permission: ToolPermission) -> String {
            switch permission {
            case .allow: "Allow"
            case .ask: "Ask"
            case .off: "Off"
            }
        }
        public static let alwaysAsks = "Always asks before adding."

        // Tool rows (Chat spec; addendum 3, F3 and F10)
        public static let allowedByRule = "Allowed by rule"
        public static let approvedOnce = "Approved once"
        public static let alwaysAllowed = "Always allowed · saved to Settings"
        public static let denied = "Denied"
        public static let disabled = "Disabled in Settings"
        public static let blocked = "Blocked by macOS"
        public static let openSystemSettings = "Open System Settings"
        public static let concealed = "Not shared · the clipboard holds a password"
        public static func failed(_ reason: String) -> String { "Failed · \(reason)" }
        public static let running = "Running…"
        public static let waiting = "Waiting for you"
        public static let notAvailable = "Not available"
        /// VoiceOver reads the whole row: "Calendar, calendar.events, Oct 25 – Oct 31, 2.1 KB, Allowed by rule".
        public static func rowLabel(_ parts: [String?]) -> String { parts.compactMap { $0 }.joined(separator: ", ") }

        // Cards (Chat spec; addendum 3, F3 and F4)
        public static func cardTitle(_ model: String, _ tool: ToolID) -> String {
            switch tool {
            case .calendar: "\(model) wants to read your calendar"
            case .remindersRead: "\(model) wants to read your reminders"
            case .remindersCreate: "\(model) wants to add a reminder"
            case .clipboard: "\(model) wants to read your clipboard"
            }
        }
        public static func notAllowlisted(_ tool: ToolID) -> String {
            "\(label(tool)) isn’t on your allowlist. Nothing is shared until you approve."
        }
        public static let nothingAdded = "Nothing is added until you allow it."
        public static let sharedList = "People who share this list will see it."
        public static let deny = "Deny"
        public static let allowOnce = "Allow once"
        public static let alwaysAllow = "Always allow"
        public static let reminderField = "Reminder"
        public static let dueField = "Due"
        public static let listField = "List"
        public static let noDueDate = "No due date"
        /// "Reminders (default list)"
        public static func defaultList(_ name: String) -> String { "\(name) (default list)" }
        /// A synced list whose account has no name.
        public static let syncedList = "Synced list"
        public static let allLists = "All lists"
        /// Why a reminder list call didn't happen: "no list named “Secret”".
        public static func noSuchList(_ name: String) -> String { "no list named “\(name)”" }
        public static let noLists = "you don't have a reminders list"
        /// "Not added · no list named “Secret”": a reminder that couldn't be added as asked.
        public static func notAdded(_ reason: String) -> String { "Not added · \(reason)" }
        /// VoiceOver, when a card appears: the title, then what to do (Yuki).
        public static func cardAnnouncement(_ title: String) -> String { "\(title). Allow or deny." }
        /// The Reminder field's fold past 3 lines.
        public static let showAll = "Show all"
        public static let showLess = "Show less"
        /// "Oct 1 – Oct 31 · first 31 days": a calendar read cut to the limit (F10a).
        public static func cutTo31Days(_ range: String) -> String { "\(range) · first 31 days" }
        public static let noReminderList = "there is no reminders list"

        /// The row's summary of what the clipboard held: "1,284 characters", "Image · 1280 × 720".
        public static func clipboardSummary(_ contents: ClipboardContents) -> String {
            switch contents {
            case .empty: "Empty"
            case .concealed: "Password"
            case .text(let text): "\(Format.count(text.count)) characters"
            case .image(let width, let height): "Image · \(width) × \(height)"
            case .files(let names): names.count == 1 ? "1 file" : "\(names.count) files"
            }
        }

        /// The clipboard card's preview (F3): the type and size, then the first 8 characters and
        /// the rest of the first 40 masked; file names only; nothing of an image.
        public static func clipboardPreview(_ contents: ClipboardContents) -> String {
            switch contents {
            case .text(let text):
                let clean = sanitizeForDisplay(text, max: 0)
                let shown = String(clean.prefix(8))
                let masked = String(repeating: "•", count: max(0, min(clean.count, 40) - shown.count))
                return "Text · \(Format.count(text.count)) characters\n\(shown)\(masked)\(clean.count > 40 ? "…" : "")"
            case .files(let names):
                let list = names.prefix(5).map { sanitizeForDisplay($0, max: 60) }.joined(separator: ", ")
                return "\(clipboardSummary(contents)) · \(list)\(names.count > 5 ? ", …" : "")"
            default:
                return clipboardSummary(contents)
            }
        }

        // What the model is told when a tool didn't run (inside the envelope).
        static let modelDenied = "The user denied this tool call. Nothing was read or changed."
        static let modelDisabled = "This tool is turned off in HeadsUp's settings. Nothing was read."
        static let modelUnknown = "HeadsUp has no tool by this name."
        static let modelConcealed = "The clipboard holds a password-manager item, so nothing was shared."
        static func modelBlocked(_ permission: MacPermission) -> String {
            let pane = permission == .calendar ? "Calendars" : "Reminders"
            return
                "macOS hasn't given HeadsUp access. The user can allow it in System Settings → Privacy & Security → \(pane)."
        }
        static func modelInvalid(_ reason: String) -> String { "The arguments were not valid: \(reason)." }
        static func modelFailed(_ reason: String) -> String { "The tool failed: \(reason)." }
        public static let allDay = "All day"
    }

    /// Images attached to the next message (Chat spec, Images; UX part 1, §6–7; addendum 4).
    public enum Attachments {
        /// The name of an image pasted as data, without a file name.
        public static let pastedName = "Pasted image"
        /// A sent image, above its message: "Image", or "Image 2 of 3".
        public static func sentName(_ number: Int, of count: Int) -> String {
            count == 1 ? "Image" : "Image \(number) of \(count)"
        }
        public static func label(_ name: String) -> String { "Image \(name)" }
        /// VoiceOver for a thumbnail the model can't see: "Screenshot 1.png, can't be seen by Llama 3.1 8B".
        public static func unseenLabel(_ name: String, model: String) -> String { "\(name), can't be seen by \(model)" }
        /// Refused before decoding (Scan L1; Yuki, msg-838). When others in the batch were added,
        /// the advice to try smaller copies is left out.
        public static func tooLarge(_ count: Int, someAdded: Bool) -> String {
            if someAdded {
                return count == 1
                    ? "1 image wasn't attached because it's too big."
                    : "\(count) images weren't attached because they're too big."
            }
            return count == 1
                ? "This image is too big to attach. Try a smaller copy or a screenshot of it."
                : "\(count) images are too big to attach. Try smaller copies."
        }
        /// "Remove image Screenshot 1"
        public static func remove(_ name: String) -> String { "Remove image \(name)" }
        // The header buttons (UX part 2, labels for icon-only buttons)
        public static let pinnedChats = "Pinned chats"
        public static let attach = "Attach image"
        public static let attachHelp = "Attach images"
        // The vision notice (UX part 1, §6)
        public static func cantSee(_ model: String) -> String { "\(model) can't see images." }
        public static func switchTo(_ model: String) -> String { "Switch to \(model)" }
        public static let removeImage = "Remove image"
        public static let removeImages = "Remove images"
        public static let noModelSees = "None of your models can see images."
        public static let addModel = "Add a model to send images."
        public static let openSettings = "Open Settings"
        // The limit of 5 (addendum 4)
        /// "You can send up to 5 images at a time. 1 image wasn't added."
        public static func tooMany(notAdded: Int) -> String {
            let count = notAdded == 1 ? "1 image wasn't added." : "\(notAdded) images weren't added."
            return "You can send up to 5 images at a time. " + count
        }
        public static let limitReached = "You can send up to 5 images at a time."
        public static let close = "Close"
        // The drop zone (UX part 1, §7; addendum 4)
        public static let dropToAttach = "Drop to attach"
        /// "Drop to attach 3 of 7 images (up to 5 per message)"
        public static func dropSome(_ count: Int, of total: Int) -> String {
            "Drop to attach \(count) of \(total) images (up to 5 per message)"
        }
        public static let onlyImages = "Only images can be attached"
        public static let onlyTheImages = "Only the images will be attached"
    }

    public enum Chat {
        // The toolbar
        public static let new = "New"
        public static let newHelp = "New chat (⌘N)"
        public static let stop = "Stop"
        // Whether the chat is kept (Chat spec, the toolbar; Pinned chats spec)
        public static let notSaved = "Not saved · cleared on ⌘N or quit"
        public static let pinnedKept = "Pinned · kept until you unpin it"
        public static func pinnedList(_ count: Int) -> String { "Pinned · \(count)" }
        public static let pin = "Pin"
        public static let pinned = "Pinned"
        public static let pinHelp = "Pin this chat (⌘P)"
        public static let unpinHelp = "Unpin this chat (⌘P)"
        public static let chatPinned = "Chat pinned"
        public static let chatUnpinned = "Unpinned. This chat is ephemeral again"
        // When saving fails (Pinned chats spec): the reason in plain words, or no parentheses.
        public static func pinFailed(_ reason: String?) -> String { "Couldn't pin this chat\(because(reason))." }
        public static func saveFailed(_ reason: String?) -> String {
            "Pinned, but the latest messages aren't saved\(because(reason))."
        }
        public static func unpinFailed(_ reason: String?) -> String { "Couldn't unpin this chat\(because(reason))." }
        public static func pinnedListFailed(_ reason: String?) -> String {
            "Couldn't read your pinned chats\(because(reason))."
        }
        private static func because(_ reason: String?) -> String { reason.map { " (\($0))" } ?? "" }
        public static let tryAgainTitle = "Try Again"
        public static let newChatSubtitle = "clear the current conversation"
        public static func openFailed(_ reason: String?) -> String { "Couldn't open this chat\(because(reason))." }
        /// A pinned chat's title when its first message has only images.
        public static let imageConversation = "Image conversation"
        // The Pinned list
        public static let pinnedChats = "Pinned chats"
        public static let backToChat = "Back to chat"
        public static let nothingPinned =
            "Nothing pinned. Chats disappear when you start a new one unless you pin them."
        /// "4 messages · GPT-4o mini"
        public static func pinnedMeta(messages: Int, model: String) -> String {
            "\(messages) \(messages == 1 ? "message" : "messages") · \(model)"
        }
        public static func unpin(_ title: String) -> String { "Unpin \(title)" }
        /// "Weekly plan, 4 messages, GPT-4o mini, Yesterday"
        public static func pinnedRowLabel(title: String, meta: String, date: String) -> String {
            "\(title), \(meta.replacingOccurrences(of: " · ", with: ", ")), \(date)"
        }
        /// "Just now", "12 min ago", "5 h ago", "Yesterday", then the short local date: "Oct 21".
        public static func pinnedDate(
            _ date: Date, now: Date, locale: Locale = .current, timeZone: TimeZone = .current
        ) -> String {
            let text = Services.ago(date, now: now, locale: locale, timeZone: timeZone)
            return text.prefix(1).uppercased() + text.dropFirst()
        }
        /// The "Pinned chats" action's subtitle.
        public static func pinnedSaved(_ count: Int) -> String { "\(count) saved" }
        /// VoiceOver for a message with images: "You: what's wrong here?, 2 images".
        public static func youSaid(_ text: String, images: Int) -> String {
            guard images > 0 else { return youSaid(text) }
            let count = images == 1 ? "1 image" : "\(images) images"
            return text.isEmpty ? "You: \(count)" : "You: \(text), \(count)"
        }
        /// What an older image becomes in what is sent: only the newest message's images go.
        static let imageOmitted = "[image omitted]"

        // A reply
        public static func thinking(_ model: String) -> String { "Thinking with \(model)…" }
        public static let stopped = "Stopped"
        // VoiceOver (Yuki's chat copy)
        public static func youSaid(_ text: String) -> String { "You: \(text)" }
        /// "GPT-4o mini: …", the blocks read in order; ", stopped" after Stop.
        public static func modelSaid(_ model: String, blocks: [String], stopped: Bool) -> String {
            "\(model): " + blocks.joined(separator: " ") + (stopped ? ", stopped" : "")
        }
        public static func codeBlockSpoken(language: String?) -> String {
            language.map { "Code block, \($0):" } ?? "Code block:"
        }
        public static func tableSpoken(columns: Int, rows: Int) -> String { "Table, \(columns) columns, \(rows) rows" }
        public static func linkSpoken(_ host: String) -> String { "link, \(host)" }
        public static func replyStarted(_ model: String) -> String { "\(model) is answering" }
        public static func replyEnded(_ model: String) -> String { "\(model) answered" }
        public static let replyStopped = "Reply stopped"
        public static let code = "code"
        public static let copy = "Copy"
        public static let copyAsMarkdown = "Copy as Markdown"
        public static let copied = "Copied to clipboard"

        // The link ask (addendum 3, F2)
        public static let openLinkQuestion = "Open this link?"
        public static let cancel = "Cancel"
        public static let open = "Open"

        // Problem rows (UX part 1, §4)
        public static let tryAgain = "Try again"
        public static let editEndpoint = "Edit endpoint…"
        public static let openSettings = "Open Settings"
        public static let newChat = "New chat"
        public static let switchModel = "Switch model"
        public static func start(_ service: String) -> String { "Start \(service)" }
        public static func starting(_ service: String) -> String { "Starting \(service)…" }
        public static let theModel = "The model"
        public static let offlineTitle = "Can't connect to the internet"
        public static let offlineText = "Check your connection, then try again."
        public static func unreachableTitle(_ host: String) -> String { "Can't reach \(host)" }
        public static let unreachableText = "The server didn't answer."
        public static func timeoutTitle(_ model: String) -> String { "\(model) took too long to answer" }
        public static func tokenTitle(_ model: String) -> String { "\(model) rejected the API token" }
        public static let badTokenText = "The token may be wrong or expired."
        public static let needsTokenText = "This server needs an API token."
        public static func busyTitle(_ model: String) -> String { "\(model) is busy" }
        public static func busyText(seconds: Int?) -> String {
            seconds.map { "Too many requests. You can try again in \($0) s." } ?? "Too many requests."
        }
        public static func notRunningTitle(_ server: String) -> String { "\(server) isn't running" }
        public static let notRunningText = "Start it, then try again."
        public static func modelMissingTitle(_ id: String) -> String { "\(id) isn't on this server" }
        public static let modelMissingText = "Choose another model id."
        public static func tooLongTitle(_ model: String) -> String { "This chat is too long for \(model)" }
        public static let tooLongText = "Start a new chat, or switch to a model that takes longer chats."
        public static func redirectedTitle(_ model: String, host: String) -> String {
            "\(model)'s server redirected to \(host)"
        }
        public static let redirectedText =
            "HeadsUp doesn't follow redirects, so your token isn't sent there. Check the URL."
        public static func serverTitle(_ model: String, status: Int) -> String {
            "\(model) returned an error (\(status))"
        }
        public static func badResponseTitle(_ model: String) -> String { "\(model) sent a reply HeadsUp can't read" }
        public static let badResponseText = "The server may not be fully OpenAI-compatible."
        public static let keychainDeniedTitle = "Your keychain didn't let HeadsUp read the token"
        public static let keychainDeniedText = "If macOS asks, allow HeadsUp, then try again."
        public static let noModelTitle = "No model is set up"
        public static let noModelText = "Add an OpenAI-compatible URL in Settings → Models, then try again."
        /// The disclosure with the server's own message.
        public static let details = "Details"

        // The step limit (addendum 4)
        public static func stepLimitTitle(_ model: String, steps: Int) -> String {
            "\(model) stopped after \(steps) tool calls"
        }
        public static let stepLimitText = "It may need more steps to finish."
        public static let continueTitle = "Continue"
        public static func stepLimitRecord(steps: Int) -> String { "Stopped after \(steps) tool calls · Continued" }
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
