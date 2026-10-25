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
    /// The user chose default settings; the old file is kept under this name. Saving works.
    case defaultsChosen(keptAs: URL)
    /// A later save failed, with the reason in plain words. Changes are kept in memory.
    /// `keptAs` names the old file if Use Defaults moved it aside before the save failed.
    case saveFailed(String, keptAs: URL? = nil)

    /// Whether the card shows a ×: only for a file kept aside, the rule `dismissFileProblem()` follows.
    public var canBeDismissed: Bool {
        switch self {
        case .keptAside, .defaultsChosen: true
        case .unreadable, .newerVersion, .saveFailed: false
        }
    }
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
        case .keptAside, .defaultsChosen, .saveFailed, nil: true
        }
    }

    /// The file, or nil for a store that keeps settings in memory only (previews).
    private let file: URL?
    @ObservationIgnored private let clock: Clock
    /// The name chosen when the Use Defaults confirm opened.
    private var useDefaultsTarget: URL?
    @ObservationIgnored private weak var toaster: Toaster?
    @ObservationIgnored private weak var revealer: FileRevealer?

    public static let fileName = "settings.json"

    /// HeadsUp's data folder: ~/Library/Application Support/HeadsUp on macOS.
    public static var defaultFolder: URL {
        dataFolder(quickTimers: false)
    }

    /// HeadsUp's data folder, or the debug quick-timers build's own one
    /// (~/Library/Application Support/HeadsUp-Quick), so `just app-quick` never touches the
    /// real settings and stats.
    public static func dataFolder(
        quickTimers: Bool,
        applicationSupport: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    ) -> URL {
        applicationSupport.appendingPathComponent(quickTimers ? "HeadsUp-Quick" : "HeadsUp", isDirectory: true)
    }

    /// Loads settings.json from `folder`, or keeps settings in memory when `folder` is nil.
    public init(folder: URL?, clock: Clock, initial: Settings = Settings()) {
        self.clock = clock
        settings = initial
        guard let folder else {
            file = nil
            return
        }
        let file = folder.appendingPathComponent(Self.fileName)
        self.file = file
        load(file)
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

    /// Refreshes the wake shortcut's keycap label for the current keyboard layout. The shell
    /// calls it at launch and when the input source changes. It changes the label in memory
    /// only (amendment 4): saving here would create settings.json on a fresh install. The
    /// label is written with the next real change.
    public func updateShortcutLabel(_ key: String) {
        let current = settings.general.shortcut
        guard current.key != key else { return }
        settings.general.shortcut = Shortcut(keyCode: current.keyCode, modifiers: current.modifiers, key: key)
    }

    // MARK: Settings-file problem actions (amendment 3)

    /// Connects the ports these actions use, once AppModel has them.
    func attach(toaster: Toaster, revealer: FileRevealer) {
        self.toaster = toaster
        self.revealer = revealer
    }

    /// Show in Finder: the file kept aside, or settings.json, or the folder when there is no file.
    public func revealSettingsFile() {
        guard let file else { return }
        let target: URL =
            switch fileProblem {
            case .keptAside(let kept), .defaultsChosen(let kept), .saveFailed(_, let kept?): kept
            case .unreadable(let url), .newerVersion(let url): url
            case .saveFailed(_, nil), nil:
                FileManager.default.fileExists(atPath: file.path) ? file : file.deletingLastPathComponent()
            }
        revealer?.reveal(target)
    }

    /// The inline question before Use Defaults, naming the file the old one will be kept as.
    /// It is set between `beginUseDefaults()` and the run or cancel, so the name the user
    /// reads is the name on disk.
    public var useDefaultsConfirmation: String? {
        guard let problem = fileProblem, let target = useDefaultsTarget else { return nil }
        return Strings.SettingsFile.confirm(problem, keptAs: target.lastPathComponent)
    }

    /// The card's Use Defaults and Save… button: the inline confirm opens, and the name the old
    /// file will be kept under is chosen now, once.
    public func beginUseDefaults() {
        guard let file, let problem = fileProblem, let kind = Self.keptAsideKind(problem) else { return }
        useDefaultsTarget = keptAsideName(for: file, kind: kind)
    }

    /// The confirm's Cancel.
    public func cancelUseDefaults() {
        useDefaultsTarget = nil
    }

    /// Use Defaults, after the user confirmed it in the card (Scan L2): first keeps the old file
    /// under the confirmed name (`settings.newer-<date>.json` or `settings.broken-<date>.json`),
    /// then writes default settings and turns saving on. If the file can't be moved aside,
    /// nothing is replaced. If the save fails after the move, the problem still names the kept
    /// file, so the user can find it.
    public func useDefaultsAndSave() {
        guard let file, let problem = fileProblem, let kind = Self.keptAsideKind(problem) else { return }
        let confirmed = useDefaultsTarget ?? keptAsideName(for: file, kind: kind)
        useDefaultsTarget = nil
        var kept: URL?
        if FileManager.default.fileExists(atPath: file.path) {
            guard let target = confirmed, !FileManager.default.fileExists(atPath: target.path) else {
                report(
                    .saveFailed(Strings.Files.plainWords(errno: EEXIST)), detail: "no free name to keep \(file.path)")
                return
            }
            do {
                try FileManager.default.moveItem(at: file, to: target)
                kept = target
            } catch {
                let code = ((error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError)?.code ?? Int(EACCES)
                report(.saveFailed(Strings.Files.plainWords(errno: Int32(code))), detail: "\(error)")
                return
            }
            #if DEBUG
                afterMovingAside?()
            #endif
        }
        settings = Settings()
        fileProblem = kept.map { .defaultsChosen(keptAs: $0) }
        if save() { toaster?.toast(Strings.SettingsFile.saved) }
    }

    #if DEBUG
        /// Runs between the move and the save, so a test can make the save fail there.
        @ObservationIgnored var afterMovingAside: (() -> Void)?
    #endif

    /// The old file Use Defaults kept aside, while its card or a later failure shows it.
    private var keptByUseDefaults: URL? {
        switch fileProblem {
        case .defaultsChosen(let kept): kept
        case .saveFailed(_, let kept): kept
        default: nil
        }
    }

    /// Which kind of file Use Defaults keeps aside, for the problems that offer it.
    private static func keptAsideKind(_ problem: SettingsFileProblem) -> String? {
        switch problem {
        case .unreadable: "broken"
        case .newerVersion: "newer"
        case .keptAside, .defaultsChosen, .saveFailed: nil
        }
    }

    /// Try Again, after a save failed.
    public func retrySave() {
        guard case .saveFailed = fileProblem else { return }
        if save() { toaster?.toast(Strings.SettingsFile.saved) }
    }

    /// The × on a card about a file kept aside. Other problems stay until fixed.
    public func dismissFileProblem() {
        guard fileProblem?.canBeDismissed == true else { return }
        fileProblem = nil
    }

    // MARK: Loading

    /// Only the version, decoded first: a newer file is recognised even when the rest of it
    /// doesn't decode, so it is never moved aside.
    private struct VersionOnly: Decodable {
        var version: Int?
    }

    private func load(_ file: URL) {
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
            setAside(file, reason: "\(error)")
        }
    }

    /// Renames a broken file so it is kept, and the next save starts a new one.
    private func setAside(_ file: URL, reason: String) {
        guard let target = keptAsideName(for: file, kind: "broken") else {
            report(.unreadable(file), detail: "\(reason); no free name to move it aside")
            return
        }
        do {
            try FileManager.default.moveItem(at: file, to: target)
            report(.keptAside(target), detail: reason)
        } catch {
            report(.unreadable(file), detail: "\(reason); then moving it aside failed: \(error)")
        }
    }

    /// A free name next to `file` to keep it under: `settings.<kind>-<date>.json`, then `-2`, `-3`…
    private func keptAsideName(for file: URL, kind: String) -> URL? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let stamp = formatter.string(from: clock.now)
        let folder = file.deletingLastPathComponent()
        for attempt in 1...100 {
            let suffix = attempt == 1 ? "" : "-\(attempt)"
            let target = folder.appendingPathComponent("settings.\(kind)-\(stamp)\(suffix).json")
            if !FileManager.default.fileExists(atPath: target.path) { return target }
        }
        return nil
    }

    // MARK: Saving

    /// Writes the settings; returns whether they are on disk now.
    @discardableResult
    private func save() -> Bool {
        guard let file, savingEnabled else { return false }
        do throws(SecureFile.FileError) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(settings) else { return false }
            try SecureFile.write(data, to: file)
            if case .saveFailed(_, let kept) = fileProblem { fileProblem = kept.map { .defaultsChosen(keptAs: $0) } }
            return true
        } catch {
            report(.saveFailed(error.plainWords, keptAs: keptByUseDefaults), detail: error.description)
            return false
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

extension SettingsStore {
    // MARK: Settings → Tools

    /// Settings → Tools: one row per tool, with the values it may take.
    public var toolsScreen: ToolsSettingsScreen {
        let tools = settings.tools
        return ToolsSettingsScreen(
            title: Strings.Tools.title, intro: Strings.Tools.intro,
            rows: ToolID.allCases.map { tool in
                ToolsSettingsScreen.Row(
                    id: tool, glyph: tool.glyph, label: Strings.Tools.label(tool),
                    description: Strings.Tools.description(tool), fn: tool.displayName,
                    choices: tool.allowed.map {
                        ToolsSettingsScreen.Choice(permission: $0, title: Strings.Tools.permission($0))
                    },
                    selected: tools[tool], help: tool.effect == .write ? Strings.Tools.alwaysAsks : nil)
            })
    }

    /// A segment in Settings → Tools, or Always allow on a card. It applies to the next tool
    /// call. Allow is refused for a write (F4).
    public func setToolPermission(_ tool: ToolID, _ permission: ToolPermission) {
        guard tool.allowed.contains(permission) else { return }
        update { $0.tools[tool] = permission }
    }
}
