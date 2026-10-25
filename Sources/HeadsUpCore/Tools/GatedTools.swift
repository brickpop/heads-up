import Foundation

/// Runs the tools a reply asks for (ADR-001 §8.2, §9). It runs inside the reply's task, so
/// Stop cancels it; a result that arrives after Stop isn't sent.
@MainActor
protocol ToolRunner: AnyObject {
    /// One call, through the gate. Returns the envelope the model reads (F2 c).
    func run(_ call: ToolCall, model: String) async -> String
    /// A card's button; false when it was ignored.
    func decide(_ cardID: String, _ choice: CardChoice) -> Bool
    /// Stop, New chat, a pinned load, quit: a waiting card becomes Denied.
    func denyPending()
    var hasPendingCard: Bool { get }
}

/// What the runner may do to the chat's transcript: add a tool record, change it, and say a
/// card waits. The chat implements it; the runner never holds the conversation.
@MainActor
protocol ToolDisplay: AnyObject {
    func appendRecord(_ record: ToolRecord)
    func updateRecord(_ id: String, _ change: (inout ToolRecord) -> Void)
    func record(_ id: String) -> ToolRecord?
    func awaitingApproval(_ waiting: Bool)
    /// Whether a guarded button shown at `shownAt` takes input now (ActionGuard, F6).
    func guardAllows(_ shownAt: Date) -> Bool
}

/// Something that holds the HUD open while macOS shows its own window (a permission prompt).
@MainActor
public protocol ModalPresenting: AnyObject {
    func beginModal()
    func endModal()
}

/// The gate and the four tools (ADR-001 §9): it resolves each call's permission, shows a card
/// and waits when it must ask, runs the tool, and keeps the record up to date. It owns the
/// waiting card's continuation and the permission writes from Always allow.
@MainActor
final class GatedTools: ToolRunner {
    private let settings: SettingsStore
    private let ports: ToolPorts
    private let pasteboard: Pasteboard
    private let clock: Clock
    private weak var modal: ModalPresenting?
    weak var display: ToolDisplay?

    /// The card waiting for an answer, and how to wake it.
    private var pending: (id: String, continuation: CheckedContinuation<CardChoice, Never>)?
    /// The macOS permissions already asked for in this run: only the first call of each kind
    /// may show a prompt, which takes the keyboard from the HUD.
    private var asked: Set<MacPermission> = []

    init(settings: SettingsStore, ports: ToolPorts, pasteboard: Pasteboard, clock: Clock, modal: ModalPresenting?) {
        self.settings = settings
        self.ports = ports
        self.pasteboard = pasteboard
        self.clock = clock
        self.modal = modal
    }

    var hasPendingCard: Bool { pending != nil }

    func run(_ call: ToolCall, model: String) async -> String {
        let shownName = sanitizeForDisplay(call.name, max: 64)
        guard let tool = ToolID(apiName: call.name) else {
            display?.appendRecord(
                ToolRecord(id: UUID().uuidString, callID: call.id, tool: nil, name: shownName, status: .notAvailable))
            return ToolEnvelope.make(tool: call.name, error: Strings.Tools.modelUnknown)
        }
        let id = UUID().uuidString
        let step = ToolGate.resolve(tool, permission: settings.settings.tools[tool])
        guard step != .disabled else {
            display?.appendRecord(ToolRecord(id: id, callID: call.id, tool: tool, name: shownName, status: .disabled))
            return ToolEnvelope.make(tool: tool.apiName, error: Strings.Tools.modelDisabled)
        }
        display?.appendRecord(ToolRecord(id: id, callID: call.id, tool: tool, name: shownName, status: .running))

        let prepared: PreparedCall
        do {
            prepared = try await withPrompt(tool, last: false) { () async throws(ToolFailure) -> PreparedCall in
                try await LocalTools.prepare(
                    tool, arguments: call.arguments, ports: self.ports, pasteboard: self.pasteboard,
                    now: self.clock.now, calendar: .current)
            }
        } catch {
            return fail(id, tool: tool, error)
        }
        display?.updateRecord(id) { $0.summary = prepared.summary }
        // Can't be done as asked: no card. The row says why; the model gets exactly what a Deny
        // gives it, so nothing about the user's lists leaks (Rev, Yuki).
        if let reason = prepared.notAdded {
            display?.updateRecord(id) { $0.status = .notAdded(reason) }
            return ToolEnvelope.make(tool: tool.apiName, error: Strings.Tools.modelDenied)
        }

        var allowed = ToolRecord.Status.allowedByRule
        if case .ask(let choices) = step {
            let card = PendingCard(
                tool: tool, model: sanitizeForDisplay(model, max: 64), choices: choices, preview: prepared.preview,
                fields: prepared.fields, isShared: prepared.isShared, shownAt: clock.now)
            switch await ask(id, card: card) {
            case .deny:
                display?.updateRecord(id) { $0.status = .denied }
                return ToolEnvelope.make(tool: tool.apiName, error: Strings.Tools.modelDenied)
            case .allowOnce:
                allowed = .approvedOnce
            case .alwaysAllow:
                settings.setToolPermission(tool, .allow)
                allowed = .alwaysAllowed
            }
        }

        do {
            let result = try await withPrompt(tool, last: true) { () async throws(ToolFailure) -> ToolResult in
                try await LocalTools.run(prepared, ports: self.ports)
            }
            display?.updateRecord(id) { record in
                record.status = allowed
                record.bytes = result.bytes
                record.events = result.events
            }
            return ToolEnvelope.make(tool: tool.apiName, content: result.content)
        } catch {
            return fail(id, tool: tool, error)
        }
    }

