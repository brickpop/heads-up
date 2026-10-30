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
        public var openPanels: OpenPanels
        /// Decodes and cleans chat images (F17): ImageIO on macOS.
        public var imageProcessor: ImageProcessor
        /// The calendar and reminders the tools read: EventKit on macOS.
        public var calendar: CalendarReader
        public var reminders: RemindersAccess
        public var terminalLauncher: TerminalLauncher
        /// Endpoint tokens: the Keychain on macOS.
        public var secrets: SecretStore
        /// Requests to model servers, under `HTTPTransport`.
        public var httpClient: HTTPClient
        /// Opens links from replies; copies text.
        public var linkOpener: LinkOpener
        public var pasteboard: Pasteboard
        /// The model API; nil is the OpenAI-compatible provider over `httpClient`. Tests give a fake.
        public var llmProvider: LLMProvider?
        /// The user's login shell, home folder and environment, for services.
        public var loginShell: String
        public var home: String
        public var environment: [String: String]
        /// Whether services start from the environment of an interactive login shell, read once
        /// (`ShellEnvironment`). The app sets it; tests and previews keep `environment` as it is.
        public var readsShellEnvironment: Bool
        /// Where settings.json lives; nil keeps settings in memory only.
        public var dataFolder: URL?
        /// Where pinned chats are kept; nil is headsup.sqlite in `dataFolder`, or memory without one.
        public var pinnedChats: PinnedChats?
        /// How long a timer minute lasts: 60 s, except in a debug build made with `just app-quick`.
        public var focusSecondsPerMinute: TimeInterval

        public init(
            clock: Clock, scheduler: Scheduler, hotkeys: HotkeyRegistrar, appearance: SystemAppearance,
            files: FileRevealer, loginItem: LoginItem, systemSettings: SystemSettingsLinks, notifier: Notifier,
            powerAssertions: PowerAssertions, powerSource: PowerSource, serviceLauncher: ServiceLauncher,
            portProbe: PortProbe, openPanels: OpenPanels, imageProcessor: ImageProcessor, calendar: CalendarReader,
            reminders: RemindersAccess, terminalLauncher: TerminalLauncher, secrets: SecretStore,
            httpClient: HTTPClient, linkOpener: LinkOpener, pasteboard: Pasteboard, llmProvider: LLMProvider? = nil,
            dataFolder: URL?,
            focusSecondsPerMinute: TimeInterval = 60,
            loginShell: String = UserAccount.loginShell, home: String = NSHomeDirectory(),
            environment: [String: String] = ProcessInfo.processInfo.environment,
            readsShellEnvironment: Bool = false
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
            self.openPanels = openPanels
            self.imageProcessor = imageProcessor
            self.calendar = calendar
            self.reminders = reminders
            self.terminalLauncher = terminalLauncher
            self.secrets = secrets
            self.httpClient = httpClient
            self.linkOpener = linkOpener
            self.pasteboard = pasteboard
            self.llmProvider = llmProvider
            self.loginShell = loginShell
            self.home = home
            self.environment = environment
            self.readsShellEnvironment = readsShellEnvironment
            self.dataFolder = dataFolder
            self.focusSecondsPerMinute = focusSecondsPerMinute
        }
    }

    public let settings: SettingsStore
    public let hud: HUDStore
    public let registry: ActionRegistry
    public let focus: FocusStore
    public let caffeine: CaffeineStore
    /// Holds the power assertions for Caffeine and the services.
    public let powerHolds: PowerHolds
    public let services: ServiceStore
    public let commands: CommandStore
    public let endpoints: EndpointService
    public let chat: ChatStore
    /// The pinned chats: the list, its screen, unpinning and loading.
    public let pins: PinsStore
    @ObservationIgnored private let imageProcessor: ImageProcessor
    @ObservationIgnored private let clock: Clock

    /// The settings-file problem the notice bar has already shown (or that was dismissed).
    private var noticeSeen: SettingsFileProblem?
    /// The model menu's keyboard selection: a row, or Manage endpoints… after the last.
    private var modelMenuSelection = 0

    /// The activity dot on each tab (amendment 1). Focus: a focus or break runs or is paused,
    /// a prompt waits, or it is snoozed. Caffeine: on, or a service holds the Mac awake (or would,
    /// but for the battery). Services: a failure unseen, or one running. Chat, Commands and Settings
    /// never have one.
    public var tabActivity: [Tab: TabActivity] {
        var activity: [Tab: TabActivity] = [:]
        if focus.phase != .idle { activity[.focus] = .active }
        let caffeineSnapshot = caffeine.snapshot
        if caffeineSnapshot.isOn || caffeineSnapshot.isHeld || caffeineSnapshot.isHeldButPaused {
            activity[.caffeine] = .active
        }
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
            title: Strings.Services.quitTitle(live.count), message: Strings.Services.quitMessage(live.map(\.name)),
            detail: alsoStops ? Strings.Services.quitAlsoStops : nil, quit: Strings.Services.quitAndTerminate,
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
        // The one owner of power assertions, for Caffeine and the services (flags addendum §3).
        let powerHolds = PowerHolds(assertions: ports.powerAssertions, power: ports.powerSource, settings: settings)
        self.powerHolds = powerHolds
        let caffeine = CaffeineStore(
            clock: ports.clock, scheduler: ports.scheduler, settings: settings, holds: powerHolds, toaster: hud)
        self.caffeine = caffeine
        let services = ServiceStore(
            folder: ports.dataFolder, clock: ports.clock, scheduler: ports.scheduler, launcher: ports.serviceLauncher,
            ports: ports.portProbe, notifier: ports.notifier, files: ports.files, settings: settings, toaster: hud,
            loginShell: ports.loginShell, home: ports.home, baseEnvironment: ports.environment,
            readsShellEnvironment: ports.readsShellEnvironment, holds: powerHolds)
        self.services = services
        caffeine.serviceHolds = { [weak services] in services?.serviceHolds ?? [] }
        commands = CommandStore(
            folder: ports.dataFolder, launcher: ports.terminalLauncher, files: ports.files, settings: settings,
            toaster: hud, loginShell: ports.loginShell, home: ports.home)
        let endpoints = EndpointService(
            settings: settings, secrets: ports.secrets,
            transport: HTTPTransport(client: ports.httpClient, secrets: ports.secrets), ports: ports.portProbe,
            services: services, clock: ports.clock, scheduler: ports.scheduler, toaster: hud, modal: hud)
        self.endpoints = endpoints
        let pins = PinsStore(
            store: ports.pinnedChats ?? ports.dataFolder.map { SQLitePinnedChats(folder: $0) } ?? MemoryPinnedChats(),
            clock: ports.clock)
        self.pins = pins
        imageProcessor = ports.imageProcessor
        let gatedTools = GatedTools(
            settings: settings, ports: ToolPorts(calendar: ports.calendar, reminders: ports.reminders),
            pasteboard: ports.pasteboard, clock: ports.clock, modal: hud, focus: focus)
        let chatStore = ChatStore(
            endpoints: endpoints, settings: settings,
            provider: ports.llmProvider ?? OpenAICompatibleProvider(transport: endpoints.transport),
            tools: gatedTools, actions: registry,
            clock: ports.clock, scheduler: ports.scheduler, ports: ports.portProbe, links: ports.linkOpener,
            pasteboard: ports.pasteboard, imageProcessor: ports.imageProcessor,
            pins: pins, toaster: hud)
        self.chat = chatStore
        gatedTools.display = chatStore
        chatStore.pinCount = { [weak pins] in pins?.count ?? 0 }
        pins.loadedID = { [weak chatStore] in chatStore?.pinnedID }
        pins.didDelete = { [weak chatStore] id in chatStore?.pinDeleted(id) }
        hud.attach(chat: chatStore)
        // F6, S2: a guarded button acts only while the HUD is key, 600 ms after it appeared and
        // 600 ms after the HUD became key (ActionGuard).
        chatStore.armedAt = { [weak hud] shownAt in
            guard let hud, hud.isKey else { return nil }
            return ActionGuard.armedAt(shownAt: shownAt, keySince: hud.keySince)
        }
        self.clock = ports.clock
        loginItem = ports.loginItem
        systemSettings = ports.systemSettings
        files = ports.files
        openPanels = ports.openPanels
        pasteboard = ports.pasteboard
        openAtLogin = ports.loginItem.status
        settings.attach(toaster: hud, revealer: ports.files)

        registry.add(.focus) { [weak focus, weak hud] in
            guard let focus, let hud else { return [] }
            return FocusActions.make(focus: focus, hud: hud)
        }
        // A typed /start 35 or /break 5: its row, made for each query.
        registry.quickTimer = { [weak focus, weak hud, clock = ports.clock] kind, minutes in
            guard let focus else { return nil }
            return QuickTimerActions.make(
                kind: kind, minutes: minutes, focus: focus, hud: hud, now: clock.now, calendar: .current)
        }
        registry.add(.caffeine) { [weak caffeine] in caffeine.map { CaffeineActions.make(caffeine: $0) } ?? [] }
        registry.add(.service) { [weak services] in services.map { ServiceActions.make(services: $0) } ?? [] }
        registry.explainers.append { [weak services] id in
            services.flatMap { ServiceActions.unavailable(id, services: $0) }
        }
        registry.add(.theme) { [weak settings] in
            settings.map { ShellActions.theme(settings: $0, appearance: ports.appearance) } ?? []
        }
        registry.add(.view) { [weak hud] in hud.map { ShellActions.goTo(hud: $0) } ?? [] }

        hud.onEvent = { [weak self] event in
            self?.handle(event)
        }
        registry.add(.model) { [weak self, weak hud] in
            guard let self, let hud else { return [] }
            return ShellActions.addModel(hud: hud, chat: self.chat)
                + ModelActions.make(endpoints: endpoints) { [weak self] id in self?.selectModel(id) }
        }
        registry.add(.command) { [weak self] in
            guard let self else { return [] }
            return CommandActions.make(commands: commands) { [weak self] id in self?.runCommand(id) }
        }
        registry.add(.chat) { [weak chatStore, weak pins, weak hud] in
            guard let chatStore, let pins, let hud else { return [] }
            return ChatActions.make(chat: chatStore, pins: pins, hud: hud)
        }
        focusSource = { [weak focus] in focus?.snapshot ?? .idle(nextLength: 25) }
        caffeineSource = { [weak caffeine] in caffeine?.snapshot ?? .off }
        servicesSource = { [weak services] in services?.snapshot ?? ServicesSnapshot() }
    }

    private func handle(_ event: HUDEvent) {
        switch event {
        case .closed:
            if settingsNotice != nil { noticeSeen = settings.fileProblem }
            // Closing never stops a reply, unless an unpinned chat is cleared on close: then it
            // stops first. A pinned chat stays.
            if settings.settings.general.clearOnClose && !chat.isPinned { chat.newChat() }
            endWelcome()
            focus.cancelHideSoon()
        case .inputChanged:
            focus.cancelHideSoon()
        case .tabChanged(let tab):
            focus.cancelHideSoon()
            if tab == .services { services.sawServices() }
            // A terminal may have been installed or removed meanwhile; Settings → General has the picker too.
            if tab == .commands || tab == .settings { commands.refreshTerminals() }
            if tab != .chat { endWelcome() }
            // The user may have changed Open at Login in System Settings meanwhile.
            if tab == .settings { refreshOpenAtLogin() }
            if tab == .settings && hud.settingsSection == .models { endpoints.probeLocal() }
        case .modelMenuOpened:
            modelMenuSelection = endpoints.endpoints.firstIndex { $0.id == endpoints.activeID } ?? 0
            endpoints.probeLocal()
        case .settingsSectionChanged(let section):
            if section == .models { endpoints.probeLocal() }
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
    @ObservationIgnored private let openPanels: OpenPanels
    @ObservationIgnored private let pasteboard: Pasteboard

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

    /// What Focus, Caffeine and Services report to the menu bar. AppModel points these at their
    /// stores; tests set them.
    @ObservationIgnored var focusSource: @MainActor () -> FocusSnapshot = { .idle(nextLength: 25) }
    @ObservationIgnored var caffeineSource: @MainActor () -> CaffeineSnapshot = { .off }
    @ObservationIgnored var servicesSource: @MainActor () -> ServicesSnapshot = { ServicesSnapshot() }

    var focusSnapshot: FocusSnapshot { focusSource() }
    var caffeineSnapshot: CaffeineSnapshot { caffeineSource() }
    var servicesSnapshot: ServicesSnapshot { servicesSource() }

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
            pinnedChats: pins.count, now: clock.now)
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
                    openPanels: FakeOpenPanels(), imageProcessor: FakeImageProcessor(),
                    calendar: FakeCalendarReader(), reminders: FakeRemindersAccess(),
                    terminalLauncher: FakeTerminalLauncher(),
                    secrets: MemorySecretStore(), httpClient: FakeHTTPClient(), linkOpener: FakeLinkOpener(),
                    pasteboard: FakePasteboard(), dataFolder: nil),
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
    /// The Commands tab: it always has a body.
    case commands
    /// The Settings tab.
    case settings
    /// The model menu, over any tab body (ADR-001 §4.1).
    case modelMenu
    /// The Chat tab's conversation, once it has a message.
    case conversation
    /// The Pinned list, in place of the conversation.
    case pinnedList
    /// The first-run welcome, on Chat.
    case welcome
    /// Nothing: the HUD collapses to its header and footer.
    case empty
}

