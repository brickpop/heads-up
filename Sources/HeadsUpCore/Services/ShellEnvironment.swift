import Foundation

#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

/// The environment of the user's terminal, for services. A login shell run with `-c` doesn't
/// read the files an interactive one does (`.zshrc`, `.bashrc`, fish's config), and that is where
/// most people set their PATH. So the login shell runs once as an interactive login shell and
/// prints its environment, as VS Code does, and services start from that.
public enum ShellEnvironment {
    /// Variables that belong to the shell that printed them, not to the user.
    static let dropped: Set<String> = ["PWD", "OLDPWD", "SHLVL", "_"]

    /// The command the shell runs: the environment, NUL-separated, between two marker lines.
    /// Only `printf`, `env -0` and `;`, so fish, zsh and bash all run it the same way. It holds
    /// nothing from the user.
    static func script(marker: String) -> String {
        "printf '\\n%s\\n' \(marker)_BEGIN; env -0; printf '\\n%s\\n' \(marker)_END"
    }

    /// The variables printed between the markers. Anything before or after them (a greeting, a
    /// prompt, an rc file's messages) is ignored. Nil without both markers, or with no variables.
    static func parse(_ output: Data, marker: String) -> [String: String]? {
        let begin = Data("\n\(marker)_BEGIN\n".utf8)
        // The end follows the NUL of the last variable; a value can't start a record with "\n".
        let end = Data("\0\n\(marker)_END\n".utf8)
        guard let start = output.range(of: begin)?.upperBound,
            let stop = output.range(of: end, in: start..<output.endIndex)?.lowerBound
        else { return nil }
        var environment: [String: String] = [:]
        for record in output[start..<stop].split(separator: 0) {
            guard let equals = record.firstIndex(of: UInt8(ascii: "=")), equals > record.startIndex,
                let key = String(data: record[record.startIndex..<equals], encoding: .utf8),
                let value = String(data: record[(equals + 1)...], encoding: .utf8),
                !dropped.contains(key)
            else { continue }
            environment[key] = value
        }
        return environment.isEmpty ? nil : environment
    }

    /// Where package managers put tools, in the order they are added to PATH.
    static func usualFolders(home: String) -> [String] {
        [
            "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", home + "/.local/bin", home + "/.cargo/bin",
            home + "/go/bin",
        ]
    }

    /// `path` with each of `folders` it lacks added at the end, in order: never before what the
    /// user set. Only a safe folder is added (see `isSafe`).
    static func appendingFolders(_ folders: [String], to path: String) -> String {
        var parts = path.split(separator: ":", omittingEmptySubsequences: true).map(String.init)
        for folder in folders where !parts.contains(folder) && isSafeFolder(folder) {
            parts.append(folder)
        }
        return parts.joined(separator: ":")
    }

    /// A folder that exists and that nobody but root and the user can change: its real path
    /// (links resolved), and every folder from / down to it, pass `isSafeChain` (Scan L1).
    static func isSafeFolder(_ path: String) -> Bool {
        guard let resolved = realpath(path, nil) else { return false }
        let real = String(cString: resolved)
        free(resolved)
        var info = stat()
        guard stat(real, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return false }
        var chain: [(owner: uid_t, mode: mode_t)] = []
        var folder = ""
        for part in [""] + real.split(separator: "/").map(String.init) {
            folder = part.isEmpty ? "/" : (folder == "/" ? "/" : folder + "/") + part
            guard lstat(folder, &info) == 0 else { return false }
            chain.append((info.st_uid, info.st_mode))
        }
        return isSafeChain(chain, user: getuid())
    }

    /// The folders from / down to a target, in order. Each is owned by root or `user` and not
    /// group- or world-writable. Only a sticky, world-writable folder like /tmp may be shared,
    /// and then only when the next folder down is `user`'s: others can't rename or remove it.
    static func isSafeChain(_ chain: [(owner: uid_t, mode: mode_t)], user: uid_t) -> Bool {
        var underSticky = false
        for (index, folder) in chain.enumerated() {
            if underSticky && folder.owner != user { return false }
            underSticky = false
            if isSafe(owner: folder.owner, mode: folder.mode, user: user) { continue }
            let isLast = index == chain.count - 1
            let ownedWell = folder.owner == 0 || folder.owner == user
            guard !isLast, ownedWell, folder.mode & S_ISVTX != 0 else { return false }
            underSticky = true
        }
        return !chain.isEmpty
    }

    /// Owned by root or `user`, and not group- or world-writable.
    static func isSafe(owner: uid_t, mode: mode_t, user: uid_t) -> Bool {
        (owner == 0 || owner == user) && mode & (S_IWGRP | S_IWOTH) == 0
    }
}

