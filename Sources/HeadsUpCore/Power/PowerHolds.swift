import Foundation
import Observation

/// How Caffeine and ServiceStore keep the Mac awake: through the one owner of the power
/// assertions (service flags addendum §3; contract rule 3, narrow protocols).
@MainActor
public protocol PowerHolding: AnyObject {
    /// Holds `kinds` for `holder`, labelled `name`, and returns the kinds held for it now. An
    /// empty `kinds` releases the holder. Nothing is held while paused on battery.
    @discardableResult
    func set(_ holder: PowerHolder, kinds: Set<PowerAssertionKind>, name: String) -> Set<PowerAssertionKind>
    /// "Only on power adapter" is on and the Mac runs on battery: nothing is held, for anyone.
    var pausedOnBattery: Bool { get }
    /// Calls `changed` when `pausedOnBattery` changes: the Mac switched power source, or the
    /// option changed.
    func observePause(_ changed: @escaping @MainActor () -> Void)
}

/// The state of one service's hold, while it should hold: starting, running or waiting to
/// restart, with Keep awake on.
public enum AwakeState: Equatable, Sendable {
    case holding
    /// "Only on power adapter", on battery.
    case pausedOnBattery
    /// macOS didn't let HeadsUp hold it.
    case refused
}

/// A service whose hold applies, for the Caffeine tab, the menu bar and the menu.
public struct ServiceHold: Equatable, Sendable {
    /// Sanitized for display.
    public let name: String
    public let awake: AwakeState

    public init(name: String, awake: AwakeState) {
        self.name = name
        self.awake = awake
    }
}

/// The only caller of the `PowerAssertions` port. Each holder (Caffeine, each service) says
/// what it wants; this sends the union to the port, so no holder releases another's. It also
/// owns "Only on power adapter" for all of them: while that option is on and the Mac runs on
/// battery, nothing is held.
@MainActor
public final class PowerHolds: PowerHolding {
    private let assertions: PowerAssertions
    private let power: PowerSource
    private let settings: SettingsStore
    /// What each holder asked for, with its label.
    private var wanted: [PowerHolder: (kinds: Set<PowerAssertionKind>, name: String)] = [:]
    /// What the port holds now.
    private var held: Set<PowerHold> = []
    /// Holds macOS refused. They aren't asked for again until their own holder calls `set`, so
    /// a hold is never granted behind its holder's back while the holder still shows it refused.
    private var refused: Set<PowerHold> = []
    private var onBattery: Bool
    private var wasPaused: Bool
    private var listeners: [@MainActor () -> Void] = []

    public init(assertions: PowerAssertions, power: PowerSource, settings: SettingsStore) {
        self.assertions = assertions
        self.power = power
        self.settings = settings
        onBattery = power.isOnBattery
        wasPaused = settings.settings.caffeine.onlyOnAC && power.isOnBattery
        power.observe { [weak self] in
            guard let self else { return }
            self.onBattery = self.power.isOnBattery
            self.apply()
        }
    }

    public var pausedOnBattery: Bool { settings.settings.caffeine.onlyOnAC && onBattery }

    @discardableResult
    public func set(_ holder: PowerHolder, kinds: Set<PowerAssertionKind>, name: String) -> Set<PowerAssertionKind> {
        wanted[holder] = kinds.isEmpty ? nil : (kinds, name)
        // The holder asks again: its refused holds are tried again.
        refused = refused.filter { $0.holder != holder }
        apply()
        let granted = held.filter { $0.holder == holder }
        if !pausedOnBattery {
            for kind in kinds where !granted.contains(where: { $0.kind == kind }) {
                refused.insert(PowerHold(holder: holder, kind: kind, name: name))
            }
        }
        return Set(granted.map(\.kind))
    }

    public func observePause(_ changed: @escaping @MainActor () -> Void) {
        listeners.append(changed)
    }

    /// Sends the union of every holder's holds, except refused ones, or none while paused, then
    /// tells the stores if the pause began or ended.
    private func apply() {
        let paused = pausedOnBattery
        var asked: Set<PowerHold> = []
        if !paused {
            for (holder, want) in wanted {
                for kind in want.kinds { asked.insert(PowerHold(holder: holder, kind: kind, name: want.name)) }
            }
        }
        asked.subtract(refused)
        held = assertions.hold(asked)
        guard paused != wasPaused else { return }
        wasPaused = paused
        for listener in listeners { listener() }
    }
}