extension AppModel {
    /// The body, by precedence: the model menu, then suggestions, then Focus, then Caffeine,
    /// then Services, then Commands, then Settings, then the Pinned list, then the conversation,
    /// then the welcome on Chat.
    public var body: HUDBody {
        if hud.modelMenuOpen { return .modelMenu }
        if !hud.suggestions.isEmpty { return .suggestions }
        if hud.tab == .focus { return .focus }
        if hud.tab == .caffeine { return .caffeine }
        if hud.tab == .services { return .services }
        if hud.tab == .commands { return .commands }
        if hud.tab == .settings { return .settings }
        if hud.tab == .chat && hud.chatView == .pinned { return .pinnedList }
        if hud.tab == .chat && hud.chatView == .conversation && chat.hasMessages { return .conversation }
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

    /// Choose…, in the service form: the folder panel, whose answer goes into the draft.
    @discardableResult
    public func chooseServiceFolder() -> Task<Void, Never> {
        chooseFolder(startingAt: SpawnPlan.expand(services.form?.draft.cwd ?? "~", home: services.home)) {
            [weak self] in self?.services.setDraftFolder($0)
        }
    }

    // MARK: Commands

    /// A row's click, or the Run action: opens the command in the chosen terminal.
    ///
    /// The Automation prompt and the terminal coming forward both take the keyboard from the
    /// HUD, so it is held open meanwhile. The run returns only once the prompt, if any, is
    /// answered. When the command opened, the HUD closes, as Spotlight does: the terminal is
    /// what the user wants to see (App shell, "After launching a command"). When it didn't, the
    /// HUD stays open and Commands shows the problem under the row.
    @discardableResult
    public func runCommand(_ id: CommandDefinition.ID) -> Task<Void, Never> {
        hud.beginModal()
        return Task { @MainActor in
            let result = await commands.run(id)
            hud.endModal()
            switch result {
            case .opened: hud.close()
            case nil: break
            case .some: hud.selectTab(.commands)
            }
        }
    }

    /// Add a command…: Settings → Commands, with a new form. A form already open with changes
    /// stays as it is.
    public func addCommand() {
        hud.showSettings(.commands)
        if commands.form?.isDirty != true { commands.editCommand(nil) }
    }

    /// A click on a command that can't run, or its Edit…: Settings → Commands with that
    /// command's form, which shows its problems. A form already open with changes stays.
    public func editCommand(_ id: CommandDefinition.ID) {
        hud.showSettings(.commands)
        if commands.form?.isDirty != true { commands.editCommand(id) }
    }

    /// The Commands tab header's Edit…: Settings → Commands, as it was left.
    public func openCommandsSettings() {
        hud.showSettings(.commands)
    }

    /// Open Settings, under a command whose terminal isn't there any more: Settings → General,
    /// where the terminal is chosen.
    public func openTerminalSetting() {
        hud.showSettings(.general)
    }

    /// Choose…, in the command form.
    @discardableResult
    public func chooseCommandFolder() -> Task<Void, Never> {
        chooseFolder(startingAt: SpawnPlan.expand(commands.form?.draft.cwd ?? "~", home: commands.home)) {
            [weak self] in self?.commands.setDraftFolder($0)
        }
    }

    /// Open Privacy & Security, under a command macOS refused to open.
    public func openAutomationSettings() {
        systemSettings.openAutomation()
    }

    // MARK: Keys

    /// The footer's left side: the HUD's, except that the Focus tab's cards and the Caffeine
    /// durations, with the prompt field empty, show their own keys.
    public var footerLeft: FooterLeft {
        let left = hud.footerLeft
        guard case .hints = left, hud.input.isEmpty else { return left }
        if body == .focus && focus.showsCards { return .hints(Strings.Hints.focusCards) }
        if body == .caffeine { return .hints(Strings.Hints.caffeineCards) }
        return left
    }

    /// A key with modifiers, while the HUD is key. The Focus and Caffeine tabs' own keys come
    /// first, while their view shows: ⌥← ⌥→ pick a card while the prompt field is empty (with
    /// text, they move by word), and on Focus ⌘↩ runs the primary button. Then the HUD's ⌘
    /// shortcuts, ⌘← ⌘→ for the tabs among them.
    public func handleShortcut(_ shortcut: Shortcut) -> Bool {
        if body == .focus {
            switch (shortcut.modifiers, shortcut.keyCode) {
            case (.option, KeyCode.leftArrow) where hud.input.isEmpty:
                if focus.moveCardSelection(by: -1) { return true }
            case (.option, KeyCode.rightArrow) where hud.input.isEmpty:
                if focus.moveCardSelection(by: 1) { return true }
            case (.command, KeyCode.returnKey), (.command, KeyCode.keypadEnter):
                if focus.runPrimaryAction() { return true }
            default:
                break
            }
        }
        if body == .caffeine, shortcut.modifiers == .option, hud.input.isEmpty {
            switch shortcut.keyCode {
            case KeyCode.leftArrow:
                caffeine.moveDurationSelection(by: -1)
                return true
            case KeyCode.rightArrow:
                caffeine.moveDurationSelection(by: 1)
                return true
            default:
                break
            }
        }
        return hud.handleShortcut(shortcut)
    }

    // MARK: Forms

    /// Esc. While Settings → Services or Commands shows its form, it is the form's Cancel;
    /// otherwise the HUD's Esc.
    public func escape() {
        if body == .settings && hud.settingsSection == .services && services.form != nil {
            services.cancelForm()
        } else if body == .settings && hud.settingsSection == .commands && commands.form != nil {
            commands.cancelForm()
        } else if body == .settings && hud.settingsSection == .models && endpoints.form.tokenHostQuestion != nil {
            // Esc closes the token-host question; nothing is tested or saved.
            endpoints.dismissTokenHostQuestion()
        } else {
            hud.escape()
        }
    }

    /// The folder panel, opening at `start`. The HUD stays open while it shows; a chosen
    /// folder goes to `chosen`.
    private func chooseFolder(startingAt start: String, then chosen: @escaping (String) -> Void) -> Task<Void, Never> {
        hud.beginModal()
        return Task { @MainActor in
            let folder = await openPanels.chooseFolder(startingAt: start)
            hud.endModal()
            if let folder { chosen(folder) }
        }
    }
}

extension AppModel {
    // MARK: Models

