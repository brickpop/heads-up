import AppKit
import HeadsUpCore
import os

/// Builds the app at launch: the model with the real ports, the HUD panel, the HUD's keys.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "HeadsUp", category: "app")
    private let hotkeys = CarbonHotkeyRegistrar()
    private var model: AppModel?
    private var panel: HUDPanel?
    private var statusItem: StatusItemController?
    private var keyLabeler: KeyLabeler?
    private var notifier: UserNotifier?
    private var wakeObserver: NSObjectProtocol?
    private var clockObserver: NSObjectProtocol?
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()

        let scheduler = SystemScheduler()
        // Answers from Notification Center go to the model, once it exists.
        let notifier = UserNotifier { [weak self] category, action in
            self?.model?.handleNotification(category: category, action: action)
        }
        let model = AppModel(
            ports: AppModel.Ports(
                clock: SystemClock(), scheduler: scheduler, hotkeys: hotkeys,
                appearance: SystemAppearanceAdapter(), files: FinderRevealer(), loginItem: LoginItemAdapter(),
                systemSettings: SystemSettingsAdapter(), notifier: notifier,
                dataFolder: SettingsStore.dataFolder(quickTimers: Self.quickTimers),
                focusSecondsPerMinute: Self.focusSecondsPerMinute))
        self.model = model
        self.notifier = notifier

        // After sleep, or when the system clock changes, timers that ended meanwhile move on at
        // once (ADR-001 §4.3).
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak model] _ in
            MainActor.assumeIsolated { model?.clockJumped() }
        }
        clockObserver = NotificationCenter.default.addObserver(
            forName: .NSSystemClockDidChange, object: nil, queue: .main
        ) { [weak model] _ in
            MainActor.assumeIsolated { model?.clockJumped() }
        }

        let panel = HUDPanel(hud: model.hud, content: HUDRootView(model: model))
        model.hud.attach(window: panel)
        self.panel = panel
        statusItem = StatusItemController(model: model, scheduler: scheduler)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, panel.isKeyWindow else { return event }
            return self.handleKey(event, hud: model.hud, panel: panel) ? nil : event
        }

        observe(
            { model.settings.settings.general.appearance },
            apply: { appearance in
                NSApp.appearance =
                    switch appearance {
                    case .system: nil
                    case .light: NSAppearance(named: .aqua)
                    case .dark: NSAppearance(named: .darkAqua)
                    }
            })

        if let problem = model.settings.fileProblem {
            log.error(
                "settings: \(String(describing: problem), privacy: .public): \(model.settings.lastErrorDetail ?? "", privacy: .public)"
            )
        }
        model.launch()
        #if DEBUG && HEADSUP_QUICK_TIMERS
            log.notice("HeadsUp quick timers: one timer minute lasts 5 seconds")
        #endif
        let keyLabeler = KeyLabeler { [weak self, weak model] in
            guard let model, let labeler = self?.keyLabeler else { return }
            model.hud.shortcutLabelChanged(labeler.label(for: model.settings.settings.general.shortcut.keyCode))
        }
        self.keyLabeler = keyLabeler
        model.hud.shortcutLabelChanged(keyLabeler.label(for: model.settings.settings.general.shortcut.keyCode))
        switch model.hud.hotkey {
        case .ok(let shortcut): log.info("wake shortcut registered: \(shortcut.displayName, privacy: .public)")
        case .taken: log.error("wake shortcut not registered: another app uses it")
        case .reservedBySystem: log.error("wake shortcut not registered: macOS uses it")
        case .failed(let status): log.error("wake shortcut not registered: OSStatus \(status, privacy: .public)")
        }
    }

    #if DEBUG && HEADSUP_QUICK_TIMERS
        /// `just app-quick`: one timer minute lasts 5 seconds, so the CEO can check a whole Focus round
        /// in minutes. A release build can't contain this: the lint and make-app.sh check it.
        /// It also keeps its own data folder, HeadsUp-Quick, so it never touches the real data.
        private static let quickTimers = true
        private static let focusSecondsPerMinute: TimeInterval = 5
    #else
        private static let quickTimers = false
        private static let focusSecondsPerMinute: TimeInterval = 60
    #endif

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys.invalidate()
    }

    /// The HUD's own keys while it is key: all keys while the shortcut recorder listens,
    /// else ⌘ shortcuts, ↑ ↓ for the suggestions, Esc.
    /// Returns false for keys it leaves to the text field. Return stays with the field
    /// (`onSubmit`), and while an input method is composing text (Japanese, Chinese…)
    /// ↑ ↓ and Esc belong to its candidate window.
    private func handleKey(_ event: NSEvent, hud: HUDStore, panel: NSPanel) -> Bool {
        let shortcut = Self.shortcut(for: event)
        if hud.recording {
            // The shortcut recorder takes every key (amendment 5): Esc cancels, anything else is
            // recorded with the label the current layout gives it.
            if shortcut.keyCode == KeyNames.escape && shortcut.modifiers.isEmpty {
                hud.cancelRecording()
            } else {
                let label = keyLabeler?.label(for: shortcut.keyCode) ?? shortcut.key
                hud.record(Shortcut(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, key: label))
            }
            return true
        }
        if !shortcut.modifiers.isEmpty {
            return hud.handleShortcut(shortcut)
        }
        if let editor = panel.firstResponder as? NSTextView, editor.hasMarkedText() {
            return false
        }
        switch Int(event.keyCode) {
        case Key.upArrow where hud.arrowKeysMoveSelection:
            hud.moveSelection(-1)
        case Key.downArrow where hud.arrowKeysMoveSelection:
            hud.moveSelection(1)
        case Key.escape:
            hud.escape()
        default:
            return false
        }
        return true
    }

    /// Virtual key codes (Carbon's kVK_ values) for the keys the monitor handles.
    private enum Key {
        static let escape = 53
        static let downArrow = 125
        static let upArrow = 126
    }

    /// The key and modifiers of a key press, as the core's `Shortcut`.
    private static func shortcut(for event: NSEvent) -> Shortcut {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: Shortcut.Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return Shortcut(
            keyCode: UInt32(event.keyCode), modifiers: modifiers,
            key: event.charactersIgnoringModifiers?.uppercased() ?? "")
    }
}
