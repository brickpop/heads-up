import Foundation

/// A timed run: a focus session or a break, with its end date on the wall clock, or the time
/// left while it is paused.
public struct FocusRun: Equatable, Sendable {
    /// The length it started with, in minutes.
    public let minutes: Int
    /// Its full length in seconds: `minutes` × 60, or less with debug quick timers.
    public let duration: TimeInterval
    /// When it ends; nil while paused.
    public let endsAt: Date?
    /// The time left when it was paused; nil while it runs.
    public let pausedLeft: TimeInterval?

    public init(minutes: Int, duration: TimeInterval? = nil, endsAt: Date?, pausedLeft: TimeInterval?) {
        self.minutes = minutes
        self.duration = duration ?? Double(minutes) * 60
        self.endsAt = endsAt
        self.pausedLeft = pausedLeft
    }

    static func running(minutes: Int, from now: Date, secondsPerMinute: TimeInterval = 60) -> FocusRun {
        let duration = Double(minutes) * secondsPerMinute
        return FocusRun(minutes: minutes, duration: duration, endsAt: now.addingTimeInterval(duration), pausedLeft: nil)
    }

    public var isPaused: Bool { endsAt == nil }

    /// Seconds left at `now`, never below zero.
    public func timeLeft(at now: Date) -> TimeInterval {
        if let endsAt { return max(0, endsAt.timeIntervalSince(now)) }
        return pausedLeft ?? 0
    }

    /// From 0 at the start to 1 at the end.
    public func progress(at now: Date) -> Double {
        guard duration > 0 else { return 1 }
        return min(1, max(0, 1 - timeLeft(at: now) / duration))
    }
}

/// A prompt the user answers: after a focus, or after a break.
public enum FocusPrompt: Equatable, Sendable {
    /// "Time for a break". `manual` for Take a break now, which offers no Keep working.
    case breakPrompt(manual: Bool)
    /// "Ready to get back to it?"
    case backPrompt
}

/// Where the Focus timer is (Focus spec, "State machine").
public enum FocusPhase: Equatable, Sendable {
    case idle
    case focus(FocusRun)
    case rest(FocusRun, activity: BreakOption.ID)
    case prompt(FocusPrompt)
    case snoozed(until: Date, prompt: FocusPrompt)
}

/// Something that happened by itself, for the store to act on: stats, notifications, auto-open.
public enum FocusEvent: Equatable, Sendable {
    /// A focus ran to its end. It counts as a session of `minutes`, on the day it ended.
    case focusCompleted(minutes: Int, endedAt: Date)
    /// A break ran to its end; `autoStartedMinutes` is set when the next focus started at once.
    case breakCompleted(autoStartedMinutes: Int?)
    /// A snooze ran out and its prompt is back.
    case snoozeEnded(FocusPrompt)
}

/// The Focus timer's rules, as a value: every transition of the spec, on wall-clock end dates.
/// It never reads the clock; each change takes `now`.
public struct FocusMachine: Equatable, Sendable {
    public private(set) var phase: FocusPhase = .idle
    /// How long a timer minute lasts: 60 s, or 5 s in a debug build made with `just app-quick`.
    public let secondsPerMinute: TimeInterval

    public init(phase: FocusPhase = .idle, secondsPerMinute: TimeInterval = 60) {
        self.phase = phase
        self.secondsPerMinute = secondsPerMinute
    }

    /// The next moment the phase changes by itself, or nil when nothing runs.
    public var nextDeadline: Date? {
        switch phase {
        case .focus(let run), .rest(let run, _): run.endsAt
        case .snoozed(let until, _): until
        case .idle, .prompt: nil
        }
    }

    // MARK: The user's moves

    /// Start focus: from anywhere, it starts a new session of `minutes`.
    public mutating func start(minutes: Int, now: Date) {
        phase = .focus(.running(minutes: minutes, from: now, secondsPerMinute: secondsPerMinute))
    }

    /// Pause a focus or a break: the time left is kept, the end date dropped.
    public mutating func pause(now: Date) {
        switch phase {
        case .focus(let run) where !run.isPaused:
            phase = .focus(Self.paused(run, now: now))
        case .rest(let run, let activity) where !run.isPaused:
            phase = .rest(Self.paused(run, now: now), activity: activity)
        default:
            break
        }
    }