    /// The model chip in the Chat header; nil on other tabs.
    public var modelChip: ModelChip? {
        guard hud.tab == .chat else { return nil }
        let name = endpoints.active?.name
        return ModelChip(
            title: name ?? Strings.ModelMenu.noModel, isPlaceholder: name == nil, isOpen: hud.modelMenuOpen,
            accessibilityLabel: Strings.ModelMenu.chipLabel(name ?? Strings.ModelMenu.noModel))
    }

    /// The model menu, while open.
    public var modelMenu: ModelMenuScreen {
        let list = endpoints.endpoints
        let selection = min(modelMenuSelection, list.count)
        return ModelMenuScreen(
            label: Strings.ModelMenu.label, emptyLine: list.isEmpty ? Strings.ModelMenu.empty : nil,
            rows: list.enumerated().map { index, endpoint in
                let notRunning = endpoints.isRunning(endpoint) == false
                var detail = Strings.Models.detail(provider: endpoint.tag.providerText, model: endpoint.model)
                if notRunning { detail += " · " + Strings.ModelMenu.notRunning }
                return ModelMenuScreen.Row(
                    id: endpoint.id, name: endpoint.name,
                    localTag: endpoint.tag.isLocal ? Strings.Models.localTag : nil,
                    detail: detail, isActive: endpoint.id == endpoints.activeID, isSelected: index == selection,
                    start: notRunning && endpoints.service(for: endpoint) != nil ? Strings.ModelMenu.start : nil)
            }, manage: Strings.ModelMenu.manage, manageSelected: selection == list.count)
    }

