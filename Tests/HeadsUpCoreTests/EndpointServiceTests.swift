import Foundation
import Testing

@testable import HeadsUpCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// An AppModel with a fake model server, tokens in memory, and a real data folder.
@MainActor
private final class EndpointsHarness {
    let clock = ManualClock()
    let scheduler: ManualScheduler
    let server = FakeHTTPClient()
    let secrets = MemorySecretStore()
    let probe = FakePortProbe()
    let launcher = FakeServiceLauncher()
    let folder: URL
    private let ownsRoot: Bool
    private(set) var model: AppModel!
    var endpoints: EndpointService { model.endpoints }

    init(sharing other: EndpointsHarness? = nil) throws {
        scheduler = ManualScheduler(clock: clock)
        let root =
            other?.folder.deletingLastPathComponent()
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("headsup-eps-\(UUID().uuidString)")
        ownsRoot = other == nil
        folder = root.appendingPathComponent("HeadsUp")
        // The home folder, where a service runs by default.
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var settings = Settings()
        settings.general.welcomeDone = true
        model = AppModel(
            ports: AppModel.Ports(
                clock: clock, scheduler: scheduler, hotkeys: FakeHotkeyRegistrar(),
                appearance: FixedAppearance(), files: FakeFileRevealer(), loginItem: FakeLoginItem(),
                systemSettings: FakeSystemSettingsLinks(), notifier: FakeNotifier(),
                powerAssertions: FakePowerAssertions(), powerSource: FakePowerSource(), serviceLauncher: launcher,
                portProbe: probe, folderPicker: FakeFolderPicker(), terminalLauncher: FakeTerminalLauncher(),
                secrets: other?.secrets ?? secrets, httpClient: server, dataFolder: folder, home: root.path,
                environment: [:]),
            settings: settings)
        model.launch()
    }

    deinit {
        guard ownsRoot else { return }
        try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
    }

    /// Adds an endpoint through the form and returns its id.
    @discardableResult
    func add(_ name: String, url: String, model id: String = "", token: String = "") -> Endpoint.ID {
        endpoints.cancelForm()
        endpoints.updateDraft {
            $0.name = name
            $0.baseURL = url
            $0.modelID = id
            $0.token = token
        }
        endpoints.saveForm()
        return endpoints.endpoints.last { $0.name == name }?.id ?? ""
    }

    var toast: FooterLeft { model.hud.footerLeft }
    var settingsFile: String {
        (try? String(contentsOf: folder.appendingPathComponent("settings.json"), encoding: .utf8)) ?? ""
    }
    func lastRequest() -> URLRequest? { server.requests.last }
}

@MainActor
@Suite(.serialized) struct EndpointServiceTests {
    // MARK: Adding