    /// Resume: a new end date is now plus the time left.
    public mutating func resume(now: Date) {
        switch phase {
        case .focus(let run) where run.isPaused:
            phase = .focus(Self.resumed(run, now: now))
        case .rest(let run, let activity) where run.isPaused:
            phase = .rest(Self.resumed(run, now: now), activity: activity)
        default:
            break
        }
    }

    /// Stop a focus or a break (Stop, or the Stop timer action): back to idle, nothing counted.
    public mutating func stop() {
        switch phase {
        case .focus, .rest: phase = .idle
        default: break
        }
    }

    /// Take a break now: from any phase, the break prompt, without Keep working.
    public mutating func takeBreakNow() {
        phase = .prompt(.breakPrompt(manual: true))
    }

    /// Start break, from the break prompt.
    public mutating func startBreak(activity: BreakOption.ID, minutes: Int, now: Date) {
        guard case .prompt(.breakPrompt) = phase else { return }
        phase = .rest(.running(minutes: minutes, from: now, secondsPerMinute: secondsPerMinute), activity: activity)
    }

    /// Keep working: only after a focus that ended by itself; the next focus starts.
    public mutating func keepWorking(minutes: Int, now: Date) {
        guard case .prompt(.breakPrompt(manual: false)) = phase else { return }
        start(minutes: minutes, now: now)
    }

    /// Snooze a prompt for `minutes`.
    public mutating func snooze(minutes: Int, now: Date) {
        guard case .prompt(let prompt) = phase else { return }
        phase = .snoozed(until: now.addingTimeInterval(Double(minutes) * secondsPerMinute), prompt: prompt)
    }

    /// Show now, while snoozed: the prompt comes back at once.
    public mutating func showNow() {
        guard case .snoozed(_, let prompt) = phase else { return }
        phase = .prompt(prompt)
    }

    /// End break, by hand: the back prompt, even with auto-start on.
    public mutating func endBreak() {
        guard case .rest = phase else { return }
        phase = .prompt(.backPrompt)
    }

    /// Done for now, from the back prompt.
    public mutating func doneForNow() {
        guard case .prompt(.backPrompt) = phase else { return }
        phase = .idle
    }

    // MARK: Time

    /// Moves on if an end date has passed: at a scheduled wake-up, or after the Mac slept.
    /// - Parameter autoStartMinutes: the focus length to start when a break ends, if
    ///   "Start the next focus after a break" is on; nil otherwise.
    /// - Returns: what happened, or nil when nothing was due.
    public mutating func advance(now: Date, autoStartMinutes: Int?) -> FocusEvent? {
        switch phase {
        case .focus(let run):
            guard let endsAt = run.endsAt, endsAt <= now else { return nil }
            phase = .prompt(.breakPrompt(manual: false))
            return .focusCompleted(minutes: run.minutes, endedAt: endsAt)
        case .rest(let run, _):
            guard let endsAt = run.endsAt, endsAt <= now else { return nil }
            if let autoStartMinutes {
                start(minutes: autoStartMinutes, now: now)
                return .breakCompleted(autoStartedMinutes: autoStartMinutes)
            }
            phase = .prompt(.backPrompt)
            return .breakCompleted(autoStartedMinutes: nil)
        case .snoozed(let until, let prompt):
            guard until <= now else { return nil }
            phase = .prompt(prompt)
            return .snoozeEnded(prompt)
        case .idle, .prompt:
            return nil
        }
    }

    private static func paused(_ run: FocusRun, now: Date) -> FocusRun {
        FocusRun(minutes: run.minutes, duration: run.duration, endsAt: nil, pausedLeft: run.timeLeft(at: now))
    }

    private static func resumed(_ run: FocusRun, now: Date) -> FocusRun {
        FocusRun(
            minutes: run.minutes, duration: run.duration, endsAt: now.addingTimeInterval(run.pausedLeft ?? 0),
            pausedLeft: nil)
    }
}
