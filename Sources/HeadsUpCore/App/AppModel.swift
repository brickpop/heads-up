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
        /// Where settings.json lives; nil keeps settings in memory only.
        public var dataFolder: URL?

        public init(
            clock: Clock, scheduler: Scheduler, hotkeys: HotkeyRegistrar, appearance: SystemAppearance,
            dataFolder: URL?
        ) {
            self.clock = clock
            self.scheduler = scheduler
            self.hotkeys = hotkeys
            self.appearance = appearance
            self.dataFolder = dataFolder
        }
    }

    public let settings: SettingsStore
    public let hud: HUDStore
    public let registry: ActionRegistry

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

        registry.add(.model) { [weak hud] in hud.map { ShellActions.addModel(hud: $0, chat: chat) } ?? [] }
        registry.add(.theme) { [weak settings] in
            settings.map { ShellActions.theme(settings: $0, appearance: ports.appearance) } ?? []
        }
        registry.add(.view) { [weak hud] in hud.map { ShellActions.goTo(hud: $0) } ?? [] }

        hud.onClose = { [weak self] in
            guard let self, self.settingsNotice != nil else { return }
            self.noticeSeen = self.settings.fileProblem
        }
    }

    /// Runs once the app has finished launching: registers the wake shortcut.
    public func launch() {
        hud.registerHotkey()
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
        public static func preview(
            settings: Settings = Settings(), hotkey: HotkeyStatus? = nil, systemIsDark: Bool = false,
            settingsFileProblem: SettingsFileProblem? = nil
        ) -> AppModel {
            let clock = ManualClock()
            let model = AppModel(
                ports: Ports(
                    clock: clock, scheduler: ManualScheduler(clock: clock),
                    hotkeys: FakeHotkeyRegistrar(nextStatus: hotkey),
                    appearance: FixedAppearance(isDark: systemIsDark), dataFolder: nil),
                settings: settings)
            if let settingsFileProblem { model.settings.showProblemForPreview(settingsFileProblem) }
            model.launch()
            return model
        }
    #endif
}
