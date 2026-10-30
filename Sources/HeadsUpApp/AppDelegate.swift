import AppKit
import HeadsUpCore
import os

/// Builds the app at launch: the model with the real ports, the HUD panel, the HUD's keys.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "HeadsUp", category: "app")
    private let hotkeys = CarbonHotkeyRegistrar()
    private let powerAssertions = IOKitPowerAssertions()
    private var model: AppModel?
    private var panel: HUDPanel?
    private var statusItem: StatusItemController?
    private var keyLabeler: KeyLabeler?
    private var notifier: UserNotifier?
    private var wakeObserver: NSObjectProtocol?
    private var clockObserver: NSObjectProtocol?
    private var powerOffObserver: NSObjectProtocol?
    /// Logout, restart or shutdown: services stop without the quit question (UX part 1, §10).
    private var poweringOff = false
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()

        let scheduler = SystemScheduler()
        // The HUD gets out of the way of macOS permission prompts, once it exists.
        let prompts = PermissionPrompts()
        // Answers from Notification Center go to the model, once it exists.
        let notifier = UserNotifier(prompts: prompts) { [weak self] category, action, requestID in
            self?.model?.handleNotification(category: category, action: action, requestID: requestID)
        }
        let eventKit = EventKitTools(prompts: prompts)
        let model = AppModel(
            ports: AppModel.Ports(
                clock: SystemClock(), scheduler: scheduler, hotkeys: hotkeys,
                appearance: SystemAppearanceAdapter(), files: FinderRevealer(), loginItem: LoginItemAdapter(),
                systemSettings: SystemSettingsAdapter(), notifier: notifier,
                powerAssertions: powerAssertions, powerSource: IOKitPowerSource(),
                serviceLauncher: POSIXServiceLauncher(), portProbe: SystemPortProbe(),
                openPanels: OpenPanelsAdapter(), imageProcessor: ImageIOProcessor(), calendar: eventKit,
                reminders: eventKit,
                terminalLauncher: SystemTerminalLauncher(prompts: prompts),
                secrets: KeychainSecretStore(), httpClient: URLSessionHTTPClient(),
                linkOpener: WorkspaceLinkOpener(), pasteboard: GeneralPasteboard(),
                dataFolder: SettingsStore.dataFolder(quickTimers: Self.quickTimers),
                focusSecondsPerMinute: Self.focusSecondsPerMinute, readsShellEnvironment: true))
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
        prompts.panel = panel
        // VoiceOver users keep the HUD after a Focus start, until Esc.
        model.focus.isVoiceOverOn = { NSWorkspace.shared.isVoiceOverEnabled }
        self.panel = panel
        statusItem = StatusItemController(model: model, scheduler: scheduler)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, panel.isKeyWindow else { return event }
            return self.handleKey(event, model: model, panel: panel) ? nil : event
        }

        track(
            { model.settings.settings.general.appearance },
            apply: { appearance in
                // Every window, the HUD and its material included, follows the app's appearance.
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
        if model.services.isolationWarning {
            log.error("responsibility disclaim unavailable; service inherits HeadsUp's permissions")
        }
        powerOffObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.poweringOff = true }
        }
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

    /// ⌘Q and the menu's Quit: while services run, ask first (UX part 1, §10), then stop them all
    /// (SIGTERM, then SIGKILL after 3 s) before quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, !model.services.liveServices.isEmpty else { return .terminateNow }
        if !poweringOff, let question = model.quitQuestion {
            model.hud.beginModal()
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = question.title
            alert.informativeText = [question.message, question.detail].compactMap { $0 }.joined(separator: "\n")
            alert.addButton(withTitle: question.quit)  // the default: Return
            alert.addButton(withTitle: question.cancel).keyEquivalent = "\u{1b}"  // Esc
            presentInFront(alert)
            let answer = alert.runModal()
            model.hud.endModal()
            guard answer == .alertFirstButtonReturn else { return .terminateCancel }
        }
        Task { @MainActor in
            await model.services.stopAll()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Puts the quit alert in front of every window, with the keyboard, though HeadsUp is an
    /// accessory app that is usually not active (its HUD panel takes keys without activating it).
    /// - The panel is built now (`layout()`), so the level set here isn't replaced when it runs,
    ///   and it doesn't hide while HeadsUp isn't active.
    /// - `NSApp.activate()` asks to become active. Since macOS 14 that is a request, and
    ///   `ignoringOtherApps` is ignored, but the user has just chosen Quit in HeadsUp, so it is
    ///   granted.
    /// - Once `runModal` has shown the alert, it is put at the level above the HUD again, ordered
    ///   in front of everything, and made key, whatever the modal session did first. The task runs
    ///   on the main queue, which the modal run loop serves.
    private func presentInFront(_ alert: NSAlert) {
        alert.layout()
        let window = alert.window
        window.hidesOnDeactivate = false
        window.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
        window.level = HUDPanel.aboveHUD
        NSApp.activate()
        let log = self.log
        Task { @MainActor in
            window.level = HUDPanel.aboveHUD
            // Answered already: nothing to bring back.
            guard window.isVisible else { return }
            window.orderFrontRegardless()
            window.makeKey()
            // What the Mac run checks in Console: whether HeadsUp became active, and the level.
            log.info(
                "quit alert shown: active \(NSApp.isActive, privacy: .public), key \(window.isKeyWindow, privacy: .public), level \(window.level.rawValue, privacy: .public)"
            )
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.willQuit()
        hotkeys.invalidate()
        // Assertions die with the process anyway; releasing them first is tidier.
        _ = powerAssertions.hold([])
    }

    /// The HUD's own keys while it is key: all keys while the shortcut recorder listens,
    /// else ⌘ shortcuts and the Focus tab's ⌥← ⌥→ ⌘↩, ↑ ↓ and Return for the open model menu,
    /// ↑ ↓ for the suggestions, Esc.
    /// Returns false for keys it leaves to the text field. Return stays with the field
    /// (`onSubmit`) unless the model menu is open. While an input method is composing text
    /// (Japanese, Chinese…), ↑ ↓ and Esc belong to its candidate window.
    private func handleKey(_ event: NSEvent, model: AppModel, panel: NSPanel) -> Bool {
        let hud = model.hud
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
        // ⌘V with images on the clipboard attaches them; text paste stays the prompt's own. By
        // the character, as the Edit menu matches it, so it is ⌘V on every layout.
        if shortcut.modifiers == .command, shortcut.key == "V", model.clipboardHasImages {
            return model.pasteImages()
        }
        let editor = panel.firstResponder as? NSTextView
        let composing = editor?.hasMarkedText() == true
        // ⌥← ⌥→, ⌥⇧← ⌥⇧→ and ⌘← ⌘→ move or select within text: the text an input method is
        // composing, or any field with text in it (the prompt, or a Settings field). Only from an
        // empty field do they pick a card, a snooze length or a tab.
        let isHorizontalArrow = shortcut.keyCode == KeyCode.leftArrow || shortcut.keyCode == KeyCode.rightArrow
        let editingText = editor.map { $0.isEditable && !$0.string.isEmpty } ?? false
        let textKeys: [Shortcut.Modifiers] = [.option, [.option, .shift], .command]
        if isHorizontalArrow && textKeys.contains(shortcut.modifiers)
            && (composing || editingText)
        {
            return false
        }
        if !shortcut.modifiers.isEmpty {
            return model.handleShortcut(shortcut)
        }
        if composing { return false }
        switch Int(event.keyCode) {
        // The model menu, while open, takes ↑ ↓ and Return.
        case Key.upArrow where hud.modelMenuOpen:
            model.moveModelMenuSelection(-1)
        case Key.downArrow where hud.modelMenuOpen:
            model.moveModelMenuSelection(1)
        case Key.returnKey where hud.modelMenuOpen, Key.keypadEnter where hud.modelMenuOpen:
            model.chooseModelMenuSelection()
        case Key.upArrow where hud.arrowKeysMoveSelection:
            hud.moveSelection(-1)
        case Key.downArrow where hud.arrowKeysMoveSelection:
            hud.moveSelection(1)
        // On Commands, with the prompt empty, ↑ ↓ pick a command; elsewhere they stay the field's.
        case Key.upArrow:
            return model.moveCommandSelection(by: -1)
        case Key.downArrow:
            return model.moveCommandSelection(by: 1)
        case Key.escape:
            model.escape()
        // Backspace in an empty prompt removes the last image, if there is one.
        case Key.delete where hud.input.isEmpty:
            return model.chat.removeLastAttachment()
        default:
            return false
        }
        return true
    }

    /// Virtual key codes (Carbon's kVK_ values) for the keys the monitor handles.
    private enum Key {
        static let returnKey = 36
        static let keypadEnter = 76
        static let escape = 53
        static let delete = 51
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