/// Reads the login shell's environment once (`ShellEnvironment`), through the service launcher,
/// so the shell runs as services do: in its own process group, with stdin from /dev/null, and
/// as its own responsible process.
@MainActor
final class ShellEnvironmentReader {
    /// How the read went: the environment, or why there is none.
    enum Outcome: Equatable {
        case read([String: String])
        case failed(reason: String)
    }

    /// An rc file that waits for input, or a slow one, ends the read after this long.
    static let timeout: TimeInterval = 5
    /// After the shell exits, how long its last output may still take to arrive; after it
    /// printed its environment, how long it has to exit before its group is killed (Scan L2).
    static let outputGrace: TimeInterval = 1
    /// More output than this is not an environment.
    static let outputLimit = 4 << 20

    private let launcher: ServiceLauncher
    private let clock: Clock
    private let scheduler: Scheduler
    private let loginShell: String
    private let home: String
    private let baseEnvironment: [String: String]

    private var marker = ""
    private var output = Data()
    /// Counts the reads, so a shell from an earlier one can't touch this one.
    private var generation = 0
    /// The shells that haven't exited yet, by read: each is reaped when it does.
    private var shells: [Int: Int32] = [:]
    private var deadline: ScheduledWork?
    private var grace: ScheduledWork?
    private var done: (@MainActor (Outcome) -> Void)?

    init(
        launcher: ServiceLauncher, clock: Clock, scheduler: Scheduler, loginShell: String, home: String,
        baseEnvironment: [String: String]
    ) {
        self.launcher = launcher
        self.clock = clock
        self.scheduler = scheduler
        self.loginShell = loginShell
        self.home = home
        self.baseEnvironment = baseEnvironment
    }

    var isReading: Bool { done != nil }

    /// Runs `<shell> -l -i -c <script>` from the home folder. `done` is called once, on the main
    /// actor; at once if the shell can't start.
    func read(_ done: @escaping @MainActor (Outcome) -> Void) {
        guard !isReading else { return }
        generation += 1
        let read = generation
        marker = "HEADSUP_ENV_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        output = Data()
        self.done = done
        // The login shell as it is, fish included: the script runs in any of them.
        let shell = loginShell.hasPrefix("/") ? loginShell : SpawnPlan.fallbackShell
        let plan = SpawnPlan(
            executable: shell, arguments: [shell, "-l", "-i", "-c", ShellEnvironment.script(marker: marker)],
            directory: home, environment: baseEnvironment)
        let launched: LaunchedProcess
        do {
            launched = try launcher.launch(
                plan,
                output: { [weak self] data in
                    Task { @MainActor in self?.received(data, read: read) }
                },
                exit: { [weak self] exit in
                    Task { @MainActor in self?.shellExited(exit, read: read) }
                })
        } catch {
            finish(.failed(reason: error.description))
            return
        }
        shells[read] = launched.pid
        deadline = scheduler.schedule(at: clock.now.addingTimeInterval(Self.timeout)) { [weak self] in
            self?.kill(read)
            self?.finish(.failed(reason: Strings.Services.environmentTimedOut(seconds: Int(Self.timeout))))
        }
    }

    /// Quitting: a read still running is killed.
    func cancel() {
        guard isReading else { return }
        kill(generation)
        done = nil
        deadline?.cancel()
        grace?.cancel()
    }

    private func received(_ data: Data, read: Int) {
        guard read == generation, isReading else { return }
        output.append(data)
        if let environment = ShellEnvironment.parse(output, marker: marker) {
            finish(.read(environment))
            // A shell that hasn't exited a second later is killed with its group (Scan L2). It
            // stays unreaped until it exits, so the group id stays its own.
            if shells[read] != nil {
                _ = scheduler.schedule(at: clock.now.addingTimeInterval(Self.outputGrace)) { [weak self] in
                    self?.kill(read)
                }
            }
        } else if output.count > Self.outputLimit {
            kill(read)
            finish(.failed(reason: Strings.Services.environmentTooLong))
        }
    }

    /// The shell is reaped at once: it is never signalled after that, so no signal can reach a
    /// process group that went to another process.
    private func shellExited(_ exit: ProcessExit, read: Int) {
        if let pid = shells.removeValue(forKey: read) { launcher.reap(pid) }
        guard read == generation, isReading else { return }
        deadline?.cancel()
        let reason = Strings.Services.environmentNotPrinted(exit)
        grace = scheduler.schedule(at: clock.now.addingTimeInterval(Self.outputGrace)) { [weak self] in
            self?.finish(.failed(reason: reason))
        }
    }

    private func kill(_ read: Int) {
        if let pid = shells[read] { launcher.signal(group: pid, SIGKILL) }
    }

    private func finish(_ outcome: Outcome) {
        guard let done else { return }
        self.done = nil
        deadline?.cancel()
        grace?.cancel()
        done(outcome)
    }
}
