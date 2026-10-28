import Foundation
import Observation

/// A tool a reply asks for.
public struct ToolCall: Equatable, Sendable {
    public let id: String
    public let name: String
    /// The JSON arguments, as the model sent them.
    public let arguments: Data
}

/// `{"tool": "calendar_events", "untrusted_content": …}`: how every tool result reaches the
/// model, never as bare text (F2 c).
enum ToolEnvelope {
    static func make(tool: String, content: String) -> String {
        let object: [String: Any] = ["tool": tool, "untrusted_content": content]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// The chat (ADR-001 §8.2; Chat spec; UX part 1, §4–5): the conversation, the reply as it
/// streams, Stop, the error rows and their recovery, and the link ask.
///
/// It sends the whole conversation to the active model. A reply's text reaches the view at most
/// 30 times a second. A reply that asks for tools runs them and asks again, 8 times at most,
/// then stops with a row offering Continue. ⌘. and Stop keep the text so far; Esc and closing
/// the HUD never stop a reply.
@MainActor
@Observable
public final class ChatStore: HUDChat {
    public enum Phase: Equatable, Sendable {
        case idle
        /// Sent; no text yet: "Thinking with GPT-4o mini…".
        case waiting
        case streaming
        /// A tool call waits on its approval card.
        case awaitingApproval
    }

    public internal(set) var items: [ChatItem] = []
    public internal(set) var phase: Phase = .idle
    /// "Open this link?", waiting for an answer.
    public private(set) var pendingLink: PendingLink?

    /// The images waiting to be sent with the next message, in the order attached
    /// (ChatAttachments.swift).
    var pending: [Attachment] = []
    /// Images still being read: they count towards the 5.
    var processing = 0
    /// Why images weren't added, until the ×, a removed image or the next message.
    var attachmentProblem: AttachmentProblem?
    /// The conversation's images, by id: sent with their message, kept in a pin.
    var images: [String: ProcessedImage] = [:]

    /// The pinned chat this conversation is linked to, if any (ChatPins.swift).
    var pin: PinLink?
    /// A pin, save or unpin that failed, until the next success (ChatPins.swift).
    var pinProblem: PinProblem?
    /// The 240 × 160 thumbnails of the conversation's images, by id.
    var previews: [String: Data] = [:]

    /// How many times a reply may ask for tools before the step-limit row.
    static let maxSteps = 8
    /// The view hears about new text at most this often.
    static let flushInterval: TimeInterval = 1.0 / 30
    /// After Start on a row, the port is tried this often, for this long.
    static let startCheckInterval: TimeInterval = 1
    static let startTimeout: TimeInterval = 30

    @ObservationIgnored let endpoints: EndpointService
    @ObservationIgnored private let provider: LLMProvider
    @ObservationIgnored let settings: SettingsStore
    /// The gate and the tools (Tools/GatedTools.swift).
    @ObservationIgnored let tools: ToolRunner
    /// The catalogue, for suggested actions (ChatSuggestions.swift).
    @ObservationIgnored let actions: ActionResolving
    /// A suggested action waiting for its confirm.
    var pendingSuggestion: PendingSuggestion?
    /// When each reply's suggested buttons appeared, for the action guard.
    @ObservationIgnored var suggestionsShownAt: [ChatMessage.ID: Date] = [:]
    @ObservationIgnored let clock: Clock
    @ObservationIgnored let scheduler: Scheduler
    @ObservationIgnored private let ports: PortProbe
    @ObservationIgnored private let links: LinkOpener
    @ObservationIgnored let pasteboard: Pasteboard
    @ObservationIgnored let imageProcessor: ImageProcessor
    @ObservationIgnored let pins: PinSaving
    /// When the pin was last written, and the write waiting for the 500 ms to pass.
    /// How many chats are pinned, for "Pinned · N". AppModel points it at the pins store.
    @ObservationIgnored var pinCount: @MainActor () -> Int = { 0 }
    @ObservationIgnored var lastPinSave: Date?
    @ObservationIgnored var pinSave: ScheduledWork?
    @ObservationIgnored weak var toaster: Toaster?
    /// When a guarded button shown at `shownAt` starts taking input, or nil while the HUD isn't
    /// key (`ActionGuard`, F6, S2). AppModel sets it.
    @ObservationIgnored var armedAt: @MainActor (_ shownAt: Date) -> Date? = { $0 }

    /// Whether a guarded button shown at `shownAt` takes input now.
    func guardAllows(_ shownAt: Date) -> Bool {
        armedAt(shownAt).map { clock.now >= $0 } ?? false
    }

    /// The reply being written, and the run it belongs to: a stopped or replaced run leaves
    /// everything alone.
    @ObservationIgnored private var run: UUID?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var pendingText = ""
    @ObservationIgnored private var flush: ScheduledWork?
    @ObservationIgnored private var startWait: ScheduledWork?
    /// Parsed replies: one incremental parser per reply while it streams, then the whole text
    /// parsed once.
    @ObservationIgnored private var streamingParsers: [ChatMessage.ID: ReplyParser] = [:]
    @ObservationIgnored private var parsed: [ChatMessage.ID: (text: String, blocks: [Block])] = [:]

    init(
        endpoints: EndpointService, settings: SettingsStore, provider: LLMProvider, tools: ToolRunner,
        actions: ActionResolving, clock: Clock,
        scheduler: Scheduler, ports: PortProbe, links: LinkOpener, pasteboard: Pasteboard,
        imageProcessor: ImageProcessor,
        pins: PinSaving, toaster: Toaster
    ) {
        self.endpoints = endpoints
        self.provider = provider
        self.settings = settings
        self.tools = tools
        self.actions = actions
        self.clock = clock
        self.scheduler = scheduler
        self.ports = ports
        self.links = links
        self.pasteboard = pasteboard
        self.imageProcessor = imageProcessor
        self.pins = pins
        self.toaster = toaster
    }

    // MARK: HUDChat

    public var askTarget: AskTarget { endpoints.active.map { .model(name: $0.name) } ?? .noModel }
    public var hasMessages: Bool { !items.isEmpty }
    public var isBusy: Bool { phase != .idle }
    public var hasAttachments: Bool { !pending.isEmpty }
    /// Images are attached and the model can't see them: Enter doesn't send (UX part 1, §6).
    public var isSendBlocked: Bool { !pending.isEmpty && endpoints.active?.images != true }

    // MARK: Sending

    /// Enter, or Ask <model>, with the images attached; a message may be images only. Nothing
    /// happens while a reply is coming (Enter waits), or while the model can't see the images.
    public func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isBusy, !text.isEmpty || !pending.isEmpty else { return }
        guard !isSendBlocked else { return }
        supersedeRows()
        pendingLink = nil
        pendingSuggestion = nil
        for attachment in pending {
            images[attachment.id] = attachment.image
            previews[attachment.id] = attachment.image.preview
        }
        items.append(.message(ChatMessage(role: .user, text: text, imageIDs: pending.map(\.id))))
        pending = []
        attachmentProblem = nil
        guard let endpoint = endpoints.active else {
            items.append(.problem(Problem(kind: .noEndpoint, shownAt: clock.now)))
            savePin()
            return
        }
        start(endpoint, steps: Self.maxSteps)
        savePin()
    }

    /// ⌘. or Stop: the reply keeps its text and ends with "Stopped".
    public func stop() {
        guard isBusy else { return }
        cancelRun()
        flushText()
        updateReply { $0.state = .stopped }
        phase = .idle
        suggestionsSettled()
        savePin()
    }

    /// ⌘N: stops, then forgets the conversation and the images waiting to be sent. A pinned
    /// chat stays pinned; this one is no longer linked to it.
    public func newChat() {
        stop()
        clearConversation()
    }

    /// Forgets the conversation, its images and its link to a pin.
    func clearConversation() {
        cancelRun()
        startWait?.cancel()
        pinSave?.cancel()
        pinSave = nil
        items = []
        images = [:]
        previews = [:]
        pinProblem = nil
        pending = []
        attachmentProblem = nil
        pin = nil
        pendingLink = nil
        pendingSuggestion = nil
        suggestionsShownAt = [:]
        streamingParsers = [:]
        parsed = [:]
    }

    /// A reply's blocks: parsed as it grows while it streams, and whole once it is done.
    func blocks(_ message: ChatMessage) -> [Block] {
        if message.state == .streaming {
            var parser = streamingParsers[message.id] ?? ReplyParser()
            let blocks = parser.blocks(message.text)
            streamingParsers[message.id] = parser
            return blocks
        }
        streamingParsers[message.id] = nil
        if let cached = parsed[message.id], cached.text == message.text { return cached.blocks }
        let blocks = MarkdownBlocks.parse(message.text)
        parsed[message.id] = (message.text, blocks)
        return blocks
    }

    /// Try again: what came after the last thing the user wrote goes, and it is sent again.
    func retry() {
        guard !isBusy,
            let lastUser = items.lastIndex(where: { if case .message(let m) = $0 { m.role == .user } else { false } })
        else { return }
        startWait?.cancel()
        pendingLink = nil
        items.removeSubrange(items.index(after: lastUser)...)
        guard let endpoint = endpoints.active else {
            items.append(.problem(Problem(kind: .noEndpoint, shownAt: clock.now)))
            return
        }
        start(endpoint, steps: Self.maxSteps)
    }

    /// Continue, on the step-limit row: 8 more steps. False when the F6 guard ignored it.
    func continueAfterLimit(_ rowID: Problem.ID) -> Bool {
        guard !isBusy, let index = problemIndex(rowID), case .problem(var row) = items[index],
            case .stepLimit(let steps, let endpointID, false) = row.kind, !row.isSuperseded
        else { return false }
        guard guardAllows(row.shownAt) else { return false }
        row.kind = .stepLimit(steps: steps, endpointID: endpointID, continued: true)
        items[index] = .problem(row)
        guard let endpoint = endpoints.endpoint(endpointID) ?? endpoints.active else { return true }
        start(endpoint, steps: Self.maxSteps)
        return true
    }

    // MARK: The engine

    private func start(_ endpoint: Endpoint, steps: Int) {
        cancelRun()
        let id = UUID()
        run = id
        // Busy at once, so Enter waits from the moment it is sent.
        phase = .waiting
        task = Task { await self.loop(endpoint, steps: steps, run: id) }
    }

    private func cancelRun() {
        run = nil
        tools.denyPending()
        task?.cancel()
        task = nil
        flush?.cancel()
        flush = nil
    }

    private func loop(_ endpoint: Endpoint, steps: Int, run id: UUID) async {
        for step in 1...steps {
            let reply = ChatMessage(role: .assistant, text: "", state: .streaming, model: endpoint.name)
            let context = conversation(for: endpoint)
            items.append(.message(reply))
            phase = .waiting
            var calls: [ToolCall] = []
            var reason = StopReason.stop
            do {
                for try await event in provider.stream(
                    endpoint: endpoint, messages: context, tools: offeredTools(endpoint))
                {
                    guard run == id else { return }
                    switch event {
                    case .text(let text):
                        phase = .streaming
                        pendingText += text
                        scheduleFlush()
                    case .toolCall(let callID, let name, let arguments):
                        calls.append(ToolCall(id: callID, name: name, arguments: arguments))
                    case .finished(let stopReason, _):
                        reason = stopReason
                    }
                }
            } catch {
                guard run == id else { return }
                flushText()
                failed(error as? ChatError ?? .badResponse, endpoint: endpoint)
                return
            }
            guard run == id else { return }
            flushText()
            guard reason == .toolCalls, !calls.isEmpty else {
                updateReply { $0.state = .done }
                finishRun()
                return
            }
            updateReply { reply in
                reply.state = .done
                reply.toolCalls = calls.map {
                    LLMMessage.ToolCall(
                        id: $0.id, name: $0.name, arguments: String(decoding: $0.arguments, as: UTF8.self))
                }
            }
            for call in calls {
                let envelope =
                    call.name == SuggestTool.name
                    ? acceptSuggestions(call, on: reply.id) : await tools.run(call, model: endpoint.name)
                guard run == id, !Task.isCancelled else { return }
                items.append(.toolResult(id: UUID().uuidString, callID: call.id, envelope: envelope))
            }
            // A finished step is kept at once in a pinned chat.
            savePin()
            if step == steps {
                items.append(
                    .problem(
                        Problem(
                            kind: .stepLimit(steps: steps, endpointID: endpoint.id, continued: false),
                            shownAt: clock.now)))
                finishRun()
                return
            }
        }
    }

    /// A request failed: the text so far stays, and the error row goes under it.
    private func failed(_ error: ChatError, endpoint: Endpoint) {
        if let reply = currentReply, reply.text.isEmpty {
            items.removeAll { $0.id == reply.id }
        } else {
            updateReply { $0.state = .done }
        }
        items.append(.problem(Problem(kind: .error(error, endpointID: endpoint.id), shownAt: clock.now)))
        finishRun()
    }

    private func finishRun() {
        run = nil
        task = nil
        phase = .idle
        suggestionsSettled()
        savePin()
    }

    /// The system prompt, then every message, with tool calls and their results, as the model
    /// reads them. Rows and the reply being written aren't sent. Only the newest user message
    /// sends its images, and only to a model that sees images; any other image is sent as
    /// "[image omitted]" (ADR-001 §8.2).
    private func conversation(for endpoint: Endpoint) -> [LLMMessage] {
        var messages = [
            LLMMessage.text(
                .system,
                SystemPrompt.v1(
                    now: clock.now, timeZone: .current, locale: .current, tools: offeredToolIDs(endpoint),
                    suggests: offersSuggestions(endpoint)))
        ]
        let newestUser = items.last { if case .message(let m) = $0 { m.role == .user } else { false } }?.id
        for item in items {
            switch item {
            case .message(let message) where message.role == .tool:
                // A kept tool row is display only: its result was never kept.
                continue
            case .message(let message) where message.role == .user:
                guard !message.imageIDs.isEmpty else {
                    messages.append(.text(.user, message.text))
                    continue
                }
                let sent = message.id == newestUser && endpoint.images ? message.imageIDs.compactMap { images[$0] } : []
                if sent.isEmpty {
                    let omitted = Array(repeating: Strings.Chat.imageOmitted, count: message.imageIDs.count)
                    let text = ([message.text] + omitted).filter { !$0.isEmpty }.joined(separator: "\n")
                    messages.append(.text(.user, text))
                } else {
                    let text: [LLMMessage.Part] = message.text.isEmpty ? [] : [.text(message.text)]
                    messages.append(LLMMessage(role: .user, parts: text + sent.map { .imageDataURL($0.dataURL) }))
                }
            case .message(let message) where message.state != .streaming:
                guard !message.text.isEmpty || !message.toolCalls.isEmpty else { continue }
                messages.append(
                    LLMMessage(role: .assistant, parts: [.text(message.text)], toolCalls: message.toolCalls))
            case .toolResult(_, let callID, let envelope):
                messages.append(LLMMessage(role: .tool, parts: [.text(envelope)], toolCallID: callID))
            default:
                continue
            }
        }
        return messages
    }

    private var currentReply: ChatMessage? {
        guard
            case .message(let message)? = items.last(where: {
                if case .message(let m) = $0 { m.role == .assistant } else { false }
            }),
            message.state == .streaming
        else { return nil }
        return message
    }

    private func updateReply(_ change: (inout ChatMessage) -> Void) {
        guard let reply = currentReply, let index = items.firstIndex(where: { $0.id == reply.id }),
            case .message(var message) = items[index]
        else { return }
        change(&message)
        items[index] = .message(message)
    }

    private func scheduleFlush() {
        guard flush == nil else { return }
        flush = scheduler.schedule(at: clock.now.addingTimeInterval(Self.flushInterval)) { [weak self] in
            self?.flush = nil
            self?.flushText()
        }
    }

    private func flushText() {
        flush?.cancel()
        flush = nil
        guard !pendingText.isEmpty else { return }
        let text = pendingText
        pendingText = ""
        updateReply { $0.text += text }
        savePinSoon()
    }

    /// A new message takes the buttons off the rows before it.
    private func supersedeRows() {
        startWait?.cancel()
        items = items.map { item in
            guard case .problem(var row) = item else { return item }
            row.isSuperseded = true
            row.starting = nil
            return .problem(row)
        }
    }

    func problemIndex(_ id: Problem.ID) -> Int? {
        items.firstIndex { $0.id == id }
    }

    func problem(_ id: Problem.ID) -> Problem? {
        guard let index = problemIndex(id), case .problem(let row) = items[index] else { return nil }
        return row
    }

    // MARK: Start, then try again

    /// After Start on a "not running" row: "Starting Ollama…" while `port` is tried each
    /// second. When it answers, the message is sent again; after 30 s the row offers Try again.
    func waitForServer(_ rowID: Problem.ID, service: String, port: Int) {
        guard let index = problemIndex(rowID), case .problem(var row) = items[index] else { return }
        startWait?.cancel()
        row.starting = Strings.Chat.starting(service)
        items[index] = .problem(row)
        checkServer(rowID, port: port, deadline: clock.now.addingTimeInterval(Self.startTimeout))
    }

    private func checkServer(_ rowID: Problem.ID, port: Int, deadline: Date) {
        startWait = scheduler.schedule(at: clock.now.addingTimeInterval(Self.startCheckInterval)) { [weak self] in
            guard let self, self.problem(rowID)?.starting != nil else { return }
            Task { @MainActor in
                let answers = await self.ports.answers(port: port)
                guard let index = self.problemIndex(rowID), case .problem(var row) = self.items[index],
                    row.starting != nil
                else { return }
                if answers {
                    self.retry()
                } else if self.clock.now >= deadline {
                    row.starting = nil
                    self.items[index] = .problem(row)
                } else {
                    self.checkServer(rowID, port: port, deadline: deadline)
                }
            }
        }
    }

    // MARK: Links

    /// A click on a link. A long one, one with a query or fragment, or one to a host the user
    /// never wrote asks first (F2); the others open at once.
    public func openLink(_ id: LinkID) {
        guard let url = destination(id), let opened = LinkPolicy.url(url) else { return }
        let userText = items.compactMap { item -> String? in
            if case .message(let message) = item, message.role == .user { return message.text }
            return nil
        }
        // It asks too when what the URL opens isn't the host shown (F2).
        if LinkPolicy.asksFirst(url, userMessages: userText) || !LinkPolicy.opensShownHost(url) {
            pendingLink = PendingLink(link: id, url: url, shownAt: clock.now)
        } else {
            links.open(opened)
        }
    }

    public enum LinkChoice: Sendable {
        case cancel, copy, open
    }

    /// The link ask's buttons. False when the F6 guard ignored the press: within 600 ms of the
    /// ask appearing, or while the HUD isn't key (S2).
    @discardableResult
    public func confirmLink(_ choice: LinkChoice) -> Bool {
        guard let pending = pendingLink else { return false }
        guard guardAllows(pending.shownAt) else { return false }
        pendingLink = nil
        switch choice {
        case .cancel: break
        case .copy: if let url = LinkPolicy.url(pending.url) { copy(url.absoluteString) }
        case .open: if let url = LinkPolicy.url(pending.url) { links.open(url) }
        }
        return true
    }

    /// The URL of a link, found again in its message's Markdown.
    private func destination(_ id: LinkID) -> String? {
        guard let destinations = rendered(id.messageID)?.destinations, destinations.indices.contains(id.index) else {
            return nil
        }
        return destinations[id.index]
    }

    func message(_ id: ChatMessage.ID) -> ChatMessage? {
        for item in items {
            if case .message(let message) = item, message.id == id { return message }
        }
        return nil
    }

    // MARK: Copying

    /// A code card's Copy.
    public func copyCode(_ blockID: CodeBlockID) {
        guard let codes = rendered(blockID.messageID)?.codes, codes.indices.contains(blockID.index) else { return }
        copy(codes[blockID.index])
    }

    /// A message's context menu: Copy, or Copy as Markdown.
    public func copyMessage(_ id: ChatMessage.ID, asMarkdown: Bool) {
        guard let message = message(id) else { return }
        copy(asMarkdown ? message.text : MarkdownBlocks.parse(message.text).map(\.plainText).joined(separator: "\n\n"))
    }

    /// Every copy keeps only tabs and line breaks of the control characters (Scan L1), so a
    /// reply can't put an escape sequence on the clipboard for a terminal to run.
    private func copy(_ text: String) {
        pasteboard.copy(stripControls(text))
        toaster?.toast(Strings.Chat.copied)
    }
}

#if DEBUG
    extension ChatStore {
        /// For SwiftUI previews: a finished conversation with a code block, a link that asks
        /// first, and an error row, without streaming.
        public func showPreviewConversation() {
            let reply = ChatMessage(
                role: .assistant,
                text: """
                    You have **4 events** today. Your longest free block is **14:00–16:30**.

                    - Standup at 9:30
                    - Design review at 11:00

                    ```sh
                    lsof -ti :3000 | xargs kill
                    ```

                    [Join the meeting](https://meet.example.com/j?id=42)
                    """, model: "GPT-4o mini")
            items = [
                .message(ChatMessage(role: .user, text: "What's on today?")), .message(reply),
                .message(ChatMessage(role: .user, text: "And tomorrow?")),
                .problem(Problem(kind: .error(.offline, endpointID: endpoints.activeID ?? ""), shownAt: clock.now)),
            ]
            pendingLink = PendingLink(
                link: LinkID(messageID: reply.id, index: 0), url: "https://meet.example.com/j?id=42", shownAt: clock.now
            )
        }
    }
#endif

/// A code block in a reply, by its place: the message, and its index among that message's code blocks.
public struct CodeBlockID: Hashable, Sendable {
    let messageID: ChatMessage.ID
    let index: Int
}
