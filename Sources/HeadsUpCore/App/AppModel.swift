import Foundation
import Observation

/// Owns the stores and the ports (ADR-001 §4). The app creates one at launch;
/// views get it from the environment and read the stores through it.
@MainActor
@Observable
public final class AppModel {
    /// The OS services the core uses, implemented by the macOS shell, or by fakes.
    public struct Ports {
        public var clock: Clock
        public var scheduler: Scheduler
        public var hotkeys: HotkeyRegistrar
        public var appearance: SystemAppearance
        public var files: FileRevealer
        public var loginItem: LoginItem
        public var systemSettings: SystemSettingsLinks
        /// Where settings.json lives; nil keeps settings in memory only.
        public var dataFolder: URL?

        public init(
            clock: Clock, scheduler: Scheduler, hotkeys: HotkeyRegistrar, appearance: SystemAppearance,
            files: FileRevealer, loginItem: LoginItem, systemSettings: SystemSettingsLinks, dataFolder: URL?
        ) {
            self.clock = clock
            self.scheduler = scheduler
            self.hotkeys = hotkeys
            self.appearance = appearance
            self.files = files
            self.loginItem = loginItem
            self.systemSettings = systemSettings
            self.dataFolder = dataFolder
        }
    }

    public let settings: SettingsStore
    public let hud: HUDStore
    public let registry: ActionRegistry
    @ObservationIgnored private let clock: Clock

    /// The settings-file problem the notice bar has already shown (or that was dismissed).
    private var noticeSeen: SettingsFileProblem?

    /// The activity dot on each tab. Focus, Caffeine and Services fill it in in their slices;
    /// Chat, Commands and Settings never have one.
    public var tabActivity: [Tab: TabActivity] { [:] }

    /// The title of the notice bar at the top of the HUD body, while there is a settings-file
    /// problem the user hasn't seen yet. It shows on one HUD open: closing the HUD, the ×, or
    /// Open Settings each count as seen. A new problem shows again.
    public var settingsNotice: String? {
        guard let problem = settings.fileProblem, problem != noticeSeen else { return nil }
        // The user chose defaults in Settings just now: there is nothing new to tell.
        if case .defaultsChosen = problem { return nil }
        return Strings.SettingsFile.title(problem)
    }

    public init(ports: Ports, settings initial: Settings = Settings()) {
        let settings = SettingsStore(folder: ports.dataFolder, clock: ports.clock, initial: initial)
        let registry = ActionRegistry()
        let chat = NoChat()
        let hud = HUDStore(
            clock: ports.clock, scheduler: ports.scheduler, registry: registry, settings: settings,
            hotkeys: ports.hotkeys, chat: chat)
        self.settings = settings
        self.registry = registry
        self.hud = hud
        self.clock = ports.clock
        loginItem = ports.loginItem
        systemSettings = ports.systemSettings
        files = ports.files
        openAtLogin = ports.loginItem.status
        settings.attach(toaster: hud, revealer: ports.files)

        registry.add(.model) { [weak hud] in hud.map { ShellActions.addModel(hud: $0, chat: chat) } ?? [] }
        registry.add(.theme) { [weak settings] in
            settings.map { ShellActions.theme(settings: $0, appearance: ports.appearance) } ?? []
        }
        registry.add(.view) { [weak hud] in hud.map { ShellActions.goTo(hud: $0) } ?? [] }

        hud.onEvent = { [weak self] event in
            self?.handle(event)
        }
    }

    private func handle(_ event: HUDEvent) {
        switch event {
        case .closed:
            if settingsNotice != nil { noticeSeen = settings.fileProblem }
            endWelcome()
        case .tabChanged(let tab):
            if tab != .chat { endWelcome() }
            // The user may have changed Open at Login in System Settings meanwhile.
            if tab == .settings { refreshOpenAtLogin() }
        }
    }

    /// Runs once the app has finished launching: registers the wake shortcut, and on the
    /// very first launch opens the HUD with the welcome (UX part 1, §3).
    public func launch() {
        hud.registerHotkey()
        if !settings.settings.general.welcomeDone {
            hud.open(tab: .chat, makeKey: true)
        }
    }

    // MARK: Welcome

    /// The welcome shows in the Chat body on the first launch, until Esc, the shortcut,
    /// another tab or Set up a model. It is shown once, ever.
    public var showsWelcome: Bool {
        !settings.settings.general.welcomeDone && hud.isOpen && hud.tab == .chat
    }

