import Foundation

/// One model the user can chat with (ADR-001 §8.1): an OpenAI-compatible base URL, a model
/// id, and what the model can do. Kept in settings.json; the token is in the Keychain, never here.
public struct Endpoint: Equatable, Codable, Sendable, Identifiable {
    public typealias ID = String

    public let id: ID
    public var name: String
    /// "https://api.openai.com/v1", "http://localhost:11434/v1"
    public var baseURL: String
    /// "gpt-4o-mini"; "default" when the user left it empty.
    public var model: String
    /// The model can see images.
    public var images: Bool
    /// The model can use tools.
    public var tools: Bool
    /// A token is saved in the Keychain for it.
    public var hasToken: Bool
    /// The service that runs this server, for "Start Ollama".
    public var serviceID: ServiceDefinition.ID?

    public init(
        id: ID = UUID().uuidString, name: String, baseURL: String, model: String = "default", images: Bool = false,
        tools: Bool = true, hasToken: Bool = false, serviceID: ServiceDefinition.ID? = nil
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.model = model
        self.images = images
        self.tools = tools
        self.hasToken = hasToken
        self.serviceID = serviceID
    }

    /// Lenient: a field left out takes its default, and a missing id gets a new one.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try container.decode(String.self, forKey: .name)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? "default"
        images = try container.decodeIfPresent(Bool.self, forKey: .images) ?? false
        tools = try container.decodeIfPresent(Bool.self, forKey: .tools) ?? true
        hasToken = try container.decodeIfPresent(Bool.self, forKey: .hasToken) ?? false
        serviceID = try container.decodeIfPresent(String.self, forKey: .serviceID)
    }

    /// `<base>/<path>`, whether or not the base ends with a slash.
    public func url(_ path: String) -> URL? {
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        return URL(string: base + "/" + path)
    }

    public var tag: ProviderTag { ProviderTag(baseURL: baseURL) }

    /// The model id sent when the user left it empty.
    public static let defaultModel = "default"
}
