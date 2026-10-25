import Foundation
import Observation

/// The endpoint form's fields as the user types them, the token included. The token lives
/// only here, in memory, until Save puts it in the Keychain; it is never printed.
public struct EndpointDraft: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var name = ""
    public var modelID = ""
    public var baseURL = ""
    /// A token typed to add or replace the saved one; empty keeps the saved one.
    public var token = ""
    public var imagesOn = false
    public var toolsOn = true
    public var serviceID: ServiceDefinition.ID?
    /// Remove token was pressed: Save deletes the saved token, Cancel keeps it.
    public var removeToken = false

    public init() {}

    init(_ endpoint: Endpoint) {
        name = endpoint.name
        modelID = endpoint.model == Endpoint.defaultModel ? "" : endpoint.model
        baseURL = endpoint.baseURL
        imagesOn = endpoint.images
        toolsOn = endpoint.tools
        serviceID = endpoint.serviceID
    }

    /// Never shows the token, so logs and test output can't leak it.
    public var description: String {
        "EndpointDraft(name: \(name), modelID: \(modelID), baseURL: \(baseURL), token: \(token.isEmpty ? "none" : "••••"))"
    }

    public var debugDescription: String { description }
}

/// Quick add's choices (UX part 1, §2): each fills the form, leaving the model id empty.
public enum QuickAddKind: Hashable, CaseIterable, Sendable {
    case openAI, ollama, lmStudio, other
}

/// What Test connection found (UX part 1, §2).
public enum TestResult: Equatable, Sendable {
    case testing
    case ok(model: String, seconds: Double)
    /// Connected; the model id is empty or not on the server, and the server lists these.
    case chooseModel([String])
    /// Connected, but the server doesn't list its models and doesn't know this one.
    case modelNotOnServer(String)
    case needsToken
    case badToken(status: Int)
    /// Nothing answered. `service` can be started from here.
    case unreachable(hostPort: String, service: ServiceDefinition.ID?)
    /// "Start Ollama" was pressed: the test runs again by itself once the port answers.
    case starting(service: ServiceDefinition.ID, name: String)
    /// The service didn't answer within 30 s of Start.
    case startTimedOut(service: ServiceDefinition.ID, name: String)
    /// `withToken`: a token was sent with the request that was redirected.
    case redirected(host: String, withToken: Bool)
    /// Any other error status, with the server's message, secrets masked.
    case server(status: Int, details: String)
    /// The keychain refused to give the saved token, so nothing was sent. Try Again asks again.
    case keychainDenied
}

/// The question in the form's bottom bar: "Send your saved token to <host>?" (F7).
public struct TokenHostQuestion: Equatable, Sendable {
    public let host: String
    /// What runs once it is answered.
    let then: Action

    enum Action: Equatable, Sendable {
        case save, test
    }
}

/// The form in Settings → Models: always there, adding a new endpoint or editing one.
public struct EndpointForm: Equatable, Sendable {
    /// The endpoint being edited; nil while adding.
    public let editing: Endpoint.ID?
    public internal(set) var draft: EndpointDraft
    public internal(set) var result: TestResult?
    /// Waiting for the answer to "Send your saved token to <host>?" before Save or Test (F7).
    public internal(set) var tokenHostQuestion: TokenHostQuestion?
    /// Under the API token field: the keychain wouldn't save or remove the token.
    public internal(set) var tokenProblem: String?
    /// The answer given for the draft's current origin. It holds for the rest of this edit, and
    /// goes when the URL changes.
    var tokenHostAnswer: (origin: Origin, keep: Bool)?

    init(editing: Endpoint.ID? = nil, draft: EndpointDraft = EndpointDraft()) {
        self.editing = editing
        self.draft = draft
    }

    public static func == (lhs: EndpointForm, rhs: EndpointForm) -> Bool {
        lhs.editing == rhs.editing && lhs.draft == rhs.draft && lhs.result == rhs.result
            && lhs.tokenHostQuestion == rhs.tokenHostQuestion && lhs.tokenProblem == rhs.tokenProblem
            && lhs.tokenHostAnswer?.origin == rhs.tokenHostAnswer?.origin
            && lhs.tokenHostAnswer?.keep == rhs.tokenHostAnswer?.keep
    }
}

