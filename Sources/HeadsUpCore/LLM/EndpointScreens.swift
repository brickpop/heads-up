import Foundation

/// Settings → Models, ready to draw (contract, slice 7; UX part 1, §2; addendum 3).
public struct ModelsSettingsScreen: Equatable, Sendable {
    public let title: String
    public let intro: String
    /// Shown in place of the list with no endpoints.
    public let emptyCard: String?
    public let quickAdd: [QuickAdd]
    public let rows: [Row]
    public let listProblem: ListProblem?
    /// Always there: adding, or editing a row.
    public let form: EndpointFormScreen

    /// A quick-add button: `endpoints.quickAdd(kind)`.
    public struct QuickAdd: Equatable, Sendable, Identifiable {
        public let kind: QuickAddKind
        public let title: String
        /// A server answers on its port now: a green dot.
        public let running: Bool
        /// "Running on this Mac", while running.
        public let runningHelp: String?
        public var id: QuickAddKind { kind }
    }

    public struct Row: Equatable, Sendable, Identifiable {
        public let id: Endpoint.ID
        public let name: String
        /// "Ollama", "LM Studio", "Local" or "Custom".
        public let tag: String
        /// "Runs on this Mac", for the three local tags.
        public let tagHelp: String?
        /// "Local", beside Ollama and LM Studio, as in the model menu.
        public let localTag: String?
        /// Mono: "https://api.openai.com/v1 · gpt-4o-mini"
        public let urlLine: String
        /// Mono, --ink-3: "sk-…a91f" or "no token".
        public let token: String
        /// The radio: `endpoints.setDefault(id)`. Selected for the default.
        public let isDefault: Bool
        /// The radio's VoiceOver label, "Default model"; its value is the name.
        public let radioLabel: String
        /// The row the form is editing: --sel.
        public let isEditing: Bool
        /// The ×'s tooltip: `endpoints.removeEndpoint(id)`.
        public let removeHelp: String
        /// The row's question before removing an endpoint with a saved token.
        public let removeBar: RemoveBar?
    }

    /// "Remove GPT-4o mini? Its token is deleted from the Keychain.": `cancelRemoveEndpoint()`
    /// or `confirmRemoveEndpoint()`, no default button.
    public struct RemoveBar: Equatable, Sendable {
        public let question: String
        public let cancel: String
        public let remove: String
    }

    /// Under the list, in --danger: a removed endpoint's token the keychain kept. Try Again is
    /// `endpoints.retryTokenDelete()`.
    public struct ListProblem: Equatable, Sendable {
        public let text: String
        public let tryAgain: String
    }
}

/// The endpoint form. The token's secure field reads `endpoints.draftToken` and writes through
/// `updateDraft`; the token never appears here.
public struct EndpointFormScreen: Equatable, Sendable {
    /// "Add endpoint", or "Edit GPT-4o mini".
    public let label: String
    public let name: String
    public let modelID: String
    public let modelField: ModelField
    /// Under Model id, in --ink-2: why it is a text field and not the menu.
    public let modelIDHelp: String?
    public let baseURL: String
    /// Under Base URL: --warn for a private address over http, --danger for a URL that can't
    /// be used (F9).
    public let baseURLNote: Note?
    /// Off for a private address over http (F9).
    public let tokenEnabled: Bool
    /// "API token (stored in Keychain)", or "Saved in Keychain (…a91f). Type to replace."
    public let tokenPlaceholder: String
    public let tokenHelp: String?
    /// Under the API token field, in --danger: the keychain wouldn't save or remove the token.
    public let tokenProblem: String?
    /// "Try Again" beside `tokenProblem`: `endpoints.saveForm()`.
    public let tokenProblemTryAgain: String?
    /// After Remove token, in --ink-2: "The saved token is deleted when you save."
    public let tokenRemovalNote: String?
    /// "Keep Token", beside that note: `endpoints.keepToken()`.
    public let keepToken: String?
    /// "Remove token", while editing an endpoint with a saved token: `endpoints.removeToken()`.
    public let removeToken: String?
    public let imagesOn: Bool
    public let toolsOn: Bool
    public let optionsHelp: String
    /// For a URL on this Mac: None and every service.
    public let service: ServicePicker?
    /// "Test connection": `endpoints.testConnection()`.
    public let test: String
    public let testEnabled: Bool
    /// Under the buttons.
    public let result: TestResultScreen?
    /// "Add endpoint" or "Save": `endpoints.saveForm()`.
    public let primary: String
    public let primaryEnabled: Bool
    /// "Cancel", while editing: `endpoints.cancelForm()`.
    public let cancel: String?
    public let bar: EndpointFormBar

