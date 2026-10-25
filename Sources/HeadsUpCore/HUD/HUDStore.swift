import Foundation
import Observation

/// How stores open the HUD, change tab or close it, without knowing HUDStore (ADR-001 §4).
@MainActor
public protocol Navigator: AnyObject {
    func open(tab: Tab?, makeKey: Bool)
    /// A timer ended and wants to show its prompt, without disturbing what the user is doing.
    func autoOpen(tab: Tab, announcement: String)
    func showSettings(_ section: SettingsSection)
    func close()
}

/// How stores show a toast in the footer.
@MainActor
public protocol Toaster: AnyObject {
    func toast(_ text: String)
}

/// What the HUD needs from the chat: who Ask asks, whether a conversation shows, sending,
/// and the keys that stop it or start again.
@MainActor
public protocol HUDChat: AnyObject {
    var askTarget: AskTarget { get }
    var hasMessages: Bool { get }
    /// A reply is coming: Enter waits, and ⌘. stops it.
    var isBusy: Bool { get }
    func send(_ text: String)
    func stop()
    func newChat()
}

/// Something that happened in the HUD, reported to AppModel through `HUDStore.onEvent`.
public enum HUDEvent: Equatable, Sendable {
    case closed
    case tabChanged(Tab)
    /// The model menu opened: local servers are asked whether they run.
    case modelMenuOpened
    case settingsSectionChanged(SettingsSection)
}

/// The HUD's state and everything the user does in it (ADR-001 §4.1, amendment 1).
@MainActor
@Observable
public final class HUDStore: Navigator, Toaster {
    /// How long a toast replaces the hints.
    public static let toastDuration: TimeInterval = 2.6

    // MARK: State

    public private(set) var isOpen = false
    /// The HUD has keyboard focus. An auto-opened HUD is open but not key.
    public private(set) var isKey = false
    /// When the HUD last became key: approval cards ignore clicks just after (F6).
    public private(set) var keySince: Date?
    public private(set) var tab: Tab = .chat
    public private(set) var chatView: ChatView = .conversation
    public private(set) var input = ""
    public private(set) var modelMenuOpen = false
    public private(set) var settingsSection: SettingsSection = .models
    /// Whether the wake shortcut registered, known once `registerHotkey()` ran at launch.
    public private(set) var hotkey: HotkeyStatus = .ok(.wakeDefault)
    /// How many panels, alerts or permission prompts HeadsUp opened are showing.
    /// While above zero, a click outside doesn't close the HUD.
    public private(set) var modalDepth = 0
    /// The shortcut recorder is listening for keys.
    public private(set) var recording = false
    /// Why the last recorded shortcut wasn't taken, shown under the recorder in --danger.
    public private(set) var recorderProblem: String?

    private var toastText: String?
    private var toastWork: ScheduledWork?
    private var selectedIndex: Int?
    /// What last moved the selection.
    public private(set) var selectionChange: SelectionChange = .typing
    /// Counts toasts, so a toast with the same text as the one before is still announced.
    public private(set) var toastID = 0
    /// The HUD opened without keyboard focus (auto-open) and hasn't had it since.
    private var notKeySinceAutoOpen = false

    /// Tells AppModel what happened in the HUD, for rules that join HUD and other state
    /// (the once-per-launch notice, the welcome). One hook; new needs add cases (amendment 4).
    @ObservationIgnored var onEvent: (@MainActor (HUDEvent) -> Void)?
    @ObservationIgnored private weak var window: HUDWindow?
    @ObservationIgnored private let clock: Clock
    @ObservationIgnored private let scheduler: Scheduler
    @ObservationIgnored private let registry: ActionRegistry
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let hotkeys: HotkeyRegistrar
    @ObservationIgnored private var chat: HUDChat

