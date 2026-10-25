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
        public var notifier: Notifier
        public var powerAssertions: PowerAssertions
        public var powerSource: PowerSource
        public var serviceLauncher: ServiceLauncher
        public var portProbe: PortProbe
        public var folderPicker: FolderPicker
        /// The user's login shell, home folder and environment, for services.
        public var loginShell: String
        public var home: String
        public var environment: [String: String]
        /// Where settings.json lives; nil keeps settings in memory only.
        public var dataFolder: URL?
        /// How long a timer minute lasts: 60 s, except in a debug build made with `just app-quick`.
        public var focusSecondsPerMinute: TimeInterval

        public init(
            clock: Clock, scheduler: Scheduler, hotkeys: HotkeyRegistrar, appearance: SystemAppearance,
            files: FileRevealer, loginItem: LoginItem, systemSettings: SystemSettingsLinks, notifier: Notifier,
            powerAssertions: PowerAssertions, powerSource: PowerSource, serviceLauncher: ServiceLauncher,
            portProbe: PortProbe, folderPicker: FolderPicker, dataFolder: URL?,
            focusSecondsPerMinute: TimeInterval = 60,
            loginShell: String = UserAccount.loginShell, home: String = NSHomeDirectory(),
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) {
            self.clock = clock
            self.scheduler = scheduler
            self.hotkeys = hotkeys
            self.appearance = appearance
            self.files = files
            self.loginItem = loginItem
            self.systemSettings = systemSettings
            self.notifier = notifier
            self.powerAssertions = powerAssertions
            self.powerSource = powerSource
            self.serviceLauncher = serviceLauncher
            self.portProbe = portProbe
            self.folderPicker = folderPicker
            self.loginShell = loginShell
            self.home = home
            self.environment = environment
            self.dataFolder = dataFolder
            self.focusSecondsPerMinute = focusSecondsPerMinute
        }
    }

    public let settings: SettingsStore
    public let hud: HUDStore
    public let registry: ActionRegistry
    public let focus: FocusStore
    public let caffeine: CaffeineStore
    public let services: ServiceStore
    @ObservationIgnored private let clock: Clock

    /// The settings-file problem the notice bar has already shown (or that was dismissed).
    private var noticeSeen: SettingsFileProblem?

    /// The activity dot on each tab (amendment 1). Focus: a focus or break runs or is paused,
    /// a prompt waits, or it is snoozed. Caffeine: on. Services adds its own in slice 5;
    /// Chat, Commands and Settings never have one.
    public var tabActivity: [Tab: TabActivity] {
        var activity: [Tab: TabActivity] = [:]
        if focus.phase != .idle { activity[.focus] = .active }
        if caffeine.isOn { activity[.caffeine] = .active }
        if services.failureUnseen {
            activity[.services] = .alert
        } else if !services.liveServices.isEmpty {
            activity[.services] = .active
        }
        return activity
    }

    /// The Mac woke up: timers that ended while it slept move on now (ADR-001 §4.3).
    public func clockJumped() {
        focus.clockJumped()
        caffeine.clockJumped()
    }

    /// An answer from Notification Center, by the category and action identifiers the shell
    /// registered. Unknown identifiers are ignored.
    /// `requestID` is the notification's own id, which names the service for `service.failed`.
    public func handleNotification(category: String, action: String?, requestID: String = "") {
        guard let category = NotificationCategory(rawValue: category) else { return }
        let parsed = action.flatMap(NotificationAction.init(rawValue:))
        if action != nil && parsed == nil { return }
        if let parsed, !category.actions.contains(parsed) { return }
        switch category {
        case .serviceFailed:
            // Show Logs, or a click on the body: Services, with that service's log open.
            guard let id = ServiceStore.serviceID(fromNotification: requestID) else { return }
            hud.selectTab(.services)
            services.showLogs(id)
        case .focusEnd, .breakEnd, .breakAutostart:
            focus.handleNotification(category, action: parsed)
        }
    }

    /// The question before quitting while services run (UX part 1, §10), or nil to quit at once.
    /// Focus or Caffeine alone don't ask.
    public var quitQuestion: QuitQuestion? {
        let live = services.liveServices
        guard !live.isEmpty else { return nil }
        let alsoStops = focus.phase != .idle || caffeine.isOn
        return QuitQuestion(
            title: Strings.Services.quitTitle, message: Strings.Services.quitMessage(live.map(\.name)),
            detail: alsoStops ? Strings.Services.quitAlsoStops : nil, quit: Strings.Services.quitAndStop,
            cancel: Strings.Services.cancel)
    }

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
        let history: FocusHistory =
            ports.dataFolder.map { SQLiteFocusHistory(folder: $0, today: FocusDayFormat.string(ports.clock.now)) }
            ?? MemoryFocusHistory()
        let focus = FocusStore(
            clock: ports.clock, scheduler: ports.scheduler, settings: settings, history: history,
            notifier: ports.notifier, navigator: hud, toaster: hud, secondsPerMinute: ports.focusSecondsPerMinute)
        self.focus = focus
        let caffeine = CaffeineStore(
            clock: ports.clock, scheduler: ports.scheduler, settings: settings, assertions: ports.powerAssertions,
            power: ports.powerSource, toaster: hud)
        self.caffeine = caffeine
        let services = ServiceStore(
            folder: ports.dataFolder, clock: ports.clock, scheduler: ports.scheduler, launcher: ports.serviceLauncher,
            ports: ports.portProbe, notifier: ports.notifier, files: ports.files, settings: settings, toaster: hud,
            loginShell: ports.loginShell, home: ports.home, baseEnvironment: ports.environment)
        self.services = services
        self.clock = ports.clock
        loginItem = ports.loginItem
        systemSettings = ports.systemSettings
        files = ports.files
        folderPicker = ports.folderPicker
        openAtLogin = ports.loginItem.status
        settings.attach(toaster: hud, revealer: ports.files)

        registry.add(.focus) { [weak focus, weak hud] in
            guard let focus, let hud else { return [] }
            return FocusActions.make(focus: focus, hud: hud)
        }
        registry.add(.caffeine) { [weak caffeine] in caffeine.map { CaffeineActions.make(caffeine: $0) } ?? [] }
        registry.add(.service) { [weak services] in services.map { ServiceActions.make(services: $0) } ?? [] }
        registry.add(.model) { [weak hud] in hud.map { ShellActions.addModel(hud: $0, chat: chat) } ?? [] }
        registry.add(.theme) { [weak settings] in
            settings.map { ShellActions.theme(settings: $0, appearance: ports.appearance) } ?? []
        }
        registry.add(.view) { [weak hud] in hud.map { ShellActions.goTo(hud: $0) } ?? [] }

        hud.onEvent = { [weak self] event in
            self?.handle(event)
        }
        focusSource = { [weak focus] in focus?.snapshot ?? .idle(nextLength: 25) }
        caffeineSource = { [weak caffeine] in caffeine?.snapshot ?? .off }
        servicesSource = { [weak services] in services?.snapshot ?? ServicesSnapshot() }
    }

    private func handle(_ event: HUDEvent) {
        switch event {
        case .closed:
            if settingsNotice != nil { noticeSeen = settings.fileProblem }
            endWelcome()
            focus.cancelSnoozeHide()
        case .tabChanged(let tab):
            focus.cancelSnoozeHide()
            if tab == .services { services.sawServices() }
            if tab != .chat { endWelcome() }
            // The user may have changed Open at Login in System Settings meanwhile.
            if tab == .settings { refreshOpenAtLogin() }
        }
    }

    /// Runs once the app has finished launching: registers the wake shortcut, and on the
    /// very first launch opens the HUD with the welcome (UX part 1, §3).
    public func launch() {
        hud.registerHotkey()
        services.startAutostart()
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
    @ObservationIgnored private let folderPicker: FolderPicker

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
    @ObservationIgnored var servicesSource: @MainActor () -> ServicesSnapshot = { ServicesSnapshot() }
    @ObservationIgnored var pinnedChatsSource: @MainActor () -> Int = { 0 }

    var focusSnapshot: FocusSnapshot { focusSource() }
    var caffeineSnapshot: CaffeineSnapshot { caffeineSource() }
    var servicesSnapshot: ServicesSnapshot { servicesSource() }
    var pinnedChats: Int { pinnedChatsSource() }

    /// The menu bar item now. The shell redraws it when this changes, and at `nextChange`.
    public var statusItem: StatusItemModel {
        StatusItemModel(
            focus: focusSnapshot, caffeine: caffeineSnapshot, now: clock.now,
            promptVisible: hud.isOpen, showSeconds: settings.settings.general.menuSeconds)
    }

    /// The item shows as pressed while the HUD or its menu is open.
    public var statusItemHighlighted: Bool { hud.isOpen || menuOpen }

    /// The menu bar menu's content, built when it opens.
    public var menu: MenuModel {
        MenuModel(
            hotkey: hud.hotkey, focus: focusSnapshot, caffeine: caffeineSnapshot, services: servicesSnapshot,
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
            caffeine.toggle()
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
                    systemSettings: FakeSystemSettingsLinks(), notifier: FakeNotifier(),
                    powerAssertions: FakePowerAssertions(), powerSource: FakePowerSource(),
                    serviceLauncher: FakeServiceLauncher(), portProbe: FakePortProbe(),
                    folderPicker: FakeFolderPicker(), dataFolder: nil),
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
    /// The Focus tab: it always has a body (idle, running, a prompt, snoozed).
    case focus
    /// The Caffeine tab: it always has a body.
    case caffeine
    /// The Services tab: it always has a body (the list, the empty state or the file problem).
    case services
    /// The Settings tab.
    case settings
    /// The first-run welcome, on Chat.
    case welcome
    /// Nothing: the HUD collapses to its header and footer.
    case empty
}

extension AppModel {
    /// The body, by precedence: suggestions, then Focus, then Caffeine, then Services, then
    /// Settings, then the welcome on Chat. The model menu joins this rule in the chat slice.
    public var body: HUDBody {
        if !hud.suggestions.isEmpty { return .suggestions }
        if hud.tab == .focus { return .focus }
        if hud.tab == .caffeine { return .caffeine }
        if hud.tab == .services { return .services }
        if hud.tab == .settings { return .settings }
        if hud.tab == .chat && showsWelcome { return .welcome }
        return .empty
    }

    // MARK: Services

    /// Add a service…: Settings → Services, with a new form. A form already open with changes
    /// stays as it is, so they aren't lost.
    public func addService() {
        hud.showSettings(.services)
        if services.form?.isDirty != true { services.editService(nil) }
    }

    /// Edit…, on a row that can't start: Settings → Services with that service's form, which
    /// shows its problems. A form already open with changes stays as it is.
    public func editService(_ id: ServiceDefinition.ID) {
        hud.showSettings(.services)
        if services.form?.isDirty != true { services.editService(id) }
    }

    /// The Services tab header's Edit…: Settings → Services, as it was left.
    public func openServicesSettings() {
        hud.showSettings(.services)
    }

    /// Choose…, in the service form: the folder panel, whose answer goes into the draft. The
    /// HUD stays open while the panel shows.
    @discardableResult
    public func chooseServiceFolder() -> Task<Void, Never> {
        let start = SpawnPlan.expand(services.form?.draft.cwd ?? "~", home: services.home)
        hud.beginModal()
        return Task { @MainActor in
            let chosen = await folderPicker.chooseFolder(startingAt: start)
            hud.endModal()
            if let chosen { services.setDraftFolder(chosen) }
        }
    }

    /// Esc. While Settings → Services shows the service form, it is the form's Cancel;
    /// otherwise the HUD's Esc.
    public func escape() {
        if body == .settings && hud.settingsSection == .services && services.form != nil {
            services.cancelForm()
        } else {
            hud.escape()
        }
    }
}
