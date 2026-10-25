import Foundation
import Testing

@testable import HeadsUpCore

#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

/// A new, empty temporary folder; `data` is a subfolder that doesn't exist yet,
/// like ~/Library/Application Support/HeadsUp on a fresh install.
private struct TempFolder {
    let root: URL
    var data: URL { root.appendingPathComponent("Application Support/HeadsUp", isDirectory: true) }
    var settingsFile: URL { data.appendingPathComponent("settings.json") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("headsup-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        chmod(data.path, 0o700)
        try? FileManager.default.removeItem(at: root)
    }

    func write(_ text: String) throws {
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: settingsFile)
    }

    func read() throws -> String {
        try String(contentsOf: settingsFile, encoding: .utf8)
    }

    func files() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: data.path).sorted()
    }
}

private func mode(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as! NSNumber).intValue & 0o777
}

// Serialized: one test changes the process umask.
@MainActor
@Suite(.serialized) struct SettingsStoreTests {
    @Test func aFreshInstallCreatesNothingUntilSomethingChanges() throws {
        let folder = try TempFolder()
        defer { folder.remove() }

        let store = SettingsStore(folder: folder.data, clock: ManualClock())
        #expect(store.settings == Settings())
        #expect(!FileManager.default.fileExists(atPath: folder.data.path))

        // Setting the value it already has is no change, so nothing is written.
        store.update { $0.general.appearance = .system }
        #expect(!FileManager.default.fileExists(atPath: folder.data.path))
    }

    // 0o277 would take the owner's write bit away: only an explicit chmod gives 0700 and 0600.
    @Test(arguments: [0o022, 0o000, 0o077, 0o277])
    func theFolderIs0700AndTheFile0600WhateverTheUmask(umaskValue: Int) throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        // Application Support exists on every Mac; only HeadsUp's own folder is new.
        try FileManager.default.createDirectory(
            at: folder.data.deletingLastPathComponent(), withIntermediateDirectories: true)
        let previous = umask(mode_t(umaskValue))
        defer { umask(previous) }

        let store = SettingsStore(folder: folder.data, clock: ManualClock())
        store.markWelcomeDone()