    public init(
        clock: Clock, scheduler: Scheduler, registry: ActionRegistry, settings: SettingsStore,
        hotkeys: HotkeyRegistrar, chat: HUDChat
    ) {
        self.clock = clock
        self.scheduler = scheduler
        self.registry = registry
        self.settings = settings
        self.hotkeys = hotkeys
        self.chat = chat
    }

    /// Connects the chat, once AppModel has created it.
    func attach(chat: HUDChat) {
        self.chat = chat
    }

    /// Connects the window, once the app has created it.
    public func attach(window: HUDWindow) {
        self.window = window
    }

    // MARK: Derived state

    /// The rows under the prompt for the current input.
    public var suggestions: [SuggestionRow] {
        registry.match(input: input, ask: chat.askTarget, inConversation: inConversation)
    }

    /// The selected row, or nil when none is: Enter then does nothing.
    public var selection: Int? {
        let rows = suggestions
        if let selectedIndex, rows.indices.contains(selectedIndex), rows[selectedIndex].isSelectable {
            return selectedIndex
        }
        return Self.defaultSelection(rows)
    }

    public var placeholder: String {
        guard tab == .chat else { return Strings.Prompt.otherTab }
        if chat.askTarget == .noModel { return Strings.Prompt.chatNoModel }
        return chat.hasMessages ? Strings.Prompt.chatReply : Strings.Prompt.chatEmpty
    }

    /// The footer's left side: a toast for 2.6 s, otherwise the hints for the context.
    public var footerLeft: FooterLeft {
        if let toastText { return .toast(toastText) }
        let rows = suggestions
        if !rows.isEmpty {
            return .hints(rows.first?.isSelectable == false ? Strings.Hints.noMatch : Strings.Hints.suggestions)
        }
        guard tab == .chat else { return .hints(Strings.Hints.otherTab) }
        return .hints(chat.isBusy ? Strings.Hints.chatBusy : Strings.Hints.chat)
    }

    /// The Chat tab shows a conversation with messages.
    private var inConversation: Bool {
        tab == .chat && chatView == .conversation && chat.hasMessages
    }

    /// The first row when it can be selected; nil for "No matching actions" or no rows.
    private static func defaultSelection(_ rows: [SuggestionRow]) -> Int? {
        rows.first?.isSelectable == true ? 0 : nil
    }

    // MARK: Opening and closing

    /// The menu bar item's left click: opens the HUD, or closes it.
    public func toggle() {
        if isOpen {
            close()
        } else {
            open()
        }
    }

    /// Opens the HUD, on `tab` if given, else on the last tab. Without `makeKey` (auto-open
    /// when a session ends) it shows without taking keyboard focus.
    public func open(tab: Tab? = nil, makeKey: Bool = true) {
        if let tab { switchTab(to: tab) }
        if !isOpen { notKeySinceAutoOpen = !makeKey }
        isOpen = true
        window?.show(makeKey: makeKey)
    }

    /// Closes the HUD. The input is cleared and the model menu closes; the tab is kept.
    public func close() {
        guard isOpen else { return }
        cancelRecording()
        isOpen = false
        isKey = false
        keySince = nil
        input = ""
        selectedIndex = nil
        modelMenuOpen = false
        notKeySinceAutoOpen = false
        window?.hide()
        onEvent?(.closed)
    }

    /// The wake shortcut was pressed. It closes an open HUD, except one that opened by itself
    /// and hasn't had keyboard focus yet: the user hasn't seen it, so it takes focus instead.
    public func hotkeyPressed() {
        if isOpen && !notKeySinceAutoOpen {
            close()
        } else {
            open(makeKey: true)
        }
    }

    public func didBecomeKey() {
        isKey = true
        notKeySinceAutoOpen = false
        keySince = clock.now
    }

    /// The HUD lost keyboard focus, usually to a click elsewhere.
    public func didResignKey() {
        guard isKey else { return }
        // A recording ends whenever the HUD loses the keyboard (Scan L1): the shortcut must
        // never stay released.
        cancelRecording()
        isKey = false
        keySince = nil
        if isOpen && settings.settings.general.closeOnClickOutside && modalDepth == 0 {
            close()
        }
    }

