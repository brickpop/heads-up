import Foundation

#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

/// Looks at the ports of a running service (ADR-001 §7.2).
@MainActor
public protocol PortProbe: AnyObject {
    /// The TCP port the process group listens on, for a service with no port set.
    func listeningPort(group: Int32) async -> Int?
    /// Whether something on this Mac accepts a connection on `port`, for a service with a port
    /// set. It may be another process: `docker compose up` listens through Docker.
    func answers(port: Int) async -> Bool
}

/// The real probe.
///
/// - `listeningPort` runs `/usr/sbin/lsof`, by absolute path and with argv (F13):
///   `-nP -a -g <pgid> -iTCP -sTCP:LISTEN -Fn`. Where lsof is missing (our Linux sandboxes),
///   it finds nothing.
/// - `answers` connects to 127.0.0.1, then to ::1, and closes at once.
@MainActor
public final class SystemPortProbe: PortProbe {
    nonisolated static let lsof = "/usr/sbin/lsof"

    public init() {}

    public func listeningPort(group: Int32) async -> Int? {
        guard FileManager.default.isExecutableFile(atPath: Self.lsof) else { return nil }
        let output: String? = await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Self.lsof)
            process.arguments = ["-nP", "-a", "-g", String(group), "-iTCP", "-sTCP:LISTEN", "-Fn"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return nil
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }.value
        return output.flatMap(Self.firstPort)
    }

    public func answers(port: Int) async -> Bool {
        guard (1...65_535).contains(port) else { return false }
        return await Task.detached {
            Self.connects(family: AF_INET, port: UInt16(port)) || Self.connects(family: AF_INET6, port: UInt16(port))
        }.value
    }

    /// The first port in lsof's `-Fn` output: lines like `n*:3000` or `n127.0.0.1:5432`.
    nonisolated static func firstPort(_ output: String) -> Int? {
        for line in output.split(separator: "\n") where line.hasPrefix("n") {
            if let colon = line.lastIndex(of: ":"), let port = Int(line[line.index(after: colon)...]) {
                return port
            }
        }
        return nil
    }

    /// Whether a TCP connection to the loopback address of `family` on `port` is accepted.
    nonisolated private static func connects(family: Int32, port: UInt16) -> Bool {
        #if canImport(Glibc)
            let stream = Int32(SOCK_STREAM.rawValue)
        #else
            let stream = SOCK_STREAM
        #endif
        let socketFD = socket(family, stream, 0)
        guard socketFD >= 0 else { return false }
        defer { close(socketFD) }
        // Loopback answers at once; this only bounds a connect that hangs, to 300 ms.
        var timeout = timeval(tv_sec: 0, tv_usec: 300_000)
        _ = setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        if family == AF_INET {
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
            return withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            } == 0
        }
        var address = sockaddr_in6()
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = port.bigEndian
        address.sin6_addr = in6addr_loopback
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        } == 0
    }
}