    /// Picking a model, in the menu or with "Switch model to …": it chats from now on, the menu
    /// closes, and the toast names it. The default stays as it is.
    public func selectModel(_ id: Endpoint.ID) {
        guard let endpoint = endpoints.endpoint(id) else { return }
        endpoints.setActive(id)
        hud.closeModelMenu()
        hud.toast(Strings.Models.active(endpoint.name))
    }

    /// Start, on a menu row whose local server isn't running: starts its service.
    public func startEndpointService(_ id: Endpoint.ID) {
        guard let endpoint = endpoints.endpoint(id), let service = endpoints.service(for: endpoint) else { return }
        services.start(service.id)
    }

    /// Start <service>, on a Test connection result: starts the draft's service, and the test
    /// runs again once its port answers.
    public func startTestService() {
        guard let service = endpoints.draftService() else { return }
        services.start(service.id)
        endpoints.waitForService(service)
    }

    /// Open Services, after a service didn't start: the Services tab with its log open.
    public func openTestServiceLogs() {
        guard let service = endpoints.draftService() else { return }
        hud.selectTab(.services)
        services.showLogs(service.id)
    }

    /// Manage endpoints…: Settings → Models.
    public func manageEndpoints() {
        hud.showSettings(.models)
    }

    /// ↑ ↓ in the model menu, over the rows and Manage endpoints….
    public func moveModelMenuSelection(_ delta: Int) {
        let last = endpoints.endpoints.count
        modelMenuSelection = max(0, min(last, min(modelMenuSelection, last) + delta))
    }