/// The models to chat with (ADR-001 §8; Model endpoints spec): the endpoints in settings.json,
/// which one chats now, the form, Test connection, and whether local servers run.
///
/// It writes settings.json only through `SettingsStore` and keeps tokens in the `SecretStore`.
/// The active model lives in memory: at each launch it is the default again.
@MainActor
@Observable
public final class EndpointService {
    /// The model chat uses now; nil with no endpoints.
    public private(set) var activeID: Endpoint.ID?
    public private(set) var form = EndpointForm()
    /// The row asking "Remove GPT-4o mini? Its token is deleted from the Keychain."
    public private(set) var removing: Endpoint.ID?
    /// A removed endpoint whose token the keychain kept: the note under the list offers Try Again.
    public private(set) var leftoverToken: Endpoint.ID?
    /// Local endpoints and quick-add ports whose server answered, by port, as last probed.
    public private(set) var answeringPorts: Set<Int> = []
    /// Ports probed at least once, so "not running" isn't shown before the first probe.
    private var probedPorts: Set<Int> = []

    @ObservationIgnored let settings: SettingsStore
    @ObservationIgnored private let secrets: SecretStore
    @ObservationIgnored let transport: HTTPTransport
    @ObservationIgnored private let ports: PortProbe
    @ObservationIgnored private let services: ServiceStore
    @ObservationIgnored private let clock: Clock
    @ObservationIgnored private let scheduler: Scheduler
    @ObservationIgnored private weak var toaster: Toaster?
    @ObservationIgnored private var testTask: Task<Void, Never>?
    /// The checks while a started service comes up; cancelled when the form changes.
    @ObservationIgnored private var startWait: ScheduledWork?

    /// Test connection waits this long for the server, apart from chat's 60 s.
    static let testTimeout: TimeInterval = 10
    /// After Start, the port is tried this often, for this long.
    static let startCheckInterval: TimeInterval = 1
    static let startTimeout: TimeInterval = 30

    public init(
        settings: SettingsStore, secrets: SecretStore, transport: HTTPTransport, ports: PortProbe,
        services: ServiceStore, clock: Clock, scheduler: Scheduler, toaster: Toaster
    ) {
        self.settings = settings
        self.secrets = secrets
        self.transport = transport
        self.ports = ports
        self.services = services
        self.clock = clock
        self.scheduler = scheduler
        self.toaster = toaster
        activeID = settings.settings.defaultEndpointID ?? settings.settings.endpoints.first?.id
    }

    // MARK: State

    public var endpoints: [Endpoint] { settings.settings.endpoints }
    public var defaultID: Endpoint.ID? { settings.settings.defaultEndpointID }
    public var active: Endpoint? { endpoints.first { $0.id == activeID } }

    public func endpoint(_ id: Endpoint.ID) -> Endpoint? { endpoints.first { $0.id == id } }

    /// The draft's token, for the secure field's getter only: never in a screen model.
    public var draftToken: String { form.draft.token }

    /// Whether a local endpoint's server answered when last probed; nil before a probe.
    public func isRunning(_ endpoint: Endpoint) -> Bool? {
        guard endpoint.tag.isLocal, let port = Self.port(endpoint.baseURL) else { return nil }
        guard probedPorts.contains(port) else { return nil }
        return answeringPorts.contains(port)
    }

    // MARK: Endpoints

    /// The radio: the default model, which also becomes the active one.
    public func setDefault(_ id: Endpoint.ID) {
        guard endpoint(id) != nil else { return }
        settings.update { $0.defaultEndpointID = id }
        activeID = id
    }

    /// Picking a model in the menu (`AppModel.selectModel`); it doesn't change the default.
    func setActive(_ id: Endpoint.ID) {
        guard endpoint(id) != nil else { return }
        activeID = id
    }

    /// The row's ×. An endpoint with a saved token asks first (`confirmRemoveEndpoint`); one
    /// without is removed at once.
    public func removeEndpoint(_ id: Endpoint.ID) {
        guard let endpoint = endpoint(id) else { return }
        if endpoint.hasToken {
            removing = id
        } else {
            remove(endpoint)
        }
    }

