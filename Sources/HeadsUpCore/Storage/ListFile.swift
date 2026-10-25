import Foundation

#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

/// The two files that each hold one list the user edits (ADR-001 §6.2).
public enum ListFileKind: Sendable {
    case services, commands

    /// "services.json"
    public var fileName: String {
        switch self {
        case .services: "services.json"
        case .commands: "commands.json"
        }
    }

    /// The key of the list in the file, and the word for its items: "services".
    var plural: String {
        switch self {
        case .services: "services"
        case .commands: "commands"
        }
    }

    /// "service", as in "service 2 has no name".
    var singular: String {
        switch self {
        case .services: "service"
        case .commands: "command"
        }
    }
}

/// Why a list file can't be used, while its editor is off and the file is left as it is.
public enum ListFileProblem: Error, Equatable, Sendable {
    /// It couldn't be read or decoded. The reason is short and plain, or nil when there is
    /// nothing useful to say.
    case unreadable(reason: String?)
    /// A newer HeadsUp wrote it.
    case newerVersion
}

/// A versioned JSON file that holds one list: `{ "version": 1, "<plural>": [...] }`, read and
/// written through SecureFile (0600, atomic).
///
/// - A missing file is an empty list, and nothing is created until the first write.
/// - A file that doesn't decode, or comes from a newer version, is a problem; the store then
///   never writes it, so the user's file is kept as it is.
/// - Decoding is lenient where each item's own decoder is.
struct JSONListFile<Item: Codable> {
    static var currentVersion: Int { 1 }

    let kind: ListFileKind
    /// The file, or nil for a store that keeps its list in memory only (previews).
    let url: URL?

    init(_ kind: ListFileKind, folder: URL?) {
        self.kind = kind
        url = folder?.appendingPathComponent(kind.fileName)
    }

    func load() -> Result<[Item], ListFileProblem> {
        guard let url else { return .success([]) }
        do throws(SecureFile.FileError) {
            try SecureFile.checkFolder(url.deletingLastPathComponent())
            guard let data = try SecureFile.read(url) else { return .success([]) }
            let decoder = JSONDecoder()
            decoder.userInfo[ListContents<Item>.listKey] = kind.plural
            do {
                let contents = try decoder.decode(ListContents<Item>.self, from: data)
                guard contents.version <= Self.currentVersion else { return .failure(.newerVersion) }
                return .success(contents.items)
            } catch {
                return .failure(.unreadable(reason: reason(error)))
            }
        } catch {
            let notAllowed = error.code == EACCES || error.code == EPERM
            return .failure(.unreadable(reason: notAllowed ? Strings.ListFile.notAllowedToRead : nil))
        }
    }

    /// Writes `items`. Returns "Couldn't save: <reason>" if it couldn't.
    func write(_ items: [Item]) -> String? {
        guard let url else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.userInfo[ListContents<Item>.listKey] = kind.plural
        do throws(SecureFile.FileError) {
            guard let data = try? encoder.encode(ListContents(version: Self.currentVersion, items: items)) else {
                return Strings.ListFile.saveFailed(Strings.Files.plainWords(errno: EINVAL))
            }
            try SecureFile.write(data, to: url)
            return nil
        } catch {
            return Strings.ListFile.saveFailed(error.plainWords)
        }
    }

    /// Why the file didn't decode, short and plain: "the port of service 1 isn't valid". Nil
    /// when there is nothing useful to say.
    func reason(_ error: Error) -> String? {
        guard let error = error as? DecodingError else { return nil }
        let context: DecodingError.Context
        var missing: CodingKey?
        switch error {
        case .keyNotFound(let key, let found):
            context = found
            missing = key
        case .typeMismatch(_, let found), .valueNotFound(_, let found), .dataCorrupted(let found):
            context = found
        @unknown default:
            return nil
        }
        let path = context.codingPath
        // Not JSON at all.
        if path.isEmpty, case .dataCorrupted = error { return Strings.ListFile.notJSON }
        // A problem inside one item: <plural>[i] or <plural>[i].field.
        guard path.count >= 2, path[0].stringValue == kind.plural, let index = path[1].intValue else { return nil }
        if let missing, path.count == 2 {
            return Strings.ListFile.missing(Self.fieldName(missing.stringValue), item: kind.singular, number: index + 1)
        }
        guard path.count >= 3 else { return nil }
        return Strings.ListFile.wrong(Self.fieldName(path[2].stringValue), item: kind.singular, number: index + 1)
    }

    /// A key of the file in words.
    private static func fieldName(_ key: String) -> String {
        switch key {
        case "cwd": "folder"
        case "env": "environment"
        default: key
        }
    }
}

/// A key of a list file: "version", or the list's own.
private struct Key: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
    static let version = Key(stringValue: "version")
}

/// The file's contents, with the list under the key the coder's `userInfo` names.
private struct ListContents<Item: Codable>: Codable {
    static var listKey: CodingUserInfoKey { CodingUserInfoKey(rawValue: "headsup.listKey")! }

    var version: Int
    var items: [Item]

    init(version: Int, items: [Item]) {
        self.version = version
        self.items = items
    }

    private static func listKey(_ userInfo: [CodingUserInfoKey: Any]) -> Key {
        Key(stringValue: userInfo[listKey] as? String ?? "items")
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        items = try container.decodeIfPresent([Item].self, forKey: Self.listKey(decoder.userInfo)) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(version, forKey: .version)
        try container.encode(items, forKey: Self.listKey(encoder.userInfo))
    }
}

/// A list file's problem card, in its tab and in its Settings section (Yuki's copy).
public struct FileProblemCard: Equatable, Sendable {
    public let title: String
    public let text: String
    /// "Show in Finder": reveals the file.
    public let showInFinder: String
    /// "Try Again": reads the file again. Nil for a file from a newer version.
    public let tryAgain: String?

    init(_ problem: ListFileProblem, kind: ListFileKind) {
        title = Strings.ListFile.title(problem, kind: kind)
        text = Strings.ListFile.text(problem, kind: kind)
        showInFinder = Strings.ListFile.showInFinder
        if case .unreadable = problem {
            tryAgain = Strings.ListFile.tryAgain
        } else {
            tryAgain = nil
        }
    }
}

/// The question in a list editor's bottom bar, ready to draw (UX part 1, §1).
public enum FormBar: Equatable, Sendable {
    case none
    /// "Discard your changes?": `dismissBar()` or `discardForm()`.
    case discard(question: String, keep: String, discard: String)
    /// "Remove Postgres?": `dismissBar()` or `confirmRemove()`.
    case remove(question: String, cancel: String, remove: String)
}
