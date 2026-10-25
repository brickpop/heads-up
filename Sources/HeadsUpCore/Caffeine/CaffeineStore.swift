import Foundation
import Observation

/// Caffeine (ADR-001 §4.2; Caffeine spec): keeps the Mac awake for a while, with power
/// assertions it holds only while on, and not while paused on battery.
///
/// The countdown runs on the wall clock, on battery too; one wake-up is armed at the end date,
/// and expiry turns Caffeine off. Assertions die with the process, so quitting ends Caffeine.
@MainActor
@Observable
public final class CaffeineStore {
    public private(set) var isOn = false
    /// When it turns off by itself; nil for Until off, or while off.
    public private(set) var endsAt: Date?
    /// What macOS refused at the last start or change; nil once a start works.
    public private(set) var assertionProblem: CaffeineAssertionProblem?
    private var onBattery: Bool

    @ObservationIgnored private let clock: Clock
    @ObservationIgnored private let scheduler: Scheduler
    @ObservationIgnored let settings: SettingsStore
    @ObservationIgnored private let assertions: PowerAssertions
    @ObservationIgnored private let power: PowerSource
    @ObservationIgnored private weak var toaster: Toaster?
    @ObservationIgnored private var expiry: ScheduledWork?

    public init(
        clock: Clock, scheduler: Scheduler, settings: SettingsStore, assertions: PowerAssertions,
        power: PowerSource, toaster: Toaster
    ) {
        self.clock = clock
        self.scheduler = scheduler
        self.settings = settings
        self.assertions = assertions
        self.power = power
        self.toaster = toaster
        onBattery = power.isOnBattery
        power.observe { [weak self] in
            guard let self else { return }
            self.onBattery = self.power.isOnBattery
            self.applyAssertions()
        }
    }

    // MARK: State

    public var options: CaffeineSettings { settings.settings.caffeine }

    /// The last duration used, which the switch, the menu and the autocomplete turn on with.
    public var lastDuration: CaffeineDuration { options.lastDuration }

    /// On, with "Only on power adapter", while the Mac runs on battery: the countdown keeps
    /// running, the assertions are released, and they come back on the adapter (UX §15).
    public var pausedOnBattery: Bool {
        isOn && options.onlyOnAC && onBattery
    }

    /// What the menu bar, the menu and the tab dot need.
    public var snapshot: CaffeineSnapshot {
        isOn ? .on(endsAt: endsAt, pausedOnBattery: pausedOnBattery) : .off
    }

    /// The footer pill at `now`: "Awake 58m", "Awake", "Paused 45m" or "Paused"; nil while off.
    public func pill(at now: Date) -> String? {
        guard isOn else { return nil }
        let left = endsAt.map { Format.minutes($0.timeIntervalSince(now), rounding: .nearest) }
        return pausedOnBattery ? Strings.Caffeine.pillPaused(left) : Strings.Caffeine.pillAwake(left)
    }

    // MARK: Turning on and off

    /// The switch, in the tab and in the menu: on with the last-used duration, or off.
    public func toggle() {
        if isOn {
            turnOff()
        } else if start(lastDuration) {
            toaster?.toast(pausedOnBattery ? Strings.Caffeine.onPausedBySwitch : Strings.Caffeine.onBySwitch)
        }
    }

    /// A duration card: while off it turns Caffeine on with it and toasts; while on it
    /// restarts the timer, without a toast. Either way it becomes the last-used duration.
    public func selectDuration(_ duration: CaffeineDuration) {
        let wasOn = isOn
        guard start(duration), !wasOn else { return }
        let label = Strings.Caffeine.cardTitle(duration)
        toaster?.toast(pausedOnBattery ? Strings.Caffeine.onPaused(label) : Strings.Caffeine.onByCard(duration))
    }

    /// An autocomplete action: "Keep awake for 1 hour" and the like.
    public func keepAwake(_ duration: CaffeineDuration) {
        guard start(duration) else { return }
        let label = Strings.Caffeine.actionSuffix(duration)
        toaster?.toast(pausedOnBattery ? Strings.Caffeine.onPaused(label) : Strings.Caffeine.onByAction(duration))
    }