    /// Model id: the server's models in a pop-up menu (mono), or the text field.
    public enum ModelField: Equatable, Sendable {
        case text
        /// The menu: the server's models, after a model id the list doesn't hold. `selected` is
        /// the draft's model id; with none, the menu shows `prompt`. Picking one is
        /// `endpoints.pickModel(id)`. While loading, it is disabled with a small spinner.
        case menu(choices: [ModelChoice], selected: String?, prompt: String, isLoading: Bool)
    }

    /// A model in the menu. `title` is the id, or "llama2:7b — not on this server".
    public struct ModelChoice: Equatable, Sendable {
        public let id: String
        public let title: String
    }

    public struct Note: Equatable, Sendable {
        public let text: String
        public let style: Style

        public enum Style: Equatable, Sendable {
            case warn, danger
        }
    }

    public struct ServicePicker: Equatable, Sendable {
        public let label: String
        public let choices: [ServiceChoice]
        /// The chosen service; nil is None.
        public let selectedID: ServiceDefinition.ID?
    }

    /// A service choice; `id` nil is None. Choosing one sets `draft.serviceID`.
    public struct ServiceChoice: Equatable, Sendable {
        public let id: ServiceDefinition.ID?
        public let title: String
        public let isSelected: Bool
    }
}

/// The bottom of the endpoint form.
public enum EndpointFormBar: Equatable, Sendable {
    case none
    /// "Send your saved token to new-host.example?": `answerTokenHost(keep:)`. No default button.
    case tokenHost(question: String, keep: String, remove: String)
}

/// A Test connection result, ready to draw.
public struct TestResultScreen: Equatable, Sendable {
    public let style: Style
    public let text: String
    /// "Start Ollama": `AppModel.startTestService()`.
    public let start: String?
    /// "Open Services", after a service didn't start: `AppModel.openTestServiceLogs()`.
    public let openServices: String?
    /// "Try Again", after the keychain refused the token: `endpoints.testConnection()`.
    public let tryAgain: String?
    /// The Details disclosure, mono, secrets masked.
    public let details: String?

    public enum Style: Equatable, Sendable {
        /// A small spinner.
        case running
        /// A green check.
        case ok
        /// An orange triangle.
        case warn
        /// A red ×.
        case error
    }
}

/// The model menu (Model endpoints spec; UX part 1, §2), drawn in the HUD body.
public struct ModelMenuScreen: Equatable, Sendable {
    /// "Model"
    public let label: String
    /// With no endpoints.
    public let emptyLine: String?
    public let rows: [Row]
    /// "Manage endpoints…": `AppModel.manageEndpoints()`.
    public let manage: String
    /// The keyboard selection is on Manage endpoints….
    public let manageSelected: Bool

    public struct Row: Equatable, Sendable, Identifiable {
        public let id: Endpoint.ID
        public let name: String
        /// "Local", for a server on this Mac.
        public let localTag: String?
        /// Mono: "Ollama · llama3.1:8b · not running".
        public let detail: String
        /// The accent check: the model chat uses now.
        public let isActive: Bool
        /// The keyboard selection.
        public let isSelected: Bool
        /// "Start", for a local server that isn't running and has a service:
        /// `AppModel.startEndpointService(id)`.
        public let start: String?
    }
}

/// The model chip in the Chat header: `hud.toggleModelMenu()`.
public struct ModelChip: Equatable, Sendable {
    /// The active model's name, or "No model".
    public let title: String
    /// No endpoint yet: the title is a placeholder.
    public let isPlaceholder: Bool
    public let isOpen: Bool
    /// "Model: GPT-4o mini"
    public let accessibilityLabel: String
}

extension EndpointService {
    public var settingsScreen: ModelsSettingsScreen {
        ModelsSettingsScreen(
            title: Strings.Models.title, intro: Strings.Models.intro,
            emptyCard: endpoints.isEmpty ? Strings.Models.emptyCard : nil,
            quickAdd: QuickAddKind.allCases.map { kind in
                let running = Self.quickAddPort(kind).map { answeringPorts.contains($0) } ?? false
                return ModelsSettingsScreen.QuickAdd(
                    kind: kind, title: Strings.Models.quickAdd(kind), running: running,
                    runningHelp: running ? Strings.Models.runningOnThisMac : nil)
            }, rows: endpoints.map(row),
            listProblem: leftoverToken == nil
                ? nil
                : ModelsSettingsScreen.ListProblem(
                    text: Strings.EndpointForm.removeFailed, tryAgain: Strings.EndpointForm.tryAgain),
            form: formScreen)
    }