    /// HeadsUp is about to show a panel, alert or permission prompt over the HUD.
    public func beginModal() {
        modalDepth += 1
    }

    public func endModal() {
        modalDepth = max(0, modalDepth - 1)
    }

    /// The click-outside rule, after a modal moment in which another app took the keyboard
    /// (a command opened in the terminal): the HUD closes if it isn't key and the setting is on.
    func closeIfNotKey() {
        if isOpen && !isKey && settings.settings.general.closeOnClickOutside && modalDepth == 0 {
            close()
        }
    }

    // MARK: Tabs and views

    /// Goes to `tab`, opening the HUD if it's closed.
    public func selectTab(_ tab: Tab) {
        open(tab: tab, makeKey: true)
    }

    public func showSettings(_ section: SettingsSection) {
        selectSettingsSection(section)
        selectTab(.settings)
    }

    public func selectSettingsSection(_ section: SettingsSection) {
        guard section != settingsSection else { return }
        cancelRecording()
        settingsSection = section
        onEvent?(.settingsSectionChanged(section))
    }

    public func toggleModelMenu() {
        guard tab == .chat else { return }
        modelMenuOpen.toggle()
        if modelMenuOpen { onEvent?(.modelMenuOpened) }
    }

    /// The model menu closes: a model was picked, or Manage endpoints… was chosen.
    func closeModelMenu() {
        modelMenuOpen = false
    }

    /// Shows or leaves the Pinned chats list. It clears the input.
    public func togglePinnedList() {
        if tab != .chat { switchTab(to: .chat) }
        chatView = chatView == .pinned ? .conversation : .pinned
        modelMenuOpen = false
        setInput("")
    }

    private func switchTab(to tab: Tab) {
        if tab != self.tab { cancelRecording() }
        if tab != .chat { chatView = .conversation }
        self.tab = tab
        modelMenuOpen = false
        selectedIndex = nil
        onEvent?(.tabChanged(tab))
    }

    // MARK: Typing

    /// The prompt's text changed. The selection goes back to the first row.
    public func setInput(_ text: String) {
        input = text
        modelMenuOpen = false
        selectedIndex = nil
        selectionChange = .typing
    }

    /// ↑ (-1) or ↓ (+1): moves among the selectable rows, wrapping around.
    public func moveSelection(_ delta: Int) {
        let rows = suggestions
        let selectable = rows.indices.filter { rows[$0].isSelectable }
        guard !selectable.isEmpty, delta != 0 else { return }
        selectionChange = .keyboard
        guard let current = selection, let position = selectable.firstIndex(of: current) else {
            selectedIndex = delta > 0 ? selectable.first : selectable.last
            return
        }
        let count = selectable.count
        selectedIndex = selectable[((position + delta) % count + count) % count]
    }

    /// The pointer moved onto a row: it becomes the selection. The view calls it only for real
    /// pointer movement, not when rows scroll or appear under a still pointer.
    public func hover(_ index: Int) {
        let rows = suggestions
        guard rows.indices.contains(index), rows[index].isSelectable, selectedIndex != index else { return }
        selectedIndex = index
        selectionChange = .pointer
    }

    /// Enter: runs the selected row. With no rows (a reply in a conversation), sends the text.
    /// Never resolves an approval card (F6).
    public func submit() {
        let rows = suggestions
        guard let index = selection else {
            if rows.isEmpty { ask() }
            return
        }
        switch rows[index] {
        case .action(let action):
            setInput("")
            action.run()
        case .ask:
            ask()
        case .noMatch:
            break
        }
    }