    /// Return in the model menu: the selected model, or Manage endpoints…, which is also what
    /// Return does with no endpoint.
    public func chooseModelMenuSelection() {
        let list = endpoints.endpoints
        if modelMenuSelection < list.count {
            selectModel(list[modelMenuSelection].id)
        } else {
            manageEndpoints()
        }
    }
}

extension AppModel {
    // MARK: Local tools

    /// Open System Settings, on a tool row macOS blocked: its privacy pane.
    public func fixTool(_ rowID: String) {
        guard case .blocked(let permission)? = chat.record(rowID)?.status else { return }
        systemSettings.openPrivacy(permission)
    }

    /// The app is quitting: a waiting card becomes Denied, and a pinned chat is saved as it is.
    public func willQuit() {
        chat.stop()
    }

    // MARK: Images and pins

    /// The header's Pinned chats and Attach image buttons; nil off the Chat tab.
    public var chatButtons: ChatButtons? {
        guard hud.tab == .chat else { return nil }
        return ChatButtons(
            pinned: ChatButtons.Pinned(
                help: Strings.Attachments.pinnedChats, accessibilityLabel: Strings.Attachments.pinnedChats,
                isOn: hud.chatView == .pinned),
            attach: ChatButtons.Attach(
                help: Strings.Attachments.attachHelp, accessibilityLabel: Strings.Attachments.attach))
    }

