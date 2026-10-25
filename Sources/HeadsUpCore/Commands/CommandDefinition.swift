import Foundation

/// A command the user saved (Commands spec): an interactive command opened in their terminal,
/// in a folder.
public struct CommandDefinition: Equatable, Codable, Sendable, Identifiable {
    public typealias ID = String

    public let id: ID
    public var name: String
    public var command: String
    /// The folder it runs in; `~` stands for the home folder.
    public var cwd: String

    public init(id: ID = UUID().uuidString, name: String, command: String, cwd: String = "~") {
        self.id = id
        self.name = name
        self.command = command
        self.cwd = cwd
    }

    /// Lenient: a missing folder is `~`, and a missing id gets a new one.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try container.decode(String.self, forKey: .name)
        command = try container.decode(String.self, forKey: .command)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd) ?? "~"
    }

    /// The problems that keep this command from being saved or run, by field; empty when
    /// valid. Checked on Save and again at load, since commands.json can be edited by hand.
    public var problems: [CommandField: String] {
        var problems: [CommandField: String] = [:]
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
        return problems
    }
}

/// The fields of the command form, for its problems.
public enum CommandField: Hashable, Sendable {
    case name, command, cwd
    /// commands.json itself: it couldn't be read, or couldn't be written.
    case file
}
