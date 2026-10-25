import Foundation

/// What the menu bar needs to know about Focus. FocusStore (slice 3) produces it; until
/// then AppModel reports `.idle`.
public enum FocusSnapshot: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A focus session.
        case focus
        /// A break.
        case rest
    }

    public enum Prompt: Equatable, Sendable {
        /// A focus ended: the break prompt waits.
        case breakDue
        /// A break ended: the back prompt waits.
        case breakOver
    }

    /// Nothing runs; `nextLength` is the focus length in minutes a start would use.
    case idle(nextLength: Int)
    case running(Kind, endsAt: Date)
    case paused(Kind, left: TimeInterval)
    case prompt(Prompt)
    case snoozed(until: Date)
}

/// What the menu bar needs to know about Caffeine. CaffeineStore (slice 4) produces it.
public enum CaffeineSnapshot: Equatable, Sendable {
    case off
    /// On until `endsAt`, or until turned off when it is nil. `pausedOnBattery` while "Only on
    /// power adapter" holds it on battery: the countdown runs, the Mac may sleep.
    case on(endsAt: Date?, pausedOnBattery: Bool = false)
}