    /// Remove, on the row's question: the endpoint and its token go. If the keychain keeps
    /// the token, the endpoint goes anyway and the note under the list offers Try Again (Yuki).
    public func confirmRemoveEndpoint() {
        guard let id = removing, let endpoint = endpoint(id) else { return }
        do {
            try secrets.removeToken(for: id)
            leftoverToken = nil
        } catch {
            leftoverToken = id
        }
        remove(endpoint)
    }

    /// Try Again, on the note under the list: deletes the removed endpoint's token again.
    public func retryTokenDelete() {
        guard let id = leftoverToken else { return }
        do {
            try secrets.removeToken(for: id)
            leftoverToken = nil
        } catch {
            leftoverToken = id
        }
    }

    /// Cancel, on the row's question.
    public func cancelRemoveEndpoint() {
        removing = nil
    }

    /// The default and active roles pass to the first endpoint left. The last can be removed.
    private func remove(_ removed: Endpoint) {
        let id = removed.id
        settings.update { settings in
            settings.endpoints.removeAll { $0.id == id }
            if settings.defaultEndpointID == id { settings.defaultEndpointID = settings.endpoints.first?.id }
        }
        if activeID == id { activeID = defaultID ?? endpoints.first?.id }
        if form.editing == id { resetForm() }
        removing = nil
        toaster?.toast(Strings.Models.removed(removed.name))
    }

    // MARK: The form

    /// Any change to the draft. A new URL clears the result and the token-host answer, and a
    /// URL on this Mac picks the service on its port.
    public func updateDraft(_ edit: (inout EndpointDraft) -> Void) {
        let before = form.draft
        edit(&form.draft)
        if form.draft.baseURL != before.baseURL {
            form.result = nil
            form.tokenHostQuestion = nil
            form.tokenHostAnswer = nil
            startWait?.cancel()
            if form.draft.serviceID == nil { form.draft.serviceID = matchingService(form.draft.baseURL)?.id }
        }
        if form.draft.token != before.token {
            form.tokenHostQuestion = nil
            form.tokenProblem = nil
        }
    }

    /// Quick add: fills the form for a new endpoint, the model id left empty for Test connection
    /// to fill (Rev 9b).
    public func quickAdd(_ kind: QuickAddKind) {
        var draft = EndpointDraft()
        switch kind {
        case .openAI:
            draft.name = "OpenAI"
            draft.baseURL = "https://api.openai.com/v1"
            draft.imagesOn = true
        case .ollama:
            draft.name = "Ollama"
            draft.baseURL = "http://localhost:11434/v1"
        case .lmStudio:
            draft.name = "LM Studio"
            draft.baseURL = "http://localhost:1234/v1"
        case .other:
            break
        }
        draft.serviceID = matchingService(draft.baseURL)?.id
        resetForm(EndpointForm(editing: nil, draft: draft))
    }

    /// A row's click, or Edit…: the form loads that endpoint.
    public func editEndpoint(_ id: Endpoint.ID) {
        guard let endpoint = endpoint(id) else { return }
        resetForm(EndpointForm(editing: id, draft: EndpointDraft(endpoint)))
    }

    /// Cancel, while editing: nothing is kept, a token marked for removal included, and the form
    /// goes back to adding, empty.
    public func cancelForm() {
        resetForm()
    }

    /// Esc on the token-host question: it closes, and nothing is tested or saved.
    public func dismissTokenHostQuestion() {
        form.tokenHostQuestion = nil
    }

    /// Whether Add or Save can be pressed: a name, and a URL HeadsUp may use.
    public var canSave: Bool {
        !form.draft.name.trimmingCharacters(in: .whitespaces).isEmpty
            && EndpointURLPolicy.classify(form.draft.baseURL) != .rejected
    }

    /// Add endpoint or Save. An edited origin with a saved token asks first (F7);
    /// `answerTokenHost` then saves.
    public func saveForm() {
        guard canSave else { return }
        if askTokenHostFirst(then: .save) { return }
        save(keepSavedToken: form.tokenHostAnswer?.keep ?? true)
    }

    /// The token-host question: Keep token, or Remove token. The answer holds for this origin
    /// for the rest of the edit, and the Save or Test that asked goes on with it.
    public func answerTokenHost(keep: Bool) {
        guard let question = form.tokenHostQuestion, let origin = Origin(form.draft.baseURL) else { return }
        form.tokenHostQuestion = nil
        form.tokenHostAnswer = (origin, keep)
        switch question.then {
        case .save: save(keepSavedToken: keep)
        case .test: testConnection()
        }
    }

