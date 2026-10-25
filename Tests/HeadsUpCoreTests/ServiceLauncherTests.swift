import Foundation
import Testing

@testable import HeadsUpCore

#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

/// Output and the exit of one launched process, collected from the launcher's threads.
private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var exitStatus: ProcessExit?

    func add(_ data: Data) { lock.withLock { bytes.append(data) } }
    func exited(_ status: ProcessExit) { lock.withLock { exitStatus = status } }
    var text: String { lock.withLock { String(decoding: bytes, as: UTF8.self) } }
    var exit: ProcessExit? { lock.withLock { exitStatus } }
}

/// Waits up to `seconds` for `condition`, checking every 10 ms.
@MainActor
private func waitUntil(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

/// Whether a process is gone, or only a zombie (the container's init may not reap at once).
private func isGone(_ pid: Int32) -> Bool {
    guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8) else {
        return kill(pid, 0) != 0
    }
    // The state is the field after the ")" that ends the command name.
    guard let close = stat.lastIndex(of: ")") else { return false }
    return stat[stat.index(close, offsetBy: 2)] == "Z"
}

@MainActor
@Suite(.serialized) struct ServiceLauncherTests {
    let launcher = POSIXServiceLauncher()

    private func plan(_ command: String, cwd: String = "/tmp", env: [EnvironmentVariable] = []) -> SpawnPlan {
        SpawnPlan(
            definition: ServiceDefinition(name: "Test", command: command, cwd: cwd, env: env),
            loginShell: "/bin/sh", home: NSHomeDirectory(),
            baseEnvironment: ["PATH": "/usr/bin:/bin"])
    }

    private func run(_ plan: SpawnPlan) async throws -> (pid: Int32, out: Collected) {
        let out = Collected()
        let launched = try launcher.launch(plan, output: { out.add($0) }, exit: { out.exited($0) })
        return (launched.pid, out)
    }

    private func temporaryFolder(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("headsup-svc-\(UUID().uuidString)")
        let folder = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func itRunsInAFolderWithAQuoteInItsName() async throws {
        let folder = try temporaryFolder("it's here")
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let (_, out) = try await run(plan("pwd", cwd: folder.path))
        #expect(await waitUntil { out.exit != nil })
        #expect(out.text == folder.path + "\n")
        #expect(out.exit == .code(0))
    }

    @Test func itRunsInAFolderStartingWithADash() async throws {
        let folder = try temporaryFolder("-rf")
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let (_, out) = try await run(plan("pwd", cwd: folder.path))
        #expect(await waitUntil { out.exit != nil })
        #expect(out.text == folder.path + "\n")
    }

    @Test func aMissingFolderFailsToStart() {
        #expect(throws: LaunchError.self) {
            _ = try launcher.launch(plan("true", cwd: "/no/such/folder"), output: { _ in }, exit: { _ in })
        }
    }

    @Test func theServiceGetsItsEnvironment() async throws {
        let (_, out) = try await run(
            plan(#"printf %s "$TOKEN""#, env: [EnvironmentVariable(key: "TOKEN", value: "s3cret")]))
        #expect(await waitUntil { out.exit != nil })
        #expect(out.text == "s3cret")
    }

    @Test func stdoutAndStderrAreMerged() async throws {
        let (_, out) = try await run(plan("echo out; echo err >&2"))
        #expect(await waitUntil { out.exit != nil && out.text.contains("err") })
        #expect(out.text.contains("out\n") && out.text.contains("err\n"))
    }

    @Test func theUsersUmaskIsKept() async throws {
        let current = umask(0o022)
        umask(current)
        let (_, out) = try await run(plan("umask"))
        #expect(await waitUntil { out.exit != nil })
        #expect(Int(out.text.trimmingCharacters(in: .whitespacesAndNewlines), radix: 8) == Int(current))
    }

    @Test func noOtherFileDescriptorOfHeadsUpReachesTheService() async throws {
        // An open file in HeadsUp, standing for its SQLite database.
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("headsup-fd-\(UUID().uuidString)").path
        let fd = open(path, O_RDWR | O_CREAT, 0o600)
        defer {
            close(fd)
            unlink(path)
        }
        #expect(fd > 2)
        // /proc/self/fd lists the shell's own descriptors (Linux).
        let (_, out) = try await run(plan("ls /proc/$$/fd"))
        #expect(await waitUntil { out.exit != nil })
        let open = out.text.split(separator: "\n").compactMap { Int32($0) }
        #expect(!open.contains(fd))
        #expect(Set(open).isSuperset(of: [0, 1, 2]))
    }

    @Test func anExitCodeIsReported() async throws {
        let (_, out) = try await run(plan("exit 3"))
        #expect(await waitUntil { out.exit != nil })
        #expect(out.exit == .code(3))
    }

    @Test func stopReachesTheWholeGroup() async throws {
        let (pid, out) = try await run(plan("sleep 300 & echo $!; wait"))
        #expect(await waitUntil { !out.text.isEmpty })
        let child = try #require(Int32(out.text.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(!isGone(child))
        launcher.signal(group: pid, SIGTERM)
        #expect(await waitUntil { out.exit != nil })
        #expect(out.exit == .signal(SIGTERM))
        #expect(await waitUntil { isGone(child) })
    }

    // Scan M1: the leader stays ours until reaped, so its group id can't go to another process
    // before the SIGKILL.
    @Test func anExitedProcessIsKeptUntilItIsReaped() async throws {
        let (pid, out) = try await run(plan("exit 3"))
        #expect(await waitUntil { out.exit != nil })
        #expect(out.exit == .code(3))
        #expect(kill(pid, 0) == 0)  // a zombie, still holding its pid and group id
        launcher.reap(pid)
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test func linuxHasNoResponsibleProcessesToDisclaim() throws {
        #if canImport(Glibc)
            #expect(!launcher.canDisclaim)
            let launched = try launcher.launch(plan("true"), output: { _ in }, exit: { _ in })
            #expect(!launched.isolated)
        #endif
    }
}

@MainActor
@Suite(.serialized) struct SystemPortProbeTests {
    /// A TCP socket listening on 127.0.0.1, on a port the system picks.
    private func listeningSocket() throws -> (fd: Int32, port: Int) {
        #if canImport(Glibc)
            let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
            let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        try #require(fd >= 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && listen(fd, 1) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        try #require(bound)
        return (fd, Int(UInt16(bigEndian: address.sin_port)))
    }

    @Test func aListeningPortAnswersAndAClosedOneDoesnt() async throws {
        let probe = SystemPortProbe()
        let (fd, port) = try listeningSocket()
        #expect(await probe.answers(port: port))
        close(fd)
        #expect(await !probe.answers(port: port))
        #expect(await !probe.answers(port: 0))
        #expect(await !probe.answers(port: 70_000))
    }
}
