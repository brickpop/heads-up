import Foundation

/// Which kind of server an endpoint URL points at (ADR-001 §6.1; UX part 1 §2, addendum 3):
/// one data table, so a new local server is one more row here. Only loopback is ever local.
public enum ProviderTag: Equatable, Sendable {
    case ollama
    case lmStudio
    /// Another server on this Mac.
    case local
    /// Anything else: the host tells the user where their chats go.
    case custom(host: String)

    /// Known local servers, by port.
    static let localPorts: [Int: ProviderTag] = [11434: .ollama, 1234: .lmStudio]

    public init(baseURL: String) {
        let parts = URLComponents(string: baseURL)
        guard EndpointURLPolicy.classify(baseURL) == .loopback, let parts else {
            self = .custom(host: parts?.host ?? baseURL)
            return
        }
        let port = parts.port ?? (parts.scheme?.lowercased() == "https" ? 443 : 80)
        self = Self.localPorts[port] ?? .local
    }

    /// The server runs on this Mac.
    public var isLocal: Bool {
        if case .custom = self { return false }
        return true
    }

    /// The provider text in the model menu and the autocomplete: "Ollama", "api.openai.com".
    public var providerText: String {
        switch self {
        case .ollama: "Ollama"
        case .lmStudio: "LM Studio"
        case .local: "Local"
        case .custom(let host): host
        }
    }
}