    /// Sends the input to the chat; with no model, opens Settings → Models and keeps the text.
    private func ask() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // Enter waits while a reply comes: no queue, and nothing is cancelled.
        guard !chat.isBusy else { return }
        if chat.askTarget == .noModel {
            showSettings(.models)
            return
        }
        selectTab(.chat)
        setInput("")
        chat.send(text)
    }

    /// Esc, the first that applies: close the model menu, clear the input, leave the Pinned
    /// list, close the HUD. It never stops a reply (⌘. does).
    public func escape() {
        if modelMenuOpen {
            modelMenuOpen = false
        } else if !input.isEmpty {
            setInput("")
        } else if tab == .chat && chatView == .pinned {
            chatView = .conversation
        } else {
            close()
        }
    }

    /// ⌘1…6, ⌘, and ⌘N while the HUD is key. Returns false for keys it doesn't handle,
    /// so the text field gets them.
    public func handleShortcut(_ shortcut: Shortcut) -> Bool {
        guard shortcut.modifiers == .command else { return false }
        if let digit = KeyCode.digits.firstIndex(of: shortcut.keyCode), let tab = Tab(number: digit + 1) {
            selectTab(tab)
            return true
        }
        switch shortcut.keyCode {
        case KeyCode.comma:
            showSettings(settingsSection)
            return true
        case KeyCode.n:
            selectTab(.chat)
            chat.newChat()
            return true
        case KeyCode.period:
            // ⌘. stops a reply; Esc never does.
            guard chat.isBusy else { return false }
            chat.stop()
            return true
        default:
            return false
        }
    }

    // MARK: Toasts

    /// Shows `text` in place of the hints for 2.6 s. A new toast replaces the current one.
    public func toast(_ text: String) {
        toastWork?.cancel()
        toastText = text
        toastID += 1
        toastWork = scheduler.schedule(at: clock.now.addingTimeInterval(Self.toastDuration)) { [weak self] in
            self?.toastText = nil
            self?.toastWork = nil
        }
    }

    // MARK: Wake shortcut

    /// Registers the wake shortcut from the settings. AppModel calls it at launch.
    public func registerHotkey() {
        hotkey = hotkeys.register(settings.settings.general.shortcut) { [weak self] in
            self?.hotkeyPressed()
        }
    }

    /// Try Again, after registration failed.
    public func retryHotkey() {
        registerHotkey()
    }

    /// The recorder (slice 2) picked a new shortcut. It is saved only if it registers; otherwise
    /// the current one stays active and saved, and the returned status says why.
    @discardableResult
    public func changeShortcut(_ shortcut: Shortcut) -> HotkeyStatus {
        let status = hotkeys.register(shortcut) { [weak self] in
            self?.hotkeyPressed()
        }
        if case .ok = status {
            hotkey = status
            settings.setShortcut(shortcut)
        }
        return status
    }
}

extension HUDStore {
    /// The keyboard layout changed, or the app launched: the shell gives the wake shortcut's
    /// keycap label for the current layout, and the menu, the welcome and Settings show it.
    public func shortcutLabelChanged(_ key: String) {
        settings.updateShortcutLabel(key)
        if case .ok(let current) = hotkey, current.key != key {
            hotkey = .ok(Shortcut(keyCode: current.keyCode, modifiers: current.modifiers, key: key))
        }
    }
}

// MARK: Shortcut recorder (Settings → General → Wake shortcut, and the welcome)

extension HUDStore {
    /// The recorder field was clicked: it listens for keys, and the wake shortcut is
    /// released meanwhile, so the recorder can capture the same keys.
    public func startRecording() {
        guard !recording else { return }
        recording = true
        recorderProblem = nil
        hotkeys.suspend()
    }

    /// The × or Esc: the current shortcut stays.
    public func cancelRecording() {
        guard recording else { return }
        recording = false
        recorderProblem = nil
        hotkeys.resume()
    }

