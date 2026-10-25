import Foundation
import Observation

/// What is wrong with settings.json, if anything (ADR-001 amendment 3, UX settings-file copy).
public enum SettingsFileProblem: Equatable, Sendable {
    /// It couldn't be read, so it was renamed to this file and kept. Saving works.
    case keptAside(URL)
    /// It couldn't be read, or moved aside. Saving is off, so it is never overwritten.
    case unreadable(URL)
    /// A newer HeadsUp wrote it. Saving is off, so the newer version keeps its settings.
    case newerVersion(URL)
    /// A later save failed, with the reason in plain words. Changes are kept in memory.
    case saveFailed(String)
}

/// Owns settings.json (ADR-001 §6.1): loads it at launch and writes it after each change.
///
/// - A missing file means defaults, and nothing is created until the user changes something.
/// - A file that doesn't decode is renamed `settings.broken-<date>.json` and kept; defaults load.
/// - A file it must not overwrite (written by a newer HeadsUp, or one it can't read or move
///   aside) is left alone: defaults load, and changes apply for this run only.
@MainActor
@Observable
public final class SettingsStore {
    public private(set) var settings: Settings
    public private(set) var fileProblem: SettingsFileProblem?
    /// The raw error behind the last problem, for the log.
    public private(set) var lastErrorDetail: String?

    /// False while the file on disk must not be overwritten.
    public var savingEnabled: Bool {
        switch fileProblem {
        case .unreadable, .newerVersion: false
        case .keptAside, .saveFailed, nil: true
        }
    }

    /// The file, or nil for a store that keeps settings in memory only (previews).
    private let file: URL?

    public static let fileName = "settings.json"

    /// HeadsUp's data folder: ~/Library/Application Support/HeadsUp on macOS.
    public static var defaultFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HeadsUp", isDirectory: true)
    }

    /// Loads settings.json from `folder`, or keeps settings in memory when `folder` is nil.
    public init(folder: URL?, clock: Clock, initial: Settings = Settings()) {
        settings = initial
        guard let folder else {
            file = nil
            return
        }
        let file = folder.appendingPathComponent(Self.fileName)
        self.file = file
        load(file, clock: clock)
    }

    /// Changes settings and saves them.
    public func update(_ change: (inout Settings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        settings = next
        save()
    }

    public func setShortcut(_ shortcut: Shortcut) {
        update { $0.general.shortcut = shortcut }
    }

    public func markWelcomeDone() {
        update { $0.general.welcomeDone = true }
    }

    // MARK: Loading

    /// Only the version, decoded first: a newer file is recognised even when the rest of it
    /// doesn't decode, so it is never moved aside.
    private struct VersionOnly: Decodable {
        var version: Int?
    }

    private func load(_ file: URL, clock: Clock) {
        let data: Data
        do throws(SecureFile.FileError) {
            try SecureFile.checkFolder(file.deletingLastPathComponent())
            guard let read = try SecureFile.read(file) else { return }
            data = read
        } catch {
            report(.unreadable(file), detail: error.description)
            return
        }

        let decoder = JSONDecoder()
        if let version = (try? decoder.decode(VersionOnly.self, from: data))?.version,
            version > Settings.currentVersion
        {
            report(.newerVersion(file), detail: "settings.json has version \(version)")
            return
        }
        do {
            settings = try decoder.decode(Settings.self, from: data)
        } catch {
            setAside(file, clock: clock, reason: "\(error)")
        }
    }

    /// Renames a broken file so it is kept, and the next save starts a new one.
    private func setAside(_ file: URL, clock: Clock, reason: String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let stamp = formatter.string(from: clock.now)
        let folder = file.deletingLastPathComponent()

        for attempt in 1...100 {
            let suffix = attempt == 1 ? "" : "-\(attempt)"
            let target = folder.appendingPathComponent("settings.broken-\(stamp)\(suffix).json")
            if FileManager.default.fileExists(atPath: target.path) { continue }
            do {
                try FileManager.default.moveItem(at: file, to: target)
                report(.keptAside(target), detail: reason)
            } catch {
                report(.unreadable(file), detail: "\(reason); then moving it aside failed: \(error)")
            }
            return
        }
        report(.unreadable(file), detail: "\(reason); no free name to move it aside")
    }

    // MARK: Saving

    private func save() {
        guard let file, savingEnabled else { return }
        do throws(SecureFile.FileError) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(settings) else { return }
            try SecureFile.write(data, to: file)
            if case .saveFailed = fileProblem { fileProblem = nil }
        } catch {
            report(.saveFailed(error.plainWords), detail: error.description)
        }
    }

    private func report(_ problem: SettingsFileProblem, detail: String) {
        fileProblem = problem
        lastErrorDetail = detail
    }

    #if DEBUG
        /// Puts the store in a problem state without a file, for previews.
        func showProblemForPreview(_ problem: SettingsFileProblem) {
            fileProblem = problem
        }
    #endif
}