    private func row(_ endpoint: Endpoint) -> ModelsSettingsScreen.Row {
        let tag = endpoint.tag
        // Ollama and LM Studio also show "Local"; a plain local server's tag already is "Local".
        let alsoLocal = tag == .ollama || tag == .lmStudio
        return ModelsSettingsScreen.Row(
            id: endpoint.id, name: endpoint.name, tag: Strings.Models.tag(tag),
            tagHelp: tag.isLocal ? Strings.Models.localTagHelp : nil,
            localTag: alsoLocal ? Strings.Models.localTag : nil,
            urlLine: Strings.Models.urlLine(endpoint.baseURL, model: endpoint.model),
            token: endpoint.hasToken ? secretsMask(endpoint.id) : Strings.Models.noToken,
            isDefault: endpoint.id == defaultID, radioLabel: Strings.Models.defaultModel,
            isEditing: endpoint.id == form.editing,
            removeHelp: endpoint.hasToken ? Strings.Models.removeHelp : Strings.Models.removeHelpNoToken,
            removeBar: removing == endpoint.id
                ? ModelsSettingsScreen.RemoveBar(
                    question: Strings.Models.removeQuestion(endpoint.name), cancel: Strings.Models.cancel,
                    remove: Strings.Models.remove)
                : nil)
    }

    private var formScreen: EndpointFormScreen {
        let draft = form.draft
        let policy = EndpointURLPolicy.classify(draft.baseURL)
        let editing = form.editing.flatMap(endpoint)
        let note: EndpointFormScreen.Note? =
            switch policy {
            case _ where draft.baseURL.trimmingCharacters(in: .whitespaces).isEmpty: nil
            case .privateHTTP: EndpointFormScreen.Note(text: Strings.EndpointForm.notEncrypted, style: .warn)
            case .rejected:
                URLComponents(string: draft.baseURL)?.scheme?.lowercased() == "http"
                    && URLComponents(string: draft.baseURL)?.host?.isEmpty == false
                    ? EndpointFormScreen.Note(text: Strings.EndpointForm.needsHTTPS, style: .danger)
                    : EndpointFormScreen.Note(text: Strings.EndpointForm.urlNotValid, style: .danger)
            case .loopback, .https: nil
            }
        let tokenEnabled = policy != .privateHTTP
        let savedMask = editing?.hasToken == true && !draft.removeToken ? editing.map { secretsMask($0.id) } : nil
        let placeholder =
            savedMask.map(Strings.EndpointForm.tokenSavedPlaceholder) ?? Strings.EndpointForm.tokenPlaceholder
        return EndpointFormScreen(
            label: editing.map { Strings.EndpointForm.editLabel($0.name) } ?? Strings.EndpointForm.addLabel,
            name: draft.name, modelID: draft.modelID, modelField: modelField, modelIDHelp: modelIDHelp,
            baseURL: draft.baseURL, baseURLNote: note,
            tokenEnabled: tokenEnabled, tokenPlaceholder: placeholder,
            tokenHelp: tokenEnabled ? Strings.EndpointForm.tokenHelp : Strings.EndpointForm.tokenNeedsHTTPS,
            tokenProblem: form.tokenProblem,
            tokenProblemTryAgain: form.tokenProblem == nil ? nil : Strings.EndpointForm.tryAgain,
            tokenRemovalNote: draft.removeToken ? Strings.EndpointForm.tokenRemovalNote : nil,
            keepToken: draft.removeToken ? Strings.EndpointForm.keepSavedToken : nil,
            removeToken: savedMask != nil ? Strings.EndpointForm.removeToken : nil, imagesOn: draft.imagesOn,
            toolsOn: draft.toolsOn, optionsHelp: Strings.EndpointForm.optionsHelp, service: servicePicker,
            test: Strings.EndpointForm.test, testEnabled: form.result != .testing && policy != .rejected,
            result: form.result.map(resultScreen),
            primary: editing == nil ? Strings.EndpointForm.add : Strings.EndpointForm.save, primaryEnabled: canSave,
            cancel: editing == nil ? nil : Strings.EndpointForm.cancel,
            bar: form.tokenHostQuestion.map {
                .tokenHost(
                    question: Strings.EndpointForm.tokenHostQuestion($0.host), keep: Strings.EndpointForm.keepToken,
                    remove: Strings.EndpointForm.removeToken)
            } ?? .none)
    }

