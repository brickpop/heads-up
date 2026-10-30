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

/// What the menu bar needs to know about Caffeine, and about the services that keep the Mac
/// awake (service flags addendum §4). CaffeineStore produces it.
public struct CaffeineSnapshot: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case off
        /// On until `endsAt`, or until turned off when it is nil. `pausedOnBattery` while "Only on
        /// power adapter" holds it on battery: the countdown runs, the Mac may sleep.
        case on(endsAt: Date?, pausedOnBattery: Bool = false)
    }

    /// Caffeine's own state.
    public var state: State
    /// The services whose hold applies, in list order. Caffeine's state doesn't depend on them.
    public var serviceHolds: [ServiceHold]

    public init(state: State, serviceHolds: [ServiceHold] = []) {
        self.state = state
        self.serviceHolds = serviceHolds
    }

    public static let off = CaffeineSnapshot(state: .off)

    public static func on(endsAt: Date?, pausedOnBattery: Bool = false) -> CaffeineSnapshot {
        CaffeineSnapshot(state: .on(endsAt: endsAt, pausedOnBattery: pausedOnBattery))
    }

    public var isOn: Bool { state != .off }

    /// At least one service holds the Mac awake (not paused, not refused).
    public var isHeld: Bool { serviceHolds.contains { $0.awake == .holding } }

    /// No service holds it, and at least one would but for the battery.
    public var isHeldButPaused: Bool { !isHeld && serviceHolds.contains { $0.awake == .pausedOnBattery } }
}