    /// A card's button. False when nothing happened: the card is gone or answered, the choice
    /// isn't offered, or the action guard ignored the press (F6): within 600 ms of the card
    /// appearing or of the HUD becoming key, or while the HUD isn't key. Enter in the prompt
    /// never reaches it.
    func decide(_ cardID: String, _ choice: CardChoice) -> Bool {
        guard let pending, pending.id == cardID, let display, let record = display.record(cardID),
            case .waiting(let card) = record.status, card.choices.contains(choice), display.guardAllows(card.shownAt)
        else { return false }
        self.pending = nil
        display.updateRecord(cardID) { $0.status = choice == .deny ? .denied : .running }
        pending.continuation.resume(returning: choice)
        return true
    }

    func denyPending() {
        guard let pending else { return }
        self.pending = nil
        display?.updateRecord(pending.id) { $0.status = .denied }
        pending.continuation.resume(returning: .deny)
    }

    // MARK: Helpers

    /// Shows the card and waits for `decide`, Stop, New chat, a pinned load or quit.
    private func ask(_ id: String, card: PendingCard) async -> CardChoice {
        // Stopped while the arguments were read: the card never shows.
        guard !Task.isCancelled, let display, display.record(id) != nil else {
            self.display?.updateRecord(id) { $0.status = .denied }
            return .deny
        }
        display.updateRecord(id) { $0.status = .waiting(card) }
        display.awaitingApproval(true)
        let choice = await withCheckedContinuation { continuation in
            pending = (id, continuation)
        }
        self.display?.awaitingApproval(false)
        return choice
    }

    /// Runs `work`, holding the HUD open while a call may still show a macOS permission prompt:
    /// it takes the keyboard, and the HUD mustn't close under it. Once a call's `last` step has
    /// reached macOS, that permission was asked, and later calls don't hold the HUD.
    private func withPrompt<T>(_ tool: ToolID, last: Bool, _ work: () async throws(ToolFailure) -> T)
        async throws(ToolFailure) -> T
    {
        guard let permission = tool.macPermission, !asked.contains(permission) else { return try await work() }
        modal?.beginModal()
        defer {
            modal?.endModal()
            if last { asked.insert(permission) }
        }
        return try await work()
    }

    private func fail(_ id: String, tool: ToolID, _ failure: ToolFailure) -> String {
        let model: String
        let status: ToolRecord.Status
        switch failure {
        case .blockedByMacOS(let permission):
            status = .blocked(permission)
            model = Strings.Tools.modelBlocked(permission)
        case .concealedClipboard:
            status = .concealed
            model = Strings.Tools.modelConcealed
        case .invalidArguments(let reason):
            status = .failed(sanitizeForDisplay(reason, max: 80))
            model = Strings.Tools.modelInvalid(reason)
        case .failed(let reason):
            status = .failed(sanitizeForDisplay(reason, max: 80))
            model = Strings.Tools.modelFailed(reason)
        }
        display?.updateRecord(id) { $0.status = status }
        return ToolEnvelope.make(tool: tool.apiName, error: model)
    }
}

extension ToolID {
    /// The macOS permission the tool needs, if any.
    var macPermission: MacPermission? {
        switch self {
        case .calendar: .calendar
        case .remindersRead, .remindersCreate: .reminders
        case .clipboard: nil
        }
    }
}