    /// Attach image: the open panel for images. The HUD stays open while it shows. Only what
    /// fits is read; the chat counts the rest for the notice.
    @discardableResult
    public func pickImages() -> Task<Void, Never> {
        hud.beginModal()
        let limit = chat.imageRoom
        return Task { @MainActor in
            let picked = await openPanels.chooseImages(limit: limit)
            hud.endModal()
            await chat.attach(picked.inputs, offered: picked.offered)?.value
        }
    }

    /// ⌘V while the clipboard holds images (the key monitor asks `pasteboard.hasImages` first;
    /// text paste stays the prompt's own). False when there were none.
    @discardableResult
    public func pasteImages() -> Bool {
        guard pasteboard.hasImages else { return false }
        let pasted = pasteboard.readImages(limit: chat.imageRoom)
        chat.attach(pasted.inputs, offered: pasted.offered)
        return true
    }

    /// Whether ⌘V should attach images rather than paste text.
    public var clipboardHasImages: Bool { pasteboard.hasImages }

    /// A button on the image notice.
    public func performAttachmentNotice(_ kind: NoticeAction.Kind) {
        switch kind {
        case .switchModel(let id): selectModel(id)
        case .removeImages: chat.removeAllAttachments()
        case .openSettings: hud.showSettings(.models)
        }
    }