    /// Model id: the menu once the server listed its models or while they load, else the text
    /// field.
    private var modelField: EndpointFormScreen.ModelField {
        let current = form.draft.modelID.trimmingCharacters(in: .whitespaces)
        func menu(_ models: [String], isLoading: Bool) -> EndpointFormScreen.ModelField {
            var choices = models.map { EndpointFormScreen.ModelChoice(id: $0, title: $0) }
            // A model id the server doesn't list (an edited endpoint whose model is gone) stays
            // the current item. While loading, it isn't known yet whether the server has it.
            if !current.isEmpty && !models.contains(current) {
                let title = isLoading ? current : Strings.EndpointForm.notOnServer(current)
                choices.insert(EndpointFormScreen.ModelChoice(id: current, title: title), at: 0)
            }
            return .menu(
                choices: choices, selected: current.isEmpty ? nil : current,
                prompt: Strings.EndpointForm.chooseModelPrompt, isLoading: isLoading)
        }
        switch form.models {
        case .none, .notListed, .failed: return .text
        case .loading: return menu([], isLoading: true)
        case .listed(let models): return menu(models, isLoading: false)
        }
    }

    /// Under the text field, in --ink-2: why there is no menu.
    private var modelIDHelp: String? {
        switch form.models {
        case .none, .loading, .listed: nil
        case .notListed: Strings.EndpointForm.modelsNotListed
        // Without a token sent, a server that wants one: Test connection sends the token.
        case .failed(.needsToken): Strings.EndpointForm.modelsNeedToken
        case .failed(let result): resultScreen(result).text
        }
    }

    /// The service popup, only for a URL on this Mac.
    private var servicePicker: EndpointFormScreen.ServicePicker? {
        guard EndpointURLPolicy.classify(form.draft.baseURL) == .loopback else { return nil }
        let selected = form.draft.serviceID
        let none = EndpointFormScreen.ServiceChoice(
            id: nil, title: Strings.EndpointForm.serviceNone, isSelected: selected == nil)
        return EndpointFormScreen.ServicePicker(
            label: Strings.EndpointForm.service,
            choices: [none]
                + serviceDefinitions.map {
                    EndpointFormScreen.ServiceChoice(id: $0.id, title: $0.name, isSelected: $0.id == selected)
                }, selectedID: selected)
    }

    private func resultScreen(_ result: TestResult) -> TestResultScreen {
        func screen(
            _ style: TestResultScreen.Style, _ text: String, start: String? = nil,
            openServices: String? = nil, tryAgain: String? = nil, details: String? = nil
        ) -> TestResultScreen {
            TestResultScreen(
                style: style, text: text, start: start, openServices: openServices, tryAgain: tryAgain,
                details: details)
        }
        switch result {
        case .testing: return screen(.running, Strings.EndpointForm.testing)
        case .ok(let model, let seconds): return screen(.ok, Strings.EndpointForm.ok(model: model, seconds: seconds))
        case .chooseModel: return screen(.warn, Strings.EndpointForm.chooseModel)
        case .modelNotOnServer(let model): return screen(.warn, Strings.EndpointForm.modelNotOnServer(model))
        case .needsToken: return screen(.error, Strings.EndpointForm.needsToken)
        case .badToken(let status): return screen(.error, Strings.EndpointForm.badToken(status: status))
        case .unreachable(let hostPort, let service):
            let name = service.flatMap { id in serviceDefinitions.first { $0.id == id }?.name }
            return screen(
                .error, Strings.EndpointForm.unreachable(hostPort), start: name.map(Strings.EndpointForm.start))
        case .starting(_, let name): return screen(.running, Strings.EndpointForm.starting(name))
        case .startTimedOut(_, let name):
            return screen(
                .error, Strings.EndpointForm.startTimedOut(name), start: Strings.EndpointForm.start(name),
                openServices: Strings.EndpointForm.openServices)
        case .redirected(let host, let withToken):
            return screen(.error, Strings.EndpointForm.redirected(host, withToken: withToken))
        case .server(let status, let details):
            return screen(
                .error, Strings.EndpointForm.serverError(status: status), details: details.isEmpty ? nil : details)
        case .keychainDenied:
            return screen(.error, Strings.EndpointForm.keychainDenied, tryAgain: Strings.EndpointForm.tryAgain)
        }
    }

    static func quickAddPort(_ kind: QuickAddKind) -> Int? {
        switch kind {
        case .ollama: 11434
        case .lmStudio: 1234
        case .openAI, .other: nil
        }
    }
}
