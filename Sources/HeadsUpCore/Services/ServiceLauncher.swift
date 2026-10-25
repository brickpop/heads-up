import Foundation

#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

/// How a service process ended.
public enum ProcessExit: Equatable, Sendable {
    case code(Int32)
    case signal(Int32)
}

/// A process the launcher started.
public struct LaunchedProcess: Equatable, Sendable {
    /// The process id, which is also its process group id.
    public let pid: Int32
    /// Whether it runs as its own responsible process, with its own permissions (F5). False
    /// when macOS has no way to do that, or refused it for this launch (R10).
    public let isolated: Bool

    public init(pid: Int32, isolated: Bool) {
        self.pid = pid
        self.isolated = isolated
    }
}

/// Starts service processes and signals their process groups (ADR-001 §7.2).
@MainActor
public protocol ServiceLauncher: AnyObject {
    /// Whether macOS lets HeadsUp start a service as its own responsible process (F5). When it
    /// doesn't, services start anyway, with HeadsUp's permissions (R10).
    var canDisclaim: Bool { get }
    /// Starts `plan` in a new process group. `output` gets stdout and stderr, merged, as they
    /// come; `exit` is called once, when the process ends. Both are called on a background thread.
    ///
    /// The process is not reaped when it ends: it stays a zombie until `reap(_:)`, which keeps
    /// its process group id from going to another process. So a SIGKILL sent to the group after
    /// the leader has exited still reaches only the service's own children.
    func launch(
        _ plan: SpawnPlan, output: @escaping @Sendable (Data) -> Void,
        exit: @escaping @Sendable (ProcessExit) -> Void
    ) throws(LaunchError) -> LaunchedProcess
    /// Sends `signal` to every process in the group `group`.
    func signal(group: Int32, _ signal: Int32)
    /// Releases a process whose exit was reported. Call it once, after the last signal to its group.
    func reap(_ pid: Int32)
}

public struct LaunchError: Error, Equatable, CustomStringConvertible {
    public let operation: String
    public let code: Int32
    public var description: String { "\(operation): \(String(cString: strerror(code)))" }
}

/// The real launcher, with `posix_spawn` (core, so it is tested on Linux).
///
/// - The process gets its own group (`POSIX_SPAWN_SETPGROUP`), so Stop reaches its children.
/// - Its folder is set with `posix_spawn_file_actions_addchdir_np` (F13): no `cd` in a shell line.
/// - stdin is /dev/null; stdout and stderr go to one pipe. No other file descriptor of HeadsUp
///   (its SQLite database, its sockets) reaches it: `POSIX_SPAWN_CLOEXEC_DEFAULT` on macOS,
///   `posix_spawn_file_actions_addclosefrom_np` on Linux (F5).
/// - On macOS, `responsibility_spawnattrs_setdisclaim` makes it its own responsible process,
///   so it doesn't use HeadsUp's Calendar, Reminders or Automation grants (F5). The symbol is
///   private, so it is looked up at run time; without it, `canDisclaim` is false (R10).
/// - The umask is left alone, so the service keeps the user's (S1).
/// - Its exit is seen with `waitid(..., WNOWAIT)`, which leaves it a zombie until `reap(_:)`.
@MainActor
public final class POSIXServiceLauncher: ServiceLauncher {
    public init() {}

    public var canDisclaim: Bool { Self.disclaim != nil }