    /// Remove token, while editing: marks it; Save deletes it, Cancel keeps it.
    public func removeToken() {
        guard let id = form.editing, endpoint(id)?.hasToken == true else { return }
        form.draft.removeToken = true
        form.draft.token = ""
    }

    /// Keep Token, after Remove token: the saved token stays.
    public func keepToken() {
        form.draft.removeToken = false
    }

    /// A model from the list Test connection found: it fills Model id.
    public func pickModel(_ id: String) {
        form.draft.modelID = id
        form.result = nil
    }

    /// Whether Save or Test must ask "Send your saved token to <host>?" first: the endpoint has a
    /// saved token, no new one is typed, its removal isn't asked, the draft's origin (scheme,
    /// host and port) is another, and that origin has no answer yet. Asks if so.
    private func askTokenHostFirst(then action: TokenHostQuestion.Action) -> Bool {
        guard let id = form.editing, let saved = endpoint(id), saved.hasToken, form.draft.token.isEmpty,
            !form.draft.removeToken, let draftOrigin = Origin(form.draft.baseURL),
            Origin(saved.baseURL) != draftOrigin, form.tokenHostAnswer?.origin != draftOrigin
        else { return false }
        form.tokenHostQuestion = TokenHostQuestion(host: draftOrigin.host, then: action)
        return true
    }

    private func save(keepSavedToken: Bool) {
        let draft = form.draft
        let policy = EndpointURLPolicy.classify(draft.baseURL)
        let id = form.editing ?? UUID().uuidString
        let previous = endpoint(id)
        let hadToken = previous?.hasToken == true
        var hasToken = hadToken
        form.tokenProblem = nil
        // The token first: nothing is saved without it, so the endpoint never silently has none.
        if !policy.allowsToken || draft.removeToken || !keepSavedToken {
            // A private address over http never keeps a token (F9).
            if hadToken {
                do {
                    try secrets.removeToken(for: id)
                } catch {
                    form.tokenProblem = Strings.EndpointForm.removeFailed
                    return
                }
            }
            hasToken = false
        }
        if policy.allowsToken && !draft.token.isEmpty {
            do {
                try secrets.setToken(draft.token, for: id)
                hasToken = true
            } catch {
                form.tokenProblem = Strings.EndpointForm.keychainFailed
                return
            }
        }
        let model = draft.modelID.trimmingCharacters(in: .whitespaces)
        let endpoint = Endpoint(
            id: id, name: draft.name.trimmingCharacters(in: .whitespaces),
            baseURL: draft.baseURL.trimmingCharacters(in: .whitespaces),
            model: model.isEmpty ? Endpoint.defaultModel : model, images: draft.imagesOn, tools: draft.toolsOn,
            hasToken: hasToken, serviceID: draft.serviceID)
        let isFirst = endpoints.isEmpty
        settings.update { settings in
            if let index = settings.endpoints.firstIndex(where: { $0.id == id }) {
                settings.endpoints[index] = endpoint
            } else {
                settings.endpoints.append(endpoint)
            }
            if settings.defaultEndpointID == nil { settings.defaultEndpointID = id }
        }
        // The first endpoint added becomes the default and the active model.
        if isFirst || activeID == nil { activeID = id }
        resetForm()
        toaster?.toast(previous == nil ? Strings.Models.added(endpoint.name) : Strings.Models.saved(endpoint.name))
    }

    private func resetForm(_ next: EndpointForm = EndpointForm()) {
        testTask?.cancel()
        startWait?.cancel()
        form = next
    }

    // MARK: Test connection

    /// `GET <base>/models`, then a one-token message when a model id is set. Through the
    /// transport, so the token goes only where the URL policy allows (S3), and a saved token
    /// only to its own origin, or to a new one the user agreed to (F7). Pressing it is also Try
    /// Again after the keychain refused the token.
    @discardableResult
    public func testConnection() -> Task<Void, Never> {
        testTask?.cancel()
        startWait?.cancel()
        if askTokenHostFirst(then: .test) { return Task {} }
        form.result = .testing
        let draft = form.draft
        let editing = form.editing
        if let editing { transport.allowKeychainRead(editing) }
        let credential = credential(for: draft)
        let task = Task { @MainActor in
            let result = await test(draft, credential: credential)
            guard !Task.isCancelled, form.editing == editing, form.draft.baseURL == draft.baseURL else { return }
            form.result = result
        }
        testTask = task
        return task
    }