    /// Keys pressed while recording. A shortcut that can't be used keeps the recorder
    /// listening and says why (UX part 2, §13); one that registers is saved and ends it.
    public func record(_ shortcut: Shortcut) {
        guard recording else { return }
        if shortcut.keyCode == KeyNames.escape && shortcut.modifiers.isEmpty {
            cancelRecording()
            return
        }
        if let problem = shortcut.keysProblem {
            recorderProblem = Strings.Recorder.keysProblem(problem)
            return
        }
        hotkeys.resume()
        let status = changeShortcut(shortcut)
        if case .ok = status {
            recording = false
            recorderProblem = nil
        } else {
            recorderProblem = Strings.Recorder.problem(status, shortcut: shortcut)
            hotkeys.suspend()
        }
    }

    /// Reset to ⌥ Space.
    public func resetShortcut() {
        if recording {
            record(.wakeDefault)
            return
        }
        let status = changeShortcut(.wakeDefault)
        recorderProblem = Strings.Recorder.problem(status, shortcut: .wakeDefault)
    }
}

// MARK: Rows, for the view

extension HUDStore {
    /// A click on a row, or VoiceOver's press: selects it and runs it, as one intent.
    /// "No matching actions" can't be run, so it is ignored.
    public func run(rowAt index: Int) {
        let rows = suggestions
        guard rows.indices.contains(index), rows[index].isSelectable else { return }
        selectedIndex = index
        selectionChange = .pointer
        submit()
    }

    /// What VoiceOver reads for a row: "Start 25 min focus, Focus, 1 of 6", counting only
    /// the rows that can be selected. "No matching actions" reads its text alone.
    public func accessibilityLabel(forRow index: Int) -> String {
        let rows = suggestions
        guard rows.indices.contains(index) else { return "" }
        let row = rows[index]
        let selectable = rows.indices.filter { rows[$0].isSelectable }
        guard let position = selectable.firstIndex(of: index) else { return row.title }
        return Strings.Suggestions.accessibilityRow(
            title: row.title, kind: row.kindLabel, position: position + 1, count: selectable.count)
    }
}

// MARK: Auto-open

extension HUDStore {
    /// A Focus session or break ended and its prompt wants to show (Yuki, slice 3):
    /// - HUD closed: opens on `tab` without taking the keyboard, with a clean input and no
    ///   model menu, so the prompt shows as designed.
    /// - HUD open and key: the user may be typing, so it stays as it is (tab, text, focus)
    ///   and `announcement` shows as a toast, which VoiceOver reads.
    /// - HUD open but not key: switches to `tab`, keeps the text, doesn't take the keyboard.
    /// - Already on `tab`: the prompt shows in place.
    public func autoOpen(tab: Tab, announcement: String) {
        if !isOpen {
            modelMenuOpen = false
            input = ""
            selectedIndex = nil
            open(tab: tab, makeKey: false)
        } else if self.tab == tab {
            return
        } else if isKey {
            toast(announcement)
        } else {
            switchTab(to: tab)
        }
    }
}

// MARK: Settings sub-nav and the recorder's Reset

extension HUDStore {
    /// ↑ (-1) or ↓ (+1) in the Settings sub-nav, in its order. It stops at the first and last
    /// section, as a macOS sidebar does.
    public func moveSettingsSection(_ delta: Int) {
        let order = SettingsSection.groups.flatMap { $0 }
        guard let current = order.firstIndex(of: settingsSection), delta != 0 else { return }
        let next = min(max(current + delta, 0), order.count - 1)
        selectSettingsSection(order[next])
    }

    /// ↑ and ↓ move the suggestion selection only while there are suggestions. Otherwise the
    /// focused view keeps its own arrows: the Settings sub-nav (`moveSettingsSection`), a
    /// segmented control, a text field.
    public var arrowKeysMoveSelection: Bool {
        !suggestions.isEmpty
    }

    /// The recorder's ghost "Reset to ⌥ Space" shows only when the shortcut differs from the
    /// default and the recorder isn't listening.
    public var canResetShortcut: Bool {
        settings.settings.general.shortcut != .wakeDefault && !recording
    }
}
