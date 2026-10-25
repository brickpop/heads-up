import Foundation

/// A service the user defined (ADR-001 §6.2; Services spec): a long-running command HeadsUp
/// starts and stops, in a folder, with extra environment variables.
public struct ServiceDefinition: Equatable, Codable, Sendable, Identifiable {
    public typealias ID = String

    public let id: ID
    public var name: String
    public var command: String
    /// The folder it runs in; `~` stands for the home folder.
    public var cwd: String
    /// Extra environment variables, in the order the user wrote them. Plain text (F11).
    public var env: [EnvironmentVariable]
    /// The port it listens on, if known; otherwise HeadsUp looks for it after start.
    public var port: Int?
    /// Start with HeadsUp.
    public var autostart: Bool

    public init(
        id: ID = UUID().uuidString, name: String, command: String, cwd: String = "~",
        env: [EnvironmentVariable] = [], port: Int? = nil, autostart: Bool = false
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.cwd = cwd
        self.env = env
        self.port = port
        self.autostart = autostart
    }

    /// Lenient: a field left out takes its default, and a missing id gets a new one.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try container.decode(String.self, forKey: .name)
        command = try container.decode(String.self, forKey: .command)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd) ?? "~"
        env = try container.decodeIfPresent([EnvironmentVariable].self, forKey: .env) ?? []
        port = try container.decodeIfPresent(Int.self, forKey: .port)
        autostart = try container.decodeIfPresent(Bool.self, forKey: .autostart) ?? false
    }

    /// The problems that keep this definition from being saved or started, by field; empty
    /// when valid. The form checks them on Save, and the store again at load, since
    /// services.json can be edited by hand. A NUL can't be passed to a process (F13).
    public var problems: [ServiceField: String] {
        var problems: [ServiceField: String] = [:]
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty {
            problems[.name] = Strings.Services.nameEmpty
        } else if trimmedName.count > 64 {
            problems[.name] = Strings.Services.nameTooLong
        }
        if command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            problems[.command] = Strings.Services.commandProblem
        } else if command.contains("\0") {
            problems[.command] = Strings.Services.nulProblem
        }
        if cwd.contains("\0") { problems[.cwd] = Strings.Services.nulProblem }
        if let port, !(1...65_535).contains(port) { problems[.port] = Strings.Services.portProblem }
        if env.contains(where: { !EnvironmentVariable.isValidKey($0.key) }) {
            problems[.env] = Strings.Services.envKeyProblem
        } else if env.contains(where: { $0.value.contains("\0") }) {
            problems[.env] = Strings.Services.nulProblem
        }
        return problems
    }

    /// The first problem, in the form's order, for the row of a service that can't start.
    var firstProblem: String? {
        ServiceField.formOrder.lazy.compactMap { problems[$0] }.first
    }
}

/// The fields of the service form, for its problems.
public enum ServiceField: Hashable, Sendable {
    case name, command, cwd, env, port
    /// services.json itself: it couldn't be read, or couldn't be written.
    case file

    static let formOrder: [ServiceField] = [.name, .command, .cwd, .env, .port]
}

/// Why services.json can't be used, while the editor is off and the file is left as it is.
public enum ServicesFileProblem: Equatable, Sendable {
    /// It couldn't be read or decoded. The reason is short and plain, or nil when there is
    /// nothing useful to say.
    case unreadable(reason: String?)
    /// A newer HeadsUp wrote it.
    case newerVersion
}

public struct EnvironmentVariable: Equatable, Codable, Sendable {
    public var key: String
    public var value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }

    /// `[A-Za-z_][A-Za-z0-9_]*`
    public static func isValidKey(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first, first == "_" || isASCIILetter(first) else { return false }
        return key.unicodeScalars.allSatisfy { $0 == "_" || isASCIILetter($0) || ("0"..."9").contains($0) }
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }
}

/// services.json: `{ "version": 1, "services": [...] }`.
struct ServicesFile: Codable {
    static let currentVersion = 1
    var version = ServicesFile.currentVersion
    var services: [ServiceDefinition] = []

    init(services: [ServiceDefinition] = []) {
        self.services = services
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? ServicesFile.currentVersion
        services = try container.decodeIfPresent([ServiceDefinition].self, forKey: .services) ?? []
    }
}