    /// The token a test sends: a typed one; else the saved one, to its own origin or to the
    /// draft's when the user said Keep for it; else none.
    private func credential(for draft: EndpointDraft) -> Credential? {
        if !draft.token.isEmpty { return .typed(draft.token) }
        guard let id = form.editing, let saved = endpoint(id), saved.hasToken, !draft.removeToken,
            let draftOrigin = Origin(draft.baseURL)
        else { return nil }
        if Origin(saved.baseURL) == draftOrigin { return .saved(endpointID: id, origin: draftOrigin) }
        if let answer = form.tokenHostAnswer, answer.origin == draftOrigin, answer.keep {
            return .saved(endpointID: id, origin: draftOrigin)
        }
        return nil
    }

    /// After Start on a test result: "Starting Ollama…" while its port is tried each second.
    /// When it answers, the test runs again; after 30 s, the result says it didn't start.
    func waitForService(_ service: ServiceDefinition) {
        startWait?.cancel()
        form.result = .starting(service: service.id, name: service.name)
        guard let port = Self.port(form.draft.baseURL) else { return }
        let deadline = clock.now.addingTimeInterval(Self.startTimeout)
        checkStarted(service, port: port, deadline: deadline)
    }

    private func checkStarted(_ service: ServiceDefinition, port: Int, deadline: Date) {
        let at = clock.now.addingTimeInterval(Self.startCheckInterval)
        startWait = scheduler.schedule(at: at) { [weak self] in
            guard let self, case .starting(service.id, _) = self.form.result else { return }
            Task { @MainActor in
                let answers = await self.ports.answers(port: port)
                guard case .starting(service.id, _) = self.form.result else { return }
                if answers {
                    self.testConnection()
                } else if self.clock.now >= deadline {
                    self.form.result = .startTimedOut(service: service.id, name: service.name)
                } else {
                    self.checkStarted(service, port: port, deadline: deadline)
                }
            }
        }
    }

    private func test(_ draft: EndpointDraft, credential: Credential?) async -> TestResult {
        let probe = Endpoint(name: draft.name, baseURL: draft.baseURL, model: draft.modelID)
        guard let modelsURL = probe.url("models"), let base = URL(string: draft.baseURL) else {
            return .unreachable(hostPort: draft.baseURL, service: nil)
        }
        let hasToken = credential != nil
        let typed = [draft.token].filter { !$0.isEmpty }
        let models: [String]
        do {
            let response = try await transport.send(
                HTTPRequest(url: modelsURL, credential: credential, timeout: Self.testTimeout))
            let body = try await response.collect(limit: 1 << 20)
            switch response.status {
            case 200: models = Self.modelIDs(body)
            case 401, 403: return hasToken ? .badToken(status: response.status) : .needsToken
            case 404: models = []  // The server doesn't list its models.
            default:
                let message = redactSecrets(response.redact(ChatErrorMapping.message(body)), known: typed)
                return .server(status: response.status, details: message)
            }
        } catch let error as HTTPError {
            return result(error, base: base, draft: draft, withToken: hasToken)
        } catch {
            return .server(status: 0, details: redactSecrets("\(error)", known: typed))
        }

        let model = draft.modelID.trimmingCharacters(in: .whitespaces)
        if model.isEmpty || (!models.isEmpty && !models.contains(model)) {
            return models.isEmpty
                ? .modelNotOnServer(model.isEmpty ? Endpoint.defaultModel : model) : .chooseModel(models)
        }
        return await testCompletion(draft, model: model, credential: credential, base: base, typed: typed)
    }