    public func launch(
        _ plan: SpawnPlan, output: @escaping @Sendable (Data) -> Void,
        exit: @escaping @Sendable (ProcessExit) -> Void
    ) throws(LaunchError) -> LaunchedProcess {
        var pipeFDs: [Int32] = [0, 0]
        guard pipe(&pipeFDs) == 0 else { throw LaunchError(operation: "pipe", code: errno) }
        let (readFD, writeFD) = (pipeFDs[0], pipeFDs[1])
        // The parent's ends must not leak into other children.
        _ = fcntl(readFD, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeFD, F_SETFD, FD_CLOEXEC)

        let launched: LaunchedProcess
        do {
            launched = try spawn(plan, writeFD: writeFD)
        } catch {
            close(readFD)
            close(writeFD)
            throw error
        }
        close(writeFD)

        // One thread reads the output until every process holding the pipe has closed it;
        // another waits for the process itself. A daemon left behind may keep the pipe open
        // after the shell exits, so the two end separately.
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let count = buffer.withUnsafeMutableBytes { read(readFD, $0.baseAddress, $0.count) }
                if count > 0 {
                    output(Data(buffer[0..<count]))
                } else if count < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            close(readFD)
        }
        let pid = launched.pid
        Thread.detachNewThread {
            exit(Self.waitForExit(pid))
        }
        return launched
    }

    public func signal(group: Int32, _ signal: Int32) {
        guard group > 0 else { return }
        _ = kill(-group, signal)
    }

    public func reap(_ pid: Int32) {
        guard pid > 0 else { return }
        var status: Int32 = 0
        // Its exit was seen already, so this doesn't wait.
        while waitpid(pid, &status, WNOHANG) < 0 && errno == EINTR {}
    }

    // MARK: Spawning

    private func spawn(_ plan: SpawnPlan, writeFD: Int32) throws(LaunchError) -> LaunchedProcess {
        #if canImport(Darwin)
            var actions: posix_spawn_file_actions_t? = nil
            var attributes: posix_spawnattr_t? = nil
        #else
            var actions = posix_spawn_file_actions_t()
            var attributes = posix_spawnattr_t()
        #endif
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }

        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeFD, 1)
        posix_spawn_file_actions_adddup2(&actions, writeFD, 2)
        var status = posix_spawn_file_actions_addchdir_np(&actions, plan.directory)
        guard status == 0 else { throw LaunchError(operation: "chdir action", code: status) }

        var flags = Int32(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        #if canImport(Darwin)
            flags |= Int32(POSIX_SPAWN_CLOEXEC_DEFAULT)
        #else
            posix_spawn_file_actions_addclosefrom_np(&actions, 3)
        #endif
        posix_spawnattr_setflags(&attributes, Int16(truncatingIfNeeded: flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)

        // A non-zero result means macOS refused: the service starts with HeadsUp's permissions.
        var isolated = false
        #if canImport(Darwin)
            if let disclaim = Self.disclaim {
                isolated = disclaim(&attributes, 1) == 0
            }
        #endif

        var pid: Int32 = 0
        status = withCStrings(plan.arguments) { argv in
            withCStrings(plan.environment) { envp in
                posix_spawn(&pid, plan.executable, &actions, &attributes, argv, envp)
            }
        }
        guard status == 0 else { throw LaunchError(operation: "posix_spawn \(plan.executable)", code: status) }
        return LaunchedProcess(pid: pid, isolated: isolated)
    }

    /// Waits for `pid` to end and reports how, leaving it a zombie (`WNOWAIT`).
    nonisolated private static func waitForExit(_ pid: Int32) -> ProcessExit {
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) < 0 {
            if errno != EINTR { return .code(-1) }
        }
        #if canImport(Darwin)
            let status = info.si_status
        #else
            let status = info._sifields._sigchld.si_status
        #endif
        return info.si_code == CLD_EXITED ? .code(status) : .signal(status)
    }

    #if canImport(Darwin)
        private typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
        /// `responsibility_spawnattrs_setdisclaim`, if this macOS has it.
        private static let disclaim: Disclaim? = {
            guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim")
            else { return nil }
            return unsafeBitCast(symbol, to: Disclaim.self)
        }()
    #else
        /// Linux has no responsible processes.
        private static let disclaim: Int? = nil
    #endif
}

/// Calls `body` with `strings` as a NULL-terminated array of C strings.
private func withCStrings<Result>(
    _ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> Result
) -> Result {
    let pointers = strings.map { strdup($0) } + [nil]
    defer {
        for pointer in pointers { free(pointer) }
    }
    return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
}
