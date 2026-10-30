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
    /// Keep the Mac from going to sleep on its own while it runs, and for how long (slice B holds
    /// it; keep-awake limit addendum).
    public var keepAwake: ServiceKeepAwake
    /// Start it again when it stops without being asked to, up to `ServiceStore.maxRestarts`
    /// times in a row.
    public var restartOnExit: Bool

    public init(
        id: ID = UUID().uuidString, name: String, command: String, cwd: String = "~",
        env: [EnvironmentVariable] = [], port: Int? = nil, autostart: Bool = false,
        keepAwake: ServiceKeepAwake = .off, restartOnExit: Bool = false
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.cwd = cwd
        self.env = env
        self.port = port
        self.autostart = autostart
        self.keepAwake = keepAwake
        self.restartOnExit = restartOnExit
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
        // Added later: a file without them has both off.
        keepAwake = Self.decodeKeepAwake(container)
        restartOnExit = try container.decodeIfPresent(Bool.self, forKey: .restartOnExit) ?? false
    }

    /// Writes `keepAwakeFor` and never the old `keepAwake`: an older HeadsUp ignores the new key
    /// and reads Off, which holds less, not more.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(command, forKey: .command)
        try container.encode(cwd, forKey: .cwd)
        try container.encode(env, forKey: .env)
        try container.encodeIfPresent(port, forKey: .port)
        try container.encode(autostart, forKey: .autostart)
        try container.encode(keepAwake, forKey: .keepAwake)
        try container.encode(restartOnExit, forKey: .restartOnExit)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, command, cwd, env, port, autostart, restartOnExit
        case keepAwake = "keepAwakeFor"
        /// The Bool of files from before the limit: read, never written.
        case legacyKeepAwake = "keepAwake"
    }

    /// `keepAwakeFor` when present, where a value this build doesn't know is Off, so a bad value
    /// never holds longer than asked. Otherwise the old Bool: true is Unlimited, false is Off.
    /// Otherwise Off.
    private static func decodeKeepAwake(_ container: KeyedDecodingContainer<CodingKeys>) -> ServiceKeepAwake {
        if container.contains(.keepAwake) {
            return (try? container.decode(ServiceKeepAwake.self, forKey: .keepAwake)) ?? .off
        }
        if let legacy = try? container.decodeIfPresent(Bool.self, forKey: .legacyKeepAwake) {
            return legacy ? .unlimited : .off
        }
        return .off
    }

    /// The problems that keep this definition from being saved or started, by field; empty
    /// when valid. The form checks them on Save, and the store again at load, since
    /// services.json can be edited by hand. A NUL can't be passed to a process (F13).
    public var problems: [ServiceField: String] {
        var problems: [ServiceField: String] = [:]
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty {
            problems[.name] = Strings.ListForm.nameEmpty
        } else if trimmedName.count > 64 {
            problems[.name] = Strings.ListForm.nameTooLong
        }
        if command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            problems[.command] = Strings.ListForm.commandProblem
        } else if command.contains("\0") {
            problems[.command] = Strings.ListForm.nulProblem
        }
        if cwd.contains("\0") { problems[.cwd] = Strings.ListForm.nulProblem }
        if let port, !(1...65_535).contains(port) { problems[.port] = Strings.Services.portProblem }
        if env.contains(where: { !EnvironmentVariable.isValidKey($0.key) }) {
            problems[.env] = Strings.Services.envKeyProblem
        } else if env.contains(where: { $0.value.contains("\0") }) {
            problems[.env] = Strings.ListForm.nulProblem
        }
        return problems
    }

    /// The first problem, in the form's order, for the row of a service that can't start.
    var firstProblem: String? {
        ServiceField.formOrder.lazy.compactMap { problems[$0] }.first
    }
}

/// How long a service keeps the Mac awake, counted from when the user starts it (keep-awake
/// limit addendum §1). The cases are in the order the form's segmented control shows them.
public enum ServiceKeepAwake: String, Codable, CaseIterable, Sendable {
    case off, thirtyMinutes, twoHours, fiveHours, unlimited

    /// Its limit in minutes; nil for Off and for Unlimited.
    public var minutes: Int? {
        switch self {
        case .thirtyMinutes: 30
        case .twoHours: 120
        case .fiveHours: 300
        case .off, .unlimited: nil
        }
    }
}

/// The fields of the service form, for its problems.
public enum ServiceField: Hashable, Sendable {
    case name, command, cwd, env, port
    /// services.json itself: it couldn't be read, or couldn't be written.
    case file

    static let formOrder: [ServiceField] = [.name, .command, .cwd, .env, .port]
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