    /// The note's Try Again, after macOS refused: on again with the same duration.
    public func retry() {
        if isOn {
            // After a partial refusal: ask again, without restarting the countdown.
            assertionProblem = nil
            applyAssertions()
        } else if start(lastDuration) {
            toaster?.toast(pausedOnBattery ? Strings.Caffeine.onPausedBySwitch : Strings.Caffeine.onBySwitch)
        }
    }

    public func turnOff() {
        guard isOn else { return }
        stop()
        assertionProblem = nil
        toaster?.toast(Strings.Caffeine.off)
    }

    /// +10 min or +1 h: from the current end, or from now if it already passed.
    public func extend(minutes: Int) {
        guard isOn, let current = endsAt else { return }
        endsAt = max(current, clock.now).addingTimeInterval(Double(minutes) * 60)
        armExpiry()
        toaster?.toast(Strings.Caffeine.extended(minutes))
    }

    /// After the Mac wakes or its clock changes: a Caffeine that ended meanwhile turns off.
    public func clockJumped() {
        expireIfDue()
    }

    // MARK: Options

    /// An option switch: the one way to change an option (contract). Keep the display on and
    /// Prevent system sleep can't both be off, so turning off the last of them does nothing.
    /// Changes apply at once while Caffeine is on.
    public func setOption(_ option: CaffeineOption, _ on: Bool) {
        switch option {
        case .keepDisplayOn:
            guard on || options.preventSystemSleep else { return }
            settings.update { $0.caffeine.keepDisplayOn = on }
        case .preventSystemSleep:
            guard on || options.keepDisplayOn else { return }
            settings.update { $0.caffeine.preventSystemSleep = on }
        case .onlyOnAC:
            settings.update { $0.caffeine.onlyOnAC = on }
        }
        applyAssertions()
    }

    // MARK: Inside

    /// Turns on with `duration`. Returns whether Caffeine is on afterwards: false when macOS
    /// refused every assertion, which leaves it off with the note.
    @discardableResult
    private func start(_ duration: CaffeineDuration) -> Bool {
        settings.update { $0.caffeine.lastDuration = duration }
        assertionProblem = nil
        isOn = true
        endsAt = duration.minutes.map { clock.now.addingTimeInterval(Double($0) * 60) }
        armExpiry()
        applyAssertions()
        return isOn
    }

    private func stop() {
        isOn = false
        endsAt = nil
        expiry?.cancel()
        expiry = nil
        applyAssertions()
    }

    private func armExpiry() {
        expiry?.cancel()
        expiry = endsAt.map { date in
            scheduler.schedule(at: date) { [weak self] in self?.expireIfDue() }
        }
    }

    /// Time up: Caffeine turns off by itself, without a toast.
    private func expireIfDue() {
        guard isOn, let endsAt, endsAt <= clock.now else { return }
        stop()
        assertionProblem = nil
    }

    /// Holds the assertions the options ask for while on and not paused; none otherwise.
    /// Options changed while on apply at once. If macOS refuses them all, Caffeine is off: the
    /// switch, the cup and the pill must not claim a Mac that is kept awake (Yuki). If it refuses
    /// one of two, Caffeine stays on with the other, and the note names the one missing.
    private func applyAssertions() {
        let wanted: Set<PowerAssertionKind> = isOn && !pausedOnBattery ? options.assertions : []
        let held = assertions.hold(wanted)
        if held == wanted {
            // Everything wanted is held: the note goes. With nothing wanted (off, or paused on
            // battery) it stays, so a refusal that stopped Caffeine, or one before a pause, still shows.
            if !wanted.isEmpty { assertionProblem = nil }
            return
        }
        if held.isEmpty {
            assertionProblem = .refused
            stop()
        } else {
            assertionProblem = wanted.subtracting(held).contains(.displaySleep) ? .displayRefused : .systemRefused
        }
    }
}