    /// The welcome's first line: the shortcut that actually registered, or how to get one.
    public var welcomeShortcutLine: String {
        if case .ok(let shortcut) = hud.hotkey { return Strings.Welcome.pressShortcut(shortcut.displayName) }
        return Strings.Welcome.pressYourShortcut
    }

    /// The welcome's line before the recorder, or nil while the shortcut works.
    public var welcomeProblemLine: String? {
        Strings.Welcome.problemLine(hud.hotkey, shortcut: settings.settings.general.shortcut)
    }

    /// The welcome's Set up a model: the welcome is done, and Settings → Models opens.
    public func welcomeSetUpModel() {
        endWelcome()
        hud.showSettings(.models)
    }

    private func endWelcome() {
        guard !settings.settings.general.welcomeDone else { return }
        settings.markWelcomeDone()
    }

    // MARK: Open at Login

    @ObservationIgnored private let loginItem: LoginItem
    @ObservationIgnored private let systemSettings: SystemSettingsLinks
    @ObservationIgnored private let files: FileRevealer

    /// Open at Login, as macOS reports it.
    public private(set) var openAtLogin: LoginItemStatus
    /// Why the last change didn't work, in plain words, or nil.
    public private(set) var openAtLoginError: String?
    /// macOS couldn't add HeadsUp the last time the user turned the switch on.
    private var couldNotAddLoginItem = false

    /// The note under the Open at Login row (UX part 2, §12; Yuki for `.unavailable`).
    public var openAtLoginNote: OpenAtLoginNote? {
        if openAtLogin == .requiresApproval { return .needsApproval }
        guard couldNotAddLoginItem else { return nil }
        return Self.isInApplications(loginItem.appLocation) ? .couldNotAdd : .moveToApplications
    }

    /// The Open at Login switch, in General and in the welcome.
    public func setOpenAtLogin(_ enabled: Bool) {
        do {
            try loginItem.setEnabled(enabled)
            openAtLoginError = nil
            if enabled { couldNotAddLoginItem = false }
        } catch {
            // An app macOS can't register gets the note instead of the error.
            if loginItem.status == .unavailable {
                couldNotAddLoginItem = enabled
                openAtLoginError = nil
            } else {
                openAtLoginError = Strings.General.loginCouldNotChange
            }
        }
        openAtLogin = loginItem.status
    }

    /// The note's Show in Finder: reveals HeadsUp.app, so the user can drag it to Applications.
    public func showAppInFinder() {
        files.reveal(loginItem.appLocation)
    }

    /// Whether the app runs from /Applications or ~/Applications.
    static func isInApplications(_ app: URL) -> Bool {
        let folder = app.deletingLastPathComponent().standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        return folder == "/Applications" || folder == home.standardizedFileURL.path
    }

    /// Reads the status again: the user may have changed it in System Settings.
    public func refreshOpenAtLogin() {
        openAtLogin = loginItem.status
    }

    /// The ghost Open Login Items button, shown while approval is needed.
    public func openLoginItemsSettings() {
        systemSettings.openLoginItems()
    }

    /// The ghost Open Keyboard Settings button, shown when macOS uses the shortcut.
    public func openKeyboardShortcutsSettings() {
        systemSettings.openKeyboardShortcuts()
    }

    // MARK: Menu bar

    /// The menu bar menu is open.
    public private(set) var menuOpen = false

    /// What Focus, Caffeine, Services and Pinned chats report to the menu bar. Their slices
    /// (3, 4, 5, 9) point these at their stores; until then they report idle. Tests set them.
    @ObservationIgnored var focusSource: @MainActor () -> FocusSnapshot = { .idle(nextLength: 25) }
    @ObservationIgnored var caffeineSource: @MainActor () -> CaffeineSnapshot = { .off }
    @ObservationIgnored var runningServicesSource: @MainActor () -> Int = { 0 }
    @ObservationIgnored var pinnedChatsSource: @MainActor () -> Int = { 0 }

    var focusSnapshot: FocusSnapshot { focusSource() }
    var caffeineSnapshot: CaffeineSnapshot { caffeineSource() }
    var runningServices: Int { runningServicesSource() }
    var pinnedChats: Int { pinnedChatsSource() }

    /// The menu bar item now. The shell redraws it when this changes, and at `nextChange`.
    public var statusItem: StatusItemModel {
        StatusItemModel(
            focus: focusSnapshot, caffeine: caffeineSnapshot, now: clock.now,
            promptVisible: hud.isOpen && hud.tab == .focus, showSeconds: settings.settings.general.menuSeconds)
    }

