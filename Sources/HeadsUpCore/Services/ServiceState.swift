import Foundation

/// Where a service is (ADR-001 §4.2; UX part 1 §9, addendum 4).
public enum ServiceState: Equatable, Sendable {
    case stopped
    /// Just started: for its first seconds, or until its port answers.
    case starting(pid: Int32, since: Date)
    case running(pid: Int32, since: Date, port: Int?)
    /// It exited without being asked to. `exitCode` is 128 + the signal for a signal.
    case failed(exitCode: Int32, at: Date)

    /// The process, while there is one.
    public var pid: Int32? {
        switch self {
        case .starting(let pid, _), .running(let pid, _, _): pid
        case .stopped, .failed: nil
        }
    }

    public var isLive: Bool { pid != nil }
}

/// What the menu bar, the menu and the tab dot need from Services.
public struct ServicesSnapshot: Equatable, Sendable {
    public var running = 0
    public var starting = 0
    public var failed = 0

    public init(running: Int = 0, starting: Int = 0, failed: Int = 0) {
        self.running = running
        self.starting = starting
        self.failed = failed
    }
}