        #expect(try mode(folder.data) == 0o700)
        #expect(try mode(folder.settingsFile) == 0o600)
        #expect(store.fileProblem == nil)
        // The store leaves the process umask alone, so services keep the user's own.
        #expect(umask(previous) == mode_t(umaskValue))
    }

    @Test func changesAreSavedAndLoadedAgain() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let commandK = Shortcut(keyCode: 40, modifiers: .command, key: "K")

        let first = SettingsStore(folder: folder.data, clock: ManualClock())
        first.setShortcut(commandK)
        first.update { $0.general.closeOnClickOutside = false }

        let second = SettingsStore(folder: folder.data, clock: ManualClock())
        #expect(second.settings.general.shortcut == commandK)
        #expect(second.settings.general.shortcut.key == "K")
        #expect(second.settings.general.closeOnClickOutside == false)
        // Only settings.json: no temporary file is left behind.
        #expect(try folder.files() == ["settings.json"])
    }

    @Test func aBrokenFileIsKeptUnderANewNameAndDefaultsLoad() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        try folder.write("{ \"general\": { \"menuSeconds\": tru")
        let clock = ManualClock(now: Date(timeIntervalSince1970: 0))

        let store = SettingsStore(folder: folder.data, clock: clock)
        #expect(store.settings == Settings())
        guard case .keptAside(let kept) = store.fileProblem else {
            Issue.record("expected keptAside, got \(String(describing: store.fileProblem))")
            return
        }
        #expect(store.savingEnabled)
        #expect(kept.lastPathComponent.hasPrefix("settings.broken-"))
        #expect(try String(contentsOf: kept, encoding: .utf8) == "{ \"general\": { \"menuSeconds\": tru")
        #expect(Strings.SettingsFile.text(.keptAside(kept)).contains(kept.lastPathComponent))

        // The next save writes a new settings.json; the broken copy stays.
        store.markWelcomeDone()
        #expect(try folder.files() == [kept.lastPathComponent, "settings.json"].sorted())
    }

    @Test func aSecondBrokenFileInTheSameSecondGetsItsOwnName() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let clock = ManualClock()
        try folder.write("not json")
        _ = SettingsStore(folder: folder.data, clock: clock)
        try folder.write("still not json")
        let second = SettingsStore(folder: folder.data, clock: clock)
        guard case .keptAside(let kept) = second.fileProblem else {
            Issue.record("expected keptAside")
            return
        }
        #expect(kept.lastPathComponent.hasSuffix("-2.json"))
        #expect(try folder.files().count == 2)
    }

    @Test func aFileFromAnOlderVersionLoadsWithDefaultsForWhatItLacks() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        try folder.write(#"{ "general": { "menuSeconds": true } }"#)

        let store = SettingsStore(folder: folder.data, clock: ManualClock())
        #expect(store.settings.general.menuSeconds == true)
        #expect(store.settings.general.closeOnClickOutside == true)
        #expect(store.settings.general.shortcut == .wakeDefault)
        #expect(store.fileProblem == nil)
    }

    @Test func aFileFromANewerVersionIsNeverOverwritten() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let newer = #"{ "version": 99, "general": { "menuSeconds": true }, "future": [1, 2] }"#
        try folder.write(newer)

        let store = SettingsStore(folder: folder.data, clock: ManualClock())
        #expect(store.fileProblem == .newerVersion(folder.settingsFile))
        #expect(!store.savingEnabled)
        #expect(store.settings == Settings())
        store.update { $0.general.menuSeconds = true }
        #expect(store.settings.general.menuSeconds == true)
        #expect(try folder.read() == newer)
        #expect(try folder.files() == ["settings.json"])
    }

    @Test func aNewerFileWithAWrongTypeStaysInPlace() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let newer = #"{"version": 99, "general": {"menuSeconds": "yes"}}"#
        try folder.write(newer)

        let store = SettingsStore(folder: folder.data, clock: ManualClock())
        #expect(store.fileProblem == .newerVersion(folder.settingsFile))
        #expect(!store.savingEnabled)
        store.markWelcomeDone()
        #expect(try folder.read() == newer)
        #expect(try folder.files() == ["settings.json"])
    }

    @Test func aNewerFileThatDoesntDecodeStaysInPlace() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        // A value this version doesn't know: the whole file fails to decode, but its version is read first.
        let newer = #"{ "version": 2, "general": { "appearance": "highContrast" } }"#
        try folder.write(newer)

        let store = SettingsStore(folder: folder.data, clock: ManualClock())
        #expect(store.fileProblem == .newerVersion(folder.settingsFile))
        store.markWelcomeDone()
        #expect(try folder.read() == newer)
        #expect(try folder.files() == ["settings.json"])
    }

    @Test func aFolderOthersCanReadIsNarrowedAtLoadAndTheFileToo() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        try folder.write(#"{ "general": { "menuSeconds": true } }"#)
        chmod(folder.data.path, 0o755)
        chmod(folder.settingsFile.path, 0o644)

        let store = SettingsStore(folder: folder.data, clock: ManualClock())
        #expect(store.fileProblem == nil)
        #expect(store.settings.general.menuSeconds == true)
        #expect(try mode(folder.data) == 0o700)
        #expect(try mode(folder.settingsFile) == 0o600)
    }

    @Test func aFolderThatIsALinkIsNeitherReadNorWritten() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let elsewhere = folder.root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data(#"{ "general": { "menuSeconds": true } }"#.utf8).write(
            to: elsewhere.appendingPathComponent("settings.json"))
        try FileManager.default.createDirectory(
            at: folder.data.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: folder.data, withDestinationURL: elsewhere)

        let store = SettingsStore(folder: folder.data, clock: ManualClock())
        #expect(store.fileProblem == .unreadable(folder.settingsFile))
        #expect(!store.savingEnabled)
        #expect(store.settings == Settings())
        store.markWelcomeDone()
        #expect(
            try String(contentsOf: elsewhere.appendingPathComponent("settings.json"), encoding: .utf8)
                == #"{ "general": { "menuSeconds": true } }"#)
    }

    @Test func aFileThatIsALinkIsNotFollowed() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        try FileManager.default.createDirectory(at: folder.data, withIntermediateDirectories: true)
        let target = folder.root.appendingPathComponent("target.json")
        try Data(#"{ "general": { "menuSeconds": true } }"#.utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: folder.settingsFile, withDestinationURL: target)

        let store = SettingsStore(folder: folder.data, clock: ManualClock())
        #expect(store.fileProblem == .unreadable(folder.settingsFile))
        #expect(store.settings == Settings())
    }

    @Test func aFailedSaveKeepsTheFileAsItWasAndSaysWhyInPlainWords() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let store = SettingsStore(folder: folder.data, clock: ManualClock())
        store.update { $0.general.menuSeconds = true }
        let saved = try folder.read()

        // The folder becomes read-only: the write can't start.
        chmod(folder.data.path, 0o500)
        store.update { $0.general.menuSeconds = false }
        chmod(folder.data.path, 0o700)

        #expect(store.fileProblem == .saveFailed("HeadsUp isn't allowed to write to its settings folder."))
        #expect(store.lastErrorDetail?.contains("Permission denied") == true)
        #expect(store.savingEnabled)
        #expect(try folder.read() == saved)
        #expect(try folder.files() == ["settings.json"])

        // The next change that saves clears the problem.
        store.update { $0.general.clearOnClose = true }
        #expect(store.fileProblem == nil)
    }

    @Test func fileErrorsReadInPlainWords() {
        #expect(Strings.Files.plainWords(errno: ENOSPC) == "The disk is full.")
        #expect(Strings.Files.plainWords(errno: EROFS) == "The disk is read-only.")
        #expect(Strings.Files.plainWords(errno: EACCES) == "HeadsUp isn't allowed to write to its settings folder.")
        #expect(Strings.Files.plainWords(errno: EIO) == "The file couldn't be written.")
    }

    @Test func aStoreWithNoFolderKeepsSettingsInMemory() {
        let store = SettingsStore(folder: nil, clock: ManualClock())
        store.markWelcomeDone()
        #expect(store.settings.general.welcomeDone)
        #expect(store.fileProblem == nil)
    }
}
