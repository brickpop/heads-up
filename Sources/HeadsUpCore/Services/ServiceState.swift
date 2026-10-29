import Foundation

/// Where a service is (ADR-001 §4.2; UX part 1 §9, addendum 4; service flags addendum §2).
public enum ServiceState: Equatable, Sendable {
    case stopped
    /// Just started: for its first seconds, or until its port answers.
    case starting(pid: Int32, since: Date)
    case running(pid: Int32, since: Date, port: Int?)
    /// It stopped without being asked to, with Restart on: restart `attempt` (1 to
    /// `ServiceStore.maxRestarts`) runs at `at`. `lastExit` is the exit code, or 128 + the
    /// signal. There is no process meanwhile.
    case waitingToRestart(attempt: Int, at: Date, lastExit: Int32)
    /// It exited without being asked to. `exitCode` is 128 + the signal for a signal.
    /// `gaveUpSince` is set when HeadsUp gave up restarting it: the time of the first
    /// unrequested exit of the streak.
    case failed(exitCode: Int32, at: Date, gaveUpSince: Date? = nil)

    /// The process, while there is one.
    public var pid: Int32? {
        switch self {
        case .starting(let pid, _), .running(let pid, _, _): pid
        case .stopped, .waitingToRestart, .failed: nil
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