    /// A row of the Pinned list: the chat replaces the conversation (a reply stops first), the
    /// list closes and the prompt is cleared.
    /// A chat that can't be read stays out, and the list says so. Its thumbnails are made once,
    /// off the main actor, after it shows (Rev 4): the stored images are full size.
    @discardableResult
    public func loadPinned(_ id: String) -> Task<Void, Never>? {
        guard let stored = pins.open(id) else { return nil }
        chat.restore(stored)
        if hud.chatView == .pinned { hud.togglePinnedList() }
        hud.setInput("")
        let images = stored.images.mapValues(\.data)
        guard !images.isEmpty else { return nil }
        let processor = imageProcessor
        return Task { [weak self] in
            let previews = await Task.detached(priority: .userInitiated) {
                images.compactMapValues { data in try? processor.preview(data) }
            }.value
            self?.chat.setPreviews(previews)
        }
    }

    // MARK: Chat

    /// A problem row's button. Each joins the chat with the endpoints, the services or the HUD.
    /// False when nothing happened: the row is gone or answered, Try again still waits for a rate
    /// limit, or the F6 guard ignored Continue.
    @discardableResult
    public func recover(_ rowID: Problem.ID, _ action: ProblemAction) -> Bool {
        guard let row = chat.problem(rowID), !row.isSuperseded, row.starting == nil else { return false }
        let endpointID: Endpoint.ID? =
            switch row.kind {
            case .error(_, let id), .stepLimit(_, let id, _): id
            case .noEndpoint: nil
            }
        switch action {
        case .tryAgain:
            if case .error(.rateLimited(let wait?), _) = row.kind,
                clock.now < row.shownAt.addingTimeInterval(TimeInterval(wait.components.seconds))
            {
                return false
            }
            // The user asks again: the keychain may prompt again.
            if case .error(.keychainDenied, let id) = row.kind { endpoints.transport.allowKeychainRead(id) }
            chat.retry()
        case .editEndpoint:
            hud.showSettings(.models)
            if let endpointID { endpoints.editEndpoint(endpointID) }
        case .startService:
            guard let endpoint = endpointID.flatMap(endpoints.endpoint), let service = endpoints.service(for: endpoint),
                let port = EndpointService.port(endpoint.baseURL)
            else { return false }
            services.start(service.id)
            chat.waitForServer(rowID, service: service.name, port: port)
        case .newChat:
            chat.newChat()
        case .switchModel:
            hud.selectTab(.chat)
            if !hud.modelMenuOpen { hud.toggleModelMenu() }
        case .openSettings:
            hud.showSettings(.models)
        case .continueAfterLimit:
            return chat.continueAfterLimit(rowID)
        }
        return true
    }
}