    /// The item shows as pressed while the HUD or its menu is open.
    public var statusItemHighlighted: Bool { hud.isOpen || menuOpen }

    /// The menu bar menu's content, built when it opens.
    public var menu: MenuModel {
        MenuModel(
            hotkey: hud.hotkey, focus: focusSnapshot, caffeine: caffeineSnapshot, runningServices: runningServices,
            pinnedChats: pinnedChats, now: clock.now)
    }

    /// A left click on the menu bar item. An orange Focus item leads to the Focus tab
    /// (UX part 2, §14): closed → open on Focus; open elsewhere → Focus; on Focus → close.
    public func statusItemClicked() {
        let warning = statusItem.parts.contains { part in
            if case .timer(_, _, let warning) = part { return warning }
            return false
        }
        guard warning else {
            hud.toggle()
            return
        }
        if hud.isOpen && hud.tab == .focus {
            hud.close()
        } else {
            hud.selectTab(.focus)
        }
    }

    /// The menu is about to open. The HUD stays open behind it.
    public func menuWillOpen() {
        guard !menuOpen else { return }
        menuOpen = true
        hud.beginModal()
    }

    public func menuDidClose() {
        guard menuOpen else { return }
        menuOpen = false
        hud.endModal()
    }

    /// A menu row was chosen.
    public func perform(_ action: MenuAction) {
        switch action {
        case .openHUD:
            hud.open()
        case .focus:
            hud.selectTab(.focus)
        case .toggleCaffeine:
            break  // CaffeineStore (slice 4) toggles with the last-used duration and toasts.
        case .services:
            hud.selectTab(.services)
        case .pinned:
            hud.selectTab(.chat)
            if hud.chatView != .pinned { hud.togglePinnedList() }
        case .settings:
            hud.showSettings(hud.settingsSection)
        }
    }

    /// The notice bar's ×.
    public func dismissSettingsNotice() {
        noticeSeen = settings.fileProblem
    }

    /// The notice bar's Open Settings: Settings → General, where the problem stays explained.
    public func openSettingsFromNotice() {
        dismissSettingsNotice()
        hud.showSettings(.general)
    }

    #if DEBUG
        /// A model with fake ports and settings in memory, for SwiftUI previews and tests.
        /// Put it in the state to show through the stores' methods, e.g. `hud.setInput("/")`.
        /// With `firstLaunch`, it launches as a fresh install: the HUD opens with the welcome.
        public static func preview(
            settings: Settings = Settings(), hotkey: HotkeyStatus? = nil, systemIsDark: Bool = false,
            settingsFileProblem: SettingsFileProblem? = nil, loginItem: LoginItemStatus = .disabled,
            firstLaunch: Bool = false
        ) -> AppModel {
            let clock = ManualClock()
            var settings = settings
            if !firstLaunch { settings.general.welcomeDone = true }
            let model = AppModel(
                ports: Ports(
                    clock: clock, scheduler: ManualScheduler(clock: clock),
                    hotkeys: FakeHotkeyRegistrar(nextStatus: hotkey),
                    appearance: FixedAppearance(isDark: systemIsDark), files: FakeFileRevealer(),
                    loginItem: FakeLoginItem(status: loginItem),
                    systemSettings: FakeSystemSettingsLinks(), dataFolder: nil),
                settings: settings)
            if let settingsFileProblem { model.settings.showProblemForPreview(settingsFileProblem) }
            model.launch()
            return model
        }
    #endif
}

/// What the HUD body shows under the settings-file notice (contract: the body rule lives in
/// the core; the view only switches on it).
public enum HUDBody: Equatable, Sendable {
    /// Rows under the prompt. They come first: typing on any tab shows them.
    case suggestions
    /// The Settings tab.
    case settings
    /// The first-run welcome, on Chat.
    case welcome
    /// Nothing: the HUD collapses to its header and footer.
    case empty
}

extension AppModel {
    /// The body, by precedence: suggestions, then Settings, then the welcome on Chat.
    /// The model menu joins this rule in the chat slice.
    public var body: HUDBody {
        if !hud.suggestions.isEmpty { return .suggestions }
        if hud.tab == .settings { return .settings }
        if hud.tab == .chat && showsWelcome { return .welcome }
        return .empty
    }
}