    /// A one-token message, timed.
    private func testCompletion(
        _ draft: EndpointDraft, model: String, credential: Credential?, base: URL, typed: [String]
    ) async -> TestResult {
        let probe = Endpoint(name: draft.name, baseURL: draft.baseURL, model: model)
        guard let url = probe.url("chat/completions") else { return .modelNotOnServer(model) }
        let body: [String: Any] = [
            "model": model, "max_tokens": 1, "stream": false, "messages": [["role": "user", "content": "Hi"]],
        ]
        let started = ContinuousClock.now
        do {
            let response = try await transport.send(
                HTTPRequest(
                    method: "POST", url: url, headers: ["Content-Type": "application/json"],
                    body: try? JSONSerialization.data(withJSONObject: body), credential: credential,
                    timeout: Self.testTimeout))
            let data = try await response.collect(limit: 1 << 20)
            switch response.status {
            case 200:
                let elapsed = ContinuousClock.now - started
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                return .ok(model: model, seconds: seconds)
            case 401, 403: return credential == nil ? .needsToken : .badToken(status: response.status)
            case 404: return .modelNotOnServer(model)
            default:
                let message = redactSecrets(response.redact(ChatErrorMapping.message(data)), known: typed)
                return .server(status: response.status, details: message)
            }
        } catch let error as HTTPError {
            return result(error, base: base, draft: draft, withToken: credential != nil)
        } catch {
            return .server(status: 0, details: redactSecrets("\(error)", known: typed))
        }
    }

    private func result(_ error: HTTPError, base: URL, draft: EndpointDraft, withToken: Bool) -> TestResult {
        switch error {
        case .redirected(let host): return .redirected(host: host ?? base.host ?? "", withToken: withToken)
        case .keychainDenied: return .keychainDenied
        default:
            let hostPort = [base.host, base.port.map(String.init)].compactMap { $0 }.joined(separator: ":")
            let service = EndpointURLPolicy.classify(draft.baseURL) == .loopback ? draftService()?.id : nil
            return .unreachable(hostPort: hostPort, service: service)
        }
    }

    /// The ids in a `GET /models` answer: `{"data": [{"id": "gpt-4o-mini"}, …]}`.
    static func modelIDs(_ body: Data) -> [String] {
        struct List: Decodable {
            struct Model: Decodable { let id: String }
            let data: [Model]
        }
        return (try? JSONDecoder().decode(List.self, from: body))?.data.map(\.id).sorted() ?? []
    }

    // MARK: Local servers

    /// Asks each local endpoint's port, and the quick-add ports, whether a server answers.
    /// Called when the model menu or Settings → Models opens; never polled.
    @discardableResult
    public func probeLocal() -> Task<Void, Never> {
        var wanted = Set(endpoints.filter(\.tag.isLocal).compactMap { Self.port($0.baseURL) })
        wanted.formUnion(ProviderTag.localPorts.keys)
        return Task { @MainActor in
            var answering: Set<Int> = []
            for port in wanted.sorted() where await ports.answers(port: port) {
                answering.insert(port)
            }
            answeringPorts = answering
            probedPorts.formUnion(wanted)
        }
    }

    /// The service linked to the draft, or the one on the draft URL's port.
    func draftService() -> ServiceDefinition? {
        if let id = form.draft.serviceID, let linked = services.definitions.first(where: { $0.id == id }) {
            return linked
        }
        return matchingService(form.draft.baseURL)
    }

    /// The service linked to an endpoint, or the one on its loopback port.
    func service(for endpoint: Endpoint) -> ServiceDefinition? {
        if let id = endpoint.serviceID, let linked = services.definitions.first(where: { $0.id == id }) {
            return linked
        }
        return matchingService(endpoint.baseURL)
    }

    /// The mask of a saved token: "sk-…a91f".
    func secretsMask(_ id: Endpoint.ID) -> String {
        secrets.mask(for: id) ?? "••••"
    }

    /// Every service, for the form's popup.
    var serviceDefinitions: [ServiceDefinition] { services.definitions }

    /// A service whose port is a loopback URL's port.
    private func matchingService(_ url: String) -> ServiceDefinition? {
        guard EndpointURLPolicy.classify(url) == .loopback, let port = Self.port(url) else { return nil }
        return services.definitions.first { $0.port == port }
    }

    static func port(_ url: String) -> Int? {
        guard let parts = URLComponents(string: url) else { return nil }
        return parts.port ?? (parts.scheme?.lowercased() == "https" ? 443 : 80)
    }
}