    @Test func aFreshInstallHasNoModel() throws {
        let h = try EndpointsHarness()
        #expect(h.endpoints.endpoints.isEmpty && h.endpoints.activeID == nil)
        #expect(
            h.endpoints.settingsScreen.emptyCard
                == "Add an OpenAI-compatible URL below. Ollama and LM Studio run on this Mac.")
        #expect(
            h.model.modelChip
                == ModelChip(
                    title: "No model", isPlaceholder: true, isOpen: false, accessibilityLabel: "Model: No model"))
        #expect(h.model.registry.actions.contains { $0.id == ActionID("model.add") })
    }

    @Test func theFirstEndpointBecomesTheDefaultAndActiveModel() throws {
        let h = try EndpointsHarness()
        let id = h.add(
            "GPT-4o mini", url: "https://api.openai.com/v1", model: "gpt-4o-mini", token: "sk-proj-abcdefgha91f")
        #expect(h.toast == .toast("Added GPT-4o mini"))
        #expect(h.endpoints.defaultID == id && h.endpoints.activeID == id)
        #expect(h.model.modelChip?.title == "GPT-4o mini")
        let row = try #require(h.endpoints.settingsScreen.rows.first)
        #expect(row.tag == "Custom" && row.tagHelp == nil && row.isDefault)
        #expect(row.urlLine == "https://api.openai.com/v1 · gpt-4o-mini" && row.token == "sk-…a91f")
        // The token is in the Keychain and in no file.
        #expect(h.secrets.saved[id] == "sk-proj-abcdefgha91f")
        #expect(!h.settingsFile.contains("sk-proj") && h.settingsFile.contains("api.openai.com"))
        #expect(h.endpoints.draftToken.isEmpty)
        // A second one doesn't take the roles.
        let ollama = h.add("Llama 3.1 8B", url: "http://localhost:11434/v1", model: "llama3.1:8b")
        #expect(h.endpoints.defaultID == id && h.endpoints.activeID == id)
        #expect(h.endpoints.settingsScreen.rows.last?.tag == "Ollama")
        #expect(h.endpoints.endpoint(ollama)?.hasToken == false)
    }

    @Test func anEmptyModelIDIsDefault() throws {
        let h = try EndpointsHarness()
        let id = h.add("Local", url: "http://127.0.0.1:8080/v1")
        #expect(h.endpoints.endpoint(id)?.model == "default")
    }

    @Test func quickAddFillsTheFormWithAnEmptyModelID() throws {
        let h = try EndpointsHarness()
        let service = ServiceDefinition(name: "Ollama", command: "ollama serve", port: 11434)
        #expect(h.model.services.save(service).isEmpty)
        h.endpoints.quickAdd(.ollama)
        let form = h.endpoints.settingsScreen.form
        #expect(form.name == "Ollama" && form.baseURL == "http://localhost:11434/v1" && form.modelID == "")
        #expect(form.service?.choices.first { $0.isSelected }?.id == service.id)
        h.endpoints.quickAdd(.openAI)
        #expect(h.endpoints.settingsScreen.form.imagesOn && h.endpoints.settingsScreen.form.service == nil)
    }

    @Test func theSettingsLeaveNoDanglingDefault() throws {
        let data = Data(
            #"{"endpoints":[{"id":"a","name":"A","baseURL":"https://a.example/v1"}],"defaultEndpointID":"gone"}"#.utf8)
        let settings = try JSONDecoder().decode(Settings.self, from: data)
        #expect(settings.endpoints.map(\.id) == ["a"] && settings.defaultEndpointID == nil)
        #expect(
            settings.endpoints[0].model == "default" && settings.endpoints[0].tools && !settings.endpoints[0].images)
    }

    // MARK: F9

    @Test func aPrivateAddressOverHTTPWarnsAndNeverKeepsAToken() throws {
        let h = try EndpointsHarness()
        h.endpoints.updateDraft {
            $0.name = "Mini"
            $0.baseURL = "http://192.168.1.20:11434/v1"
            $0.token = "sk-typed-abcdefgh"
        }
        let form = h.endpoints.settingsScreen.form
        #expect(
            form.baseURLNote == .init(text: "Not encrypted: anyone on this network can read your chats.", style: .warn))
        #expect(!form.tokenEnabled && form.tokenHelp == "Use https to add a token." && form.primaryEnabled)
        h.endpoints.saveForm()
        let id = try #require(h.endpoints.endpoints.first?.id)
        #expect(h.secrets.saved[id] == nil && h.endpoints.endpoint(id)?.hasToken == false)
    }

    @Test func otherPlainHTTPOrABadURLCantBeSaved() throws {
        let h = try EndpointsHarness()
        h.endpoints.updateDraft {
            $0.name = "Cloud"
            $0.baseURL = "http://api.openai.com/v1"
        }
        var form = h.endpoints.settingsScreen.form
        #expect(
            form.baseURLNote
                == .init(text: "Use https:// for servers outside your Mac and your network.", style: .danger))
        #expect(!form.primaryEnabled && !form.testEnabled)
        h.endpoints.updateDraft { $0.baseURL = "not a url" }
        form = h.endpoints.settingsScreen.form
        #expect(form.baseURLNote?.text == "Enter a full URL, like https://api.example.com/v1")
        h.endpoints.saveForm()
        #expect(h.endpoints.endpoints.isEmpty)
    }

    // MARK: F7

    @Test func aNewHostWithASavedTokenAsksFirst() throws {
        let h = try EndpointsHarness()
        let id = h.add("GPT", url: "https://api.openai.com/v1", token: "sk-proj-abcdefgha91f")
        h.endpoints.editEndpoint(id)
        #expect(h.endpoints.settingsScreen.form.tokenPlaceholder == "Saved in Keychain (sk-…a91f). Type to replace.")
        h.endpoints.updateDraft { $0.baseURL = "https://new-host.example/v1" }
        h.endpoints.saveForm()
        #expect(
            h.endpoints.settingsScreen.form.bar
                == .tokenHost(
                    question: "Send your saved token to new-host.example?", keep: "Keep token", remove: "Remove token"))
        #expect(h.endpoints.endpoint(id)?.baseURL == "https://api.openai.com/v1")  // not saved yet
        h.endpoints.answerTokenHost(keep: false)
        #expect(h.endpoints.endpoint(id)?.baseURL == "https://new-host.example/v1")
        #expect(h.endpoints.endpoint(id)?.hasToken == false && h.secrets.saved[id] == nil)
    }

    @Test func keepingTheTokenForTheNewHost() throws {
        let h = try EndpointsHarness()
        let id = h.add("GPT", url: "https://api.openai.com/v1", token: "sk-proj-abcdefgha91f")
        h.endpoints.editEndpoint(id)
        h.endpoints.updateDraft { $0.baseURL = "http://api.openai.com:443/v1" }
        h.endpoints.updateDraft { $0.baseURL = "https://proxy.example/v1" }
        h.endpoints.saveForm()
        h.endpoints.answerTokenHost(keep: true)
        #expect(h.endpoints.endpoint(id)?.hasToken == true && h.secrets.saved[id] == "sk-proj-abcdefgha91f")
    }

    @Test func aNewTokenTypedWithTheNewHostDoesntAsk() throws {
        let h = try EndpointsHarness()
        let id = h.add("GPT", url: "https://api.openai.com/v1", token: "sk-proj-abcdefgha91f")
        h.endpoints.editEndpoint(id)
        h.endpoints.updateDraft {
            $0.baseURL = "https://other.example/v1"
            $0.token = "sk-other-12345678"
        }
        h.endpoints.saveForm()
        #expect(h.endpoints.form.tokenHostQuestion == nil && h.secrets.saved[id] == "sk-other-12345678")
    }

    @Test func theSamePathOnTheSameHostDoesntAsk() throws {
        let h = try EndpointsHarness()
        let id = h.add("GPT", url: "https://api.openai.com/v1", token: "sk-proj-abcdefgha91f")
        h.endpoints.editEndpoint(id)
        h.endpoints.updateDraft { $0.modelID = "gpt-4o" }
        h.endpoints.saveForm()
        #expect(h.endpoints.endpoint(id)?.model == "gpt-4o" && h.endpoints.endpoint(id)?.hasToken == true)
        #expect(h.toast == .toast("Saved GPT"))
    }

    @Test func theDraftNeverPrintsItsToken() {
        var draft = EndpointDraft()
        draft.token = "sk-proj-secret-123456"
        #expect(!"\(draft)".contains("sk-proj") && !String(reflecting: draft).contains("sk-proj"))
        #expect("\(draft)".contains("••••"))
    }

    // MARK: Test connection

    @Test func testConnectionListsTheModelsWhenNoneIsChosen() async throws {
        let h = try EndpointsHarness()
        h.server.answer("/models", body: #"{"data":[{"id":"llama3.1:8b"},{"id":"qwen2.5"}]}"#)
        h.endpoints.quickAdd(.ollama)
        await h.endpoints.testConnection().value
        let result = try #require(h.endpoints.settingsScreen.form.result)
        #expect(result.style == .warn && result.text == "Connected. Choose a model:")
        #expect(result.models == ["llama3.1:8b", "qwen2.5"])
        h.endpoints.pickModel("qwen2.5")
        #expect(h.endpoints.settingsScreen.form.modelID == "qwen2.5")
    }

    @Test func testConnectionTimesAOneTokenMessage() async throws {
        let h = try EndpointsHarness()
        h.server.answer("/models", body: #"{"data":[{"id":"gpt-4o-mini"}]}"#)
        h.server.answer("/chat/completions", body: #"{"choices":[]}"#)
        h.endpoints.updateDraft {
            $0.name = "GPT"
            $0.baseURL = "https://api.openai.com/v1"
            $0.modelID = "gpt-4o-mini"
            $0.token = "sk-typed-abcdefgh"
        }
        await h.endpoints.testConnection().value
        let result = try #require(h.endpoints.settingsScreen.form.result)
        #expect(result.style == .ok && result.text.hasPrefix("Connected · gpt-4o-mini answered in "))
        let completion = try #require(h.lastRequest())
        #expect(completion.url?.path == "/v1/chat/completions" && completion.timeoutInterval == 10)
        // The typed token reaches an https server, through the transport.
        #expect(completion.value(forHTTPHeaderField: "Authorization") == "Bearer sk-typed-abcdefgh")
    }

    // S3: Test connection on a private address over http sends no Authorization.
    @Test func testConnectionOnAPrivateAddressSendsNoToken() async throws {
        let h = try EndpointsHarness()
        h.server.answer("/models", body: #"{"data":[]}"#)
        h.endpoints.updateDraft {
            $0.name = "Mini"
            $0.baseURL = "http://192.168.1.20:11434/v1"
            $0.token = "sk-typed-abcdefgh"
        }
        await h.endpoints.testConnection().value
        let request = try #require(h.lastRequest())
        #expect(request.url?.host == "192.168.1.20")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func testConnectionTokenProblems() async throws {
        let h = try EndpointsHarness()
        h.server.answer("/models", status: 401)
        h.endpoints.updateDraft {
            $0.name = "GPT"
            $0.baseURL = "https://api.openai.com/v1"
        }
        await h.endpoints.testConnection().value
        #expect(h.endpoints.settingsScreen.form.result?.text == "The server needs an API token.")
        h.endpoints.updateDraft { $0.token = "sk-wrong-abcdefgh" }
        await h.endpoints.testConnection().value
        #expect(h.endpoints.settingsScreen.form.result?.text == "The server rejected the token (401).")
    }

    @Test func aRedirectingURLShowsTheRedirect() async throws {
        let h = try EndpointsHarness()
        h.server.answer("/models", status: 307)
        h.endpoints.updateDraft {
            $0.name = "GPT"
            $0.baseURL = "https://api.openai.com/v1"
        }
        await h.endpoints.testConnection().value
        let result = try #require(h.endpoints.settingsScreen.form.result)
        #expect(result.style == .error && result.text.hasPrefix("The server redirected to api.openai.com."))
        #expect(h.server.requests.count == 1)
    }

    @Test func serverErrorDetailsNeverShowTheToken() async throws {
        let h = try EndpointsHarness()
        h.server.answer("/models", status: 500, body: #"{"error":{"message":"bad key sk-typed-abcdefgh for user"}}"#)
        h.endpoints.updateDraft {
            $0.name = "GPT"
            $0.baseURL = "https://api.openai.com/v1"
            $0.token = "sk-typed-abcdefgh"
        }
        await h.endpoints.testConnection().value
        let result = try #require(h.endpoints.settingsScreen.form.result)
        #expect(result.text == "The server answered with an error (500).")
        #expect(result.details == "bad key •••• for user")
    }

    @Test func nothingAnsweringOffersToStartItsService() async throws {
        let h = try EndpointsHarness()
        let service = ServiceDefinition(name: "Ollama", command: "ollama serve", port: 11434)
        #expect(h.model.services.save(service).isEmpty)
        h.server.fail(with: .refused)
        h.endpoints.quickAdd(.ollama)
        await h.endpoints.testConnection().value
        let result = try #require(h.endpoints.settingsScreen.form.result)
        #expect(result.text == "Can't reach localhost:11434." && result.start == "Start Ollama")
        h.model.startTestService()
        #expect(h.model.services.state(service.id).isLive)
        #expect(h.endpoints.settingsScreen.form.result?.text == "Starting Ollama…")
    }

    // MARK: Removing and the active model

    @Test func removingPassesTheRolesAndDeletesTheToken() throws {
        let h = try EndpointsHarness()
        let first = h.add("GPT", url: "https://api.openai.com/v1", token: "sk-proj-abcdefgha91f")
        let second = h.add("Llama", url: "http://localhost:11434/v1")
        h.endpoints.removeEndpoint(first)
        h.endpoints.confirmRemoveEndpoint()  // it had a token, so it asked
        #expect(h.secrets.saved[first] == nil)
        #expect(h.endpoints.defaultID == second && h.endpoints.activeID == second)
        h.endpoints.removeEndpoint(second)
        #expect(h.endpoints.endpoints.isEmpty && h.endpoints.activeID == nil && h.endpoints.defaultID == nil)
        #expect(h.model.modelChip?.title == "No model")
    }

    @Test func pickingAModelDoesntChangeTheDefaultAndALaunchStartsOnIt() throws {
        let h = try EndpointsHarness()
        let first = h.add("GPT", url: "https://api.openai.com/v1")
        let second = h.add("Llama", url: "http://localhost:11434/v1")
        h.model.hud.toggleModelMenu()
        h.model.selectModel(second)
        #expect(h.endpoints.activeID == second && h.endpoints.defaultID == first)
        #expect(!h.model.hud.modelMenuOpen && h.toast == .toast("Model: Llama"))
        let next = try EndpointsHarness(sharing: h)
        #expect(next.endpoints.activeID == first)
        h.endpoints.setDefault(second)
        #expect(h.endpoints.defaultID == second && h.endpoints.activeID == second)
    }

    // MARK: The model menu

    @Test func theMenuShowsLocalServersAndTheirState() async throws {
        let h = try EndpointsHarness()
        let service = ServiceDefinition(name: "Ollama", command: "ollama serve", port: 11434)
        #expect(h.model.services.save(service).isEmpty)
        let gpt = h.add("GPT", url: "https://api.openai.com/v1", model: "gpt-4o-mini")
        let llama = h.add("Llama", url: "http://localhost:11434/v1", model: "llama3.1:8b")
        h.model.hud.toggleModelMenu()
        #expect(h.model.body == .modelMenu)
        await h.endpoints.probeLocal().value
        let menu = h.model.modelMenu
        #expect(menu.rows.map(\.detail) == ["api.openai.com · gpt-4o-mini", "Ollama · llama3.1:8b · not running"])
        #expect(menu.rows.map(\.localTag) == [nil, "Local"])
        #expect(menu.rows.map(\.isActive) == [true, false] && menu.rows[0].isSelected)
        #expect(menu.rows[1].start == "Start" && menu.rows[0].start == nil)
        h.model.startEndpointService(llama)
        #expect(h.model.services.state(service.id).isLive)
        h.probe.answering = [11434]
        await h.endpoints.probeLocal().value
        #expect(h.model.modelMenu.rows[1].detail == "Ollama · llama3.1:8b" && h.model.modelMenu.rows[1].start == nil)
        _ = gpt
    }

    @Test func theKeyboardMovesThroughTheRowsAndManage() throws {
        let h = try EndpointsHarness()
        h.add("GPT", url: "https://api.openai.com/v1")
        let llama = h.add("Llama", url: "http://localhost:11434/v1")
        h.model.hud.selectTab(.chat)
        h.model.hud.toggleModelMenu()
        h.model.moveModelMenuSelection(1)
        #expect(h.model.modelMenu.rows[1].isSelected)
        h.model.moveModelMenuSelection(5)
        #expect(h.model.modelMenu.manageSelected)
        h.model.moveModelMenuSelection(-1)
        h.model.chooseModelMenuSelection()
        #expect(h.endpoints.activeID == llama && !h.model.hud.modelMenuOpen)
    }

    @Test func withNoModelReturnOpensSettings() throws {
        let h = try EndpointsHarness()
        h.model.hud.selectTab(.chat)
        h.model.hud.toggleModelMenu()
        #expect(h.model.modelMenu.emptyLine != nil && h.model.modelMenu.manageSelected)
        h.model.chooseModelMenuSelection()
        #expect(h.model.hud.tab == .settings && h.model.hud.settingsSection == .models)
    }

    @Test func switchModelActionsAreNeverSuggested() throws {
        let h = try EndpointsHarness()
        h.add("GPT", url: "https://api.openai.com/v1")
        let llama = h.add("Llama", url: "http://localhost:11434/v1", model: "llama3.1:8b")
        let action = try #require(h.model.registry.actions.first { $0.id == ActionID("model.switch:\(llama)") })
        #expect(action.title == "Switch model to Llama" && action.suggest == .never && action.kind == .model)
        #expect(!h.model.registry.actions.contains { $0.id == ActionID("model.add") })
        action.run()
        #expect(h.endpoints.activeID == llama)
    }

    @Test func openingTheMenuOrModelsProbesLocalServers() async throws {
        let h = try EndpointsHarness()
        h.add("Llama", url: "http://localhost:11434/v1")
        h.probe.answering = [11434]
        h.model.hud.selectTab(.settings)
        h.model.hud.selectSettingsSection(.general)
        h.model.hud.selectSettingsSection(.models)
        for _ in 0..<5 { await Task.yield() }
        #expect(h.endpoints.settingsScreen.quickAdd.first { $0.kind == .ollama }?.running == true)
        #expect(h.endpoints.settingsScreen.quickAdd.first { $0.kind == .ollama }?.runningHelp == "Running on this Mac")
    }
}

/// The slice 7 fix loop: F7 on Test connection, token removal on Save, keychain refusals,
/// the remove question, and the start wait.
@MainActor
@Suite(.serialized) struct EndpointFixLoopTests {
    private func editedToNewHost(_ h: EndpointsHarness) -> Endpoint.ID {
        let id = h.add("GPT", url: "https://api.openai.com/v1", model: "gpt-4o-mini", token: "sk-proj-abcdefgha91f")
        h.server.answer("/models", body: #"{"data":[{"id":"gpt-4o-mini"}]}"#)
        h.endpoints.editEndpoint(id)
        h.endpoints.updateDraft { $0.baseURL = "https://new-host.example/v1" }
        return id
    }

    // Scan M1 / Rev 1: the regression test for the F7 bypass through Test connection.
    @Test func testConnectionNeverSendsTheSavedTokenToANewHost() async throws {
        let h = try EndpointsHarness()
        _ = editedToNewHost(h)
        await h.endpoints.testConnection().value
        #expect(h.server.requests.isEmpty)
        #expect(
            h.endpoints.settingsScreen.form.bar
                == .tokenHost(
                    question: "Send your saved token to new-host.example?", keep: "Keep token", remove: "Remove token"))
        // Remove token: the test runs with no token at all.
        h.endpoints.answerTokenHost(keep: false)
        for _ in 0..<50 where h.server.requests.isEmpty { await Task.yield() }
        let request = try #require(h.server.requests.first)
        #expect(request.url?.host == "new-host.example")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func keepSendsItToTheNewHostOnlyAfterTheAnswer() async throws {
        let h = try EndpointsHarness()
        let id = editedToNewHost(h)
        await h.endpoints.testConnection().value
        h.endpoints.answerTokenHost(keep: true)
        for _ in 0..<50 where h.server.requests.isEmpty { await Task.yield() }
        #expect(h.lastRequest()?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-proj-abcdefgha91f")
        // The answer holds for this edit: Save doesn't ask again, and keeps the token.
        h.endpoints.saveForm()
        #expect(h.endpoints.endpoint(id)?.baseURL == "https://new-host.example/v1")
        #expect(h.endpoints.endpoint(id)?.hasToken == true)
    }

    @Test func aNewPortIsANewOriginAndEscSendsNothing() async throws {
        let h = try EndpointsHarness()
        let id = h.add("Local", url: "https://localhost:8443/v1", token: "sk-proj-abcdefgha91f")
        h.endpoints.editEndpoint(id)
        h.endpoints.updateDraft { $0.baseURL = "https://localhost:9443/v1" }
        await h.endpoints.testConnection().value
        #expect(h.endpoints.form.tokenHostQuestion != nil)
        h.model.hud.showSettings(.models)
        h.model.escape()
        #expect(h.endpoints.form.tokenHostQuestion == nil && h.server.requests.isEmpty)
    }

    @Test func theTransportRefusesASavedTokenForAnotherOrigin() async throws {
        let client = FakeHTTPClient()
        let transport = HTTPTransport(client: client, secrets: MemorySecretStore(["ep": "sk-proj-abcdefgha91f"]))
        await #expect(throws: HTTPError.tokenNotForThisOrigin) {
            _ = try await transport.send(
                HTTPRequest(
                    url: URL(string: "https://evil.example/v1/models")!,
                    credential: .saved(endpointID: "ep", origin: Origin("https://api.openai.com")!)))
        }
        await #expect(throws: HTTPError.tokenNotForThisOrigin) {
            _ = try await transport.send(
                HTTPRequest(
                    url: URL(string: "https://api.openai.com:8443/v1/models")!,
                    credential: .saved(endpointID: "ep", origin: Origin("https://api.openai.com")!)))
        }
        #expect(client.requests.isEmpty)
    }

    // Nick, blocking: Remove token waits for Save.
    @Test func removeTokenWaitsForSaveAndCancelKeepsIt() throws {
        let h = try EndpointsHarness()
        let id = h.add("GPT", url: "https://api.openai.com/v1", token: "sk-proj-abcdefgha91f")
        h.endpoints.editEndpoint(id)
        h.endpoints.removeToken()
        let form = h.endpoints.settingsScreen.form
        #expect(form.tokenRemovalNote == "The saved token is deleted when you save." && form.keepToken == "Keep Token")
        // Keep Token takes it back.
        h.endpoints.keepToken()
        #expect(h.endpoints.settingsScreen.form.tokenRemovalNote == nil)
        h.endpoints.saveForm()
        #expect(h.secrets.saved[id] != nil && h.endpoints.endpoint(id)?.hasToken == true)
        h.endpoints.editEndpoint(id)
        h.endpoints.removeToken()
        #expect(h.secrets.saved[id] != nil)
        h.endpoints.cancelForm()
        #expect(h.secrets.saved[id] != nil && h.endpoints.endpoint(id)?.hasToken == true)
        h.endpoints.editEndpoint(id)
        h.endpoints.removeToken()
        h.endpoints.saveForm()
        #expect(h.secrets.saved[id] == nil && h.endpoints.endpoint(id)?.hasToken == false)
    }

    @Test func aFailedKeychainDeleteKeepsTheTokenAndSaysSo() throws {
        let h = try EndpointsHarness()
        let id = h.add("GPT", url: "https://api.openai.com/v1", token: "sk-proj-abcdefgha91f")
        h.endpoints.editEndpoint(id)
        h.endpoints.removeToken()
        h.secrets.failure = -25291
        h.endpoints.saveForm()
        #expect(h.endpoints.endpoint(id)?.hasToken == true)
        #expect(h.endpoints.settingsScreen.form.tokenProblem?.hasPrefix("Couldn't delete the token") == true)
        #expect(h.endpoints.settingsScreen.form.tokenProblemTryAgain == "Try Again")
        h.secrets.failure = nil
    }

    @Test func aTokenTheKeychainWontSaveSavesNothing() throws {
        let h = try EndpointsHarness()
        h.secrets.failure = -25291
        h.endpoints.updateDraft {
            $0.name = "GPT"
            $0.baseURL = "https://api.openai.com/v1"
            $0.token = "sk-proj-abcdefgha91f"
        }
        h.endpoints.saveForm()
        #expect(h.endpoints.endpoints.isEmpty)
        #expect(
            h.endpoints.settingsScreen.form.tokenProblem
                == "Couldn't save the token in your keychain, so the endpoint isn't saved. Try again.")
        #expect(h.endpoints.settingsScreen.form.name == "GPT")
        h.secrets.failure = nil
    }

    // Scan Low: a refused read isn't "no token", and isn't asked again until Try Again.
    @Test func aRefusedKeychainReadSendsNothingAndOffersTryAgain() async throws {
        let h = try EndpointsHarness()
        let id = h.add("GPT", url: "https://api.openai.com/v1", model: "gpt-4o-mini", token: "sk-proj-abcdefgha91f")
        h.server.answer("/models", body: #"{"data":[{"id":"gpt-4o-mini"}]}"#)
        h.endpoints.editEndpoint(id)
        h.secrets.failure = -128  // errSecUserCanceled
        await h.endpoints.testConnection().value
        let result = try #require(h.endpoints.settingsScreen.form.result)
        #expect(result.text == "Your keychain didn't let HeadsUp read the token." && result.tryAgain == "Try Again")
        #expect(h.server.requests.isEmpty)
    }

    @Test func theTransportRemembersARefusalUntilTryAgain() async throws {
        let client = FakeHTTPClient()
        client.answer("/models", body: "{}")
        let secrets = MemorySecretStore(["ep": "sk-proj-abcdefgha91f"])
        let transport = HTTPTransport(client: client, secrets: secrets)
        let request = HTTPRequest(
            url: URL(string: "https://api.openai.com/v1/models")!,
            credential: .saved(endpointID: "ep", origin: Origin("https://api.openai.com")!))
        secrets.failure = -25293  // errSecAuthFailed
        await #expect(throws: HTTPError.keychainDenied) { _ = try await transport.send(request) }
        secrets.failure = nil
        // Not asked again: no prompt on every message.
        await #expect(throws: HTTPError.keychainDenied) { _ = try await transport.send(request) }
        #expect(client.requests.isEmpty)
        transport.allowKeychainRead("ep")
        _ = try await transport.send(request)
        #expect(client.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-proj-abcdefgha91f")
    }

    // Scan L1 / Rev 2: details mask the token that was actually sent, whatever its shape.
    @Test func detailsMaskTheSavedTokenSent() async throws {
        let h = try EndpointsHarness()
        let id = h.add("GPT", url: "https://api.openai.com/v1", token: "plainsecret-1234")
        h.server.answer("/models", status: 500, body: #"{"error":{"message":"denied for plainsecret-1234"}}"#)
        h.endpoints.editEndpoint(id)
        await h.endpoints.testConnection().value
        #expect(h.endpoints.settingsScreen.form.result?.details == "denied for ••••")
    }

    // Scan L2.
    @Test func endlessSSEDataIsABadResponse() async throws {
        var parser = SSEParser()
        let line = [UInt8](repeating: UInt8(ascii: "a"), count: 2 << 20)
        #expect(throws: SSEParser.TooLong.self) { _ = try parser.feed(Array("data: ".utf8) + line) }
        var events = SSEParser()
        let piece = Array("data: ".utf8) + [UInt8](repeating: UInt8(ascii: "b"), count: 900_000) + [10]
        #expect(throws: SSEParser.TooLong.self) {
            for _ in 0..<6 { _ = try events.feed(piece) }
        }
    }

    // Yuki: removing an endpoint with a token asks first.
    @Test func removingAnEndpointWithATokenAsksFirst() throws {
        let h = try EndpointsHarness()
        let gpt = h.add("GPT", url: "https://api.openai.com/v1", token: "sk-proj-abcdefgha91f")
        let local = h.add("Llama", url: "http://localhost:11434/v1")
        #expect(
            h.endpoints.settingsScreen.rows.map(\.removeHelp) == [
                "Remove (the token is deleted from the Keychain)", "Remove",
            ])
        h.endpoints.removeEndpoint(gpt)
        let bar = try #require(h.endpoints.settingsScreen.rows.first?.removeBar)
        #expect(bar.question == "Remove GPT? Its token is deleted from the Keychain." && bar.remove == "Remove")
        h.endpoints.cancelRemoveEndpoint()
        #expect(h.endpoints.endpoints.count == 2 && h.endpoints.settingsScreen.rows.first?.removeBar == nil)
        h.endpoints.removeEndpoint(gpt)
        h.secrets.failure = -25291
        h.endpoints.confirmRemoveEndpoint()
        // The keychain keeps the token: the endpoint goes anyway, and the note offers Try Again.
        #expect(h.endpoints.endpoints.map(\.id) == [local] && h.secrets.saved[gpt] != nil)
        let note = try #require(h.endpoints.settingsScreen.listProblem)
        #expect(note.text.hasPrefix("Couldn't delete the token from your keychain.") && note.tryAgain == "Try Again")
        h.endpoints.retryTokenDelete()
        #expect(h.endpoints.settingsScreen.listProblem != nil)  // still failing
        h.secrets.failure = nil
        h.endpoints.retryTokenDelete()
        #expect(h.secrets.saved[gpt] == nil && h.endpoints.settingsScreen.listProblem == nil)
        h.endpoints.removeEndpoint(local)  // no token: at once
        #expect(h.endpoints.endpoints.isEmpty)
    }

    @Test func theRowsAndPopupsCarryWhatTheViewNeeds() async throws {
        let h = try EndpointsHarness()
        let service = ServiceDefinition(name: "Ollama", command: "ollama serve", port: 11434)
        #expect(h.model.services.save(service).isEmpty)
        h.add("Llama", url: "http://localhost:11434/v1")
        h.add("Mine", url: "http://localhost:8080/v1")
        let rows = h.endpoints.settingsScreen.rows
        #expect(rows.map(\.tag) == ["Ollama", "Local"] && rows.map(\.localTag) == ["Local", nil])
        #expect(rows[0].radioLabel == "Default model" && rows[0].isDefault)
        h.endpoints.quickAdd(.ollama)
        #expect(h.endpoints.settingsScreen.form.service?.selectedID == service.id)
        h.server.answer("/models", body: #"{"data":[{"id":"a"}]}"#)
        await h.endpoints.testConnection().value
        #expect(h.endpoints.settingsScreen.form.result?.modelPrompt == "Choose a model")
    }

    @Test func startWaitsForThePortThenTestsAgainOrTimesOut() async throws {
        let h = try EndpointsHarness()
        let service = ServiceDefinition(name: "Ollama", command: "ollama serve", port: 11434)
        #expect(h.model.services.save(service).isEmpty)
        h.server.fail(with: .refused)
        h.endpoints.quickAdd(.ollama)
        await h.endpoints.testConnection().value
        h.model.startTestService()
        #expect(h.endpoints.settingsScreen.form.result?.text == "Starting Ollama…")
        // It answers after 2 s: the test runs again by itself.
        h.scheduler.advance(by: 1)
        for _ in 0..<5 { await Task.yield() }
        h.probe.answering = [11434]
        h.server.fail(with: nil)
        h.server.answer("/models", body: #"{"data":[{"id":"llama3.1:8b"}]}"#)
        h.scheduler.advance(by: 1)
        for _ in 0..<10 { await Task.yield() }
        #expect(h.endpoints.settingsScreen.form.result?.text == "Connected. Choose a model:")

        // Never answers: after 30 s it says so, with Open Services.
        h.server.fail(with: .refused)
        h.probe.answering = []
        await h.endpoints.testConnection().value
        h.model.startTestService()
        for _ in 0..<31 {
            h.scheduler.advance(by: 1)
            for _ in 0..<5 { await Task.yield() }
        }
        let result = try #require(h.endpoints.settingsScreen.form.result)
        #expect(
            result.text == "Ollama didn't start. Check its log in Services." && result.openServices == "Open Services")
        h.model.openTestServiceLogs()
        #expect(h.model.hud.tab == .services && h.model.services.openLogs == service.id)
    }
}
