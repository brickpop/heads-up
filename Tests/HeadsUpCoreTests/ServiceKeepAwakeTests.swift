import Foundation
import Testing

@testable import HeadsUpCore

#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

/// Keep awake for 30m, 2h, 5h or without a limit: the stored shape (keep-awake limit addendum
/// §1), and the hold counted from the user's last input (keep-awake last activity addendum §5).
@MainActor
@Suite(.serialized) struct ServiceKeepAwakeTests {
    private let minute: TimeInterval = 60
    /// One second, in the minutes `advance` takes.
    private let second = 1.0 / 60

    private func decode(_ json: String) throws -> ServiceKeepAwake {
        try JSONDecoder().decode(ServiceDefinition.self, from: Data(json.utf8)).keepAwake
    }

    /// The service's "away for" lines.
    private func away(_ h: HoldsHarness, _ id: ServiceDefinition.ID) -> [String] {
        h.log(id).filter { $0.hasPrefix("no longer keeping the Mac awake: away for") }
    }

    /// Saves the service with another keep-awake choice.
    private func save(_ h: HoldsHarness, _ id: ServiceDefinition.ID, _ keepAwake: ServiceKeepAwake) throws {
        var definition = try #require(h.services.definitions.first { $0.id == id })
        definition.keepAwake = keepAwake
        #expect(h.services.save(definition).isEmpty)
    }

    /// Moves the clock to `start` plus `minutes` in steps of 10 s or less, running what is due at
    /// each step: the fake scheduler runs a job at the end of the step it falls in.
    private func advance(_ h: HoldsHarness, to minutes: Double, from start: Date) {
        let target = start.addingTimeInterval(minutes * minute)
        while h.clock.now < target {
            h.scheduler.advance(by: min(10, target.timeIntervalSince(h.clock.now)))
        }
    }

    @Test func theOldBoolReadsAsUnlimitedOrOffAndOnlyTheNewKeyIsWritten() throws {
        let base = #""id":"a","name":"Web","command":"npm run dev""#
        #expect(try decode("{\(base),\"keepAwake\":true}") == .unlimited)
        #expect(try decode("{\(base),\"keepAwake\":false}") == .off)
        #expect(try decode("{\(base)}") == .off)
        #expect(try decode("{\(base),\"keepAwake\":true,\"keepAwakeFor\":\"thirtyMinutes\"}") == .thirtyMinutes)
        // A hand-edited value this build doesn't know never holds longer than asked.
        #expect(try decode("{\(base),\"keepAwake\":true,\"keepAwakeFor\":\"45m\"}") == .off)
        #expect(try decode("{\(base),\"keepAwakeFor\":7}") == .off)

        let definition = ServiceDefinition(id: "a", name: "Web", command: "npm run dev", keepAwake: .fiveHours)
        let text = try #require(String(data: JSONEncoder().encode(definition), encoding: .utf8))
        #expect(text.contains(#""keepAwakeFor":"fiveHours""#) && !text.contains(#""keepAwake":"#))
        #expect(try decode(text) == .fiveHours)
        #expect(ServiceKeepAwake.allCases.map(\.minutes) == [nil, 30, 120, 300, nil])
        #expect(
            ServiceKeepAwake.allCases.map(Strings.ServiceForm.keepAwakeChoice) == [
                "Off", "30m", "2h", "5h", "Unlimited",
            ])
    }

    @Test func aDefinitionWithEveryFieldSetComesBackTheSame() throws {
        // Every field differs from its default, so a field the encoder drops or the decoder
        // misreads shows as a difference.
        let definition = ServiceDefinition(
            id: "web-1", name: "Web", command: "npm run dev -- --port 5173", cwd: "~/code/web",
            env: [
                EnvironmentVariable(key: "NODE_ENV", value: "development"), EnvironmentVariable(key: "A", value: ""),
            ],
            port: 5173, autostart: true, keepAwake: .twoHours, restartOnExit: true)
        let decoded = try JSONDecoder().decode(ServiceDefinition.self, from: JSONEncoder().encode(definition))
        #expect(decoded == definition)
    }

    // MARK: Counted from the user's last input (keep-awake last activity addendum §5)

    @Test func anActiveUserKeepsTheHold() async throws {
        let h = try HoldsHarness()
        let id = h.add(keepAwake: .thirtyMinutes)
        let start = h.clock.now
        h.services.start(id)
        for step in 1...15 {
            advance(h, to: Double(step) * 20, from: start)
            h.idle.input()
            #expect(h.held(id) == [.systemSleep] && h.row(id)?.awake == .holding)
            #expect(h.scheduler.pendingCount <= 1)
        }
        #expect(away(h, id).isEmpty)
    }

    @Test func theHoldGoesAtLastInputPlusTheLimit() async throws {
        let h = try HoldsHarness()
        let id = h.add(keepAwake: .thirtyMinutes)
        let start = h.clock.now
        h.services.start(id)
        advance(h, to: 30 - second, from: start)
        #expect(h.held(id) == [.systemSleep])
        advance(h, to: 30 + second, from: start)
        #expect(h.held(id).isEmpty && h.row(id)?.awake == nil && h.services.serviceHolds.isEmpty)
        #expect(h.services.state(id).isLive && h.row(id)?.keepAwakeAway == true)
        #expect(h.log(id).last == "no longer keeping the Mac awake: away for 30m")
    }

    @Test func theHoldComesBackWhenTheUserDoes() async throws {
        let h = try HoldsHarness()
        let id = h.add(keepAwake: .thirtyMinutes)
        let start = h.clock.now
        h.services.start(id)
        advance(h, to: 35, from: start)
        #expect(h.held(id).isEmpty)
        var lines = h.log(id).count
        h.idle.input()
        advance(h, to: 36, from: start)
        #expect(h.held(id) == [.systemSleep] && h.row(id)?.keepAwakeAway == false)
        #expect(Array(h.log(id).dropFirst(lines)) == ["keeping the Mac awake again: you're back"])
        // Polls that change nothing log nothing.
        lines = h.log(id).count
        advance(h, to: 46, from: start)
        #expect(h.log(id).count == lines)

        // Opening the HUD is input: the hold is back at once, no poll needed.
        advance(h, to: 46 + 31, from: start)
        #expect(h.held(id).isEmpty)
        h.idle.input()
        h.model.hud.open()
        #expect(h.held(id) == [.systemSleep] && h.log(id).last == "keeping the Mac awake again: you're back")
    }

    @Test func startsAndRestartsDontCount() async throws {
        let h = try HoldsHarness()
        let id = h.add(keepAwake: .thirtyMinutes, restartOnExit: true)
        let start = h.clock.now
        h.services.start(id)
        // A manual Restart while active: the end still follows the last input, at the start.
        advance(h, to: 20, from: start)
        h.services.restart(id)
        await h.exits(id, .signal(SIGTERM))
        #expect(h.services.state(id).isLive && h.held(id) == [.systemSleep])
        advance(h, to: 30 + second, from: start)
        #expect(h.held(id).isEmpty)

        // An automatic restart while away stays released, with nothing logged about the hold.
        let lines = h.log(id).count
        await h.exits(id, after: 60)
        guard case .waitingToRestart(_, let at, _) = h.services.state(id) else {
            Issue.record("expected a wait, got \(h.services.state(id))")
            return
        }
        h.scheduler.advance(by: at.timeIntervalSince(h.clock.now) + ServiceStore.startWindow)
        #expect(h.services.state(id).pid != nil && h.held(id).isEmpty)
        #expect(!h.log(id).dropFirst(lines).contains { $0.contains("keeping") || $0.contains("awake") })
    }

    @Test func aNewLimitWhileAwayIsReadAtOnceAndIsntAReturn() async throws {
        let h = try HoldsHarness()
        let id = h.add(keepAwake: .thirtyMinutes)
        let start = h.clock.now
        h.services.start(id)
        advance(h, to: 40, from: start)
        #expect(h.held(id).isEmpty)
        var lines = h.log(id).count
        try save(h, id, .twoHours)
        #expect(h.held(id) == [.systemSleep])
        #expect(Array(h.log(id).dropFirst(lines)) == ["keeping the Mac awake"])

        // Off: nothing held, nothing logged, nothing to check.
        advance(h, to: 2 * 60 + 1, from: start)
        #expect(h.held(id).isEmpty)
        lines = h.log(id).count
        try save(h, id, .off)
        #expect(h.log(id).count == lines)
        // Once the "Saved" toast is gone, nothing is left to run.
        h.scheduler.advance(by: HUDStore.toastDuration)
        #expect(h.scheduler.pendingCount == 0)
    }

    @Test func aShorterLimitWhileAwayStaysAwayUntilTheUserIsBack() async throws {
        let h = try HoldsHarness()
        let id = h.add(keepAwake: .twoHours)
        let start = h.clock.now
        h.services.start(id)
        advance(h, to: 130, from: start)
        #expect(h.held(id).isEmpty)
        let lines = h.log(id).count
        try save(h, id, .thirtyMinutes)
        #expect(h.held(id).isEmpty && h.log(id).count == lines)
        h.idle.input()
        advance(h, to: 131, from: start)
        #expect(h.held(id) == [.systemSleep])
        #expect(Array(h.log(id).dropFirst(lines)) == ["keeping the Mac awake again: you're back"])
    }

    @Test func awayAndThePauseOnBatteryAreIndependent() async throws {
        let h = try HoldsHarness(onlyOnAC: true)
        let id = h.add(keepAwake: .thirtyMinutes)
        let start = h.clock.now
        h.services.start(id)
        #expect(h.row(id)?.awake == .holding)
        h.power.set(onBattery: true)
        #expect(h.log(id).last == "keeping awake paused: on battery")
        advance(h, to: 30 + second, from: start)
        #expect(h.row(id)?.awake == nil && h.log(id).last == "no longer keeping the Mac awake: away for 30m")
        let lines = h.log(id).count
        h.idle.input()
        advance(h, to: 32, from: start)
        #expect(h.row(id)?.awake == .pausedOnBattery)
        #expect(Array(h.log(id).dropFirst(lines)) == ["keeping awake paused: on battery"])
        h.power.set(onBattery: false)
        #expect(h.row(id)?.awake == .holding && h.log(id).last == "keeping awake resumed: on power")
    }

    @Test func unlimitedAndOffNeverCheck() async throws {
        let h = try HoldsHarness()
        let unlimited = h.add("Ollama", keepAwake: .unlimited)
        let off = h.add("Postgres", keepAwake: .off)
        h.services.start(unlimited)
        h.services.start(off)
        // Past the start window and the port search.
        h.scheduler.advance(by: 10)
        #expect(h.scheduler.pendingCount == 0)
        h.scheduler.advance(by: 5 * 60 * minute)
        h.model.clockJumped()
        #expect(h.held(unlimited) == [.systemSleep] && h.held(off).isEmpty && h.scheduler.pendingCount == 0)
    }

    @Test func aClockJumpIsReadAtOnce() async throws {
        let h = try HoldsHarness()
        let id = h.add(keepAwake: .thirtyMinutes)
        h.services.start(id)
        // The Mac slept: the clock and the idle time moved, and no timer has fired yet.
        h.clock.advance(by: 2 * 60 * minute)
        #expect(h.held(id) == [.systemSleep])
        h.model.clockJumped()
        #expect(h.held(id).isEmpty && h.services.state(id).isLive)

        // Woken by a key: the user is back at once.
        h.clock.advance(by: 2 * 60 * minute)
        h.idle.input()
        h.model.clockJumped()
        #expect(h.held(id) == [.systemSleep])
    }

    @Test func stoppingAnAwayServiceLeavesNothingToCheck() async throws {
        let h = try HoldsHarness()
        let id = h.add(keepAwake: .thirtyMinutes)
        let start = h.clock.now
        h.services.start(id)
        advance(h, to: 31, from: start)
        #expect(h.services.away.contains(id))
        h.services.stop(id)
        await h.exits(id, .signal(SIGTERM))
        h.scheduler.advance(by: ServiceStore.killAfter)
        #expect(!h.services.away.contains(id) && h.scheduler.pendingCount == 0)
    }

    @Test func twoLimitsShareOneCheck() async throws {
        let h = try HoldsHarness()
        let short = h.add("Web", keepAwake: .thirtyMinutes)
        let long = h.add("API", keepAwake: .twoHours)
        let start = h.clock.now
        h.services.start(short)
        h.services.start(long)
        advance(h, to: 30 + second, from: start)
        #expect(h.held(short).isEmpty && h.held(long) == [.systemSleep] && h.scheduler.pendingCount == 1)

        advance(h, to: 40, from: start)
        h.idle.input()
        advance(h, to: 41, from: start)
        #expect(h.held(short) == [.systemSleep] && h.scheduler.pendingCount == 1)
        #expect(h.log(short).last == "keeping the Mac awake again: you're back")
        #expect(away(h, long).isEmpty && !h.log(long).contains("keeping the Mac awake again: you're back"))

        advance(h, to: 70, from: start)
        #expect(h.held(short) == [.systemSleep])
        advance(h, to: 70 + second, from: start)
        #expect(h.held(short).isEmpty && h.held(long) == [.systemSleep] && h.scheduler.pendingCount == 1)
        advance(h, to: 160, from: start)
        #expect(h.held(long) == [.systemSleep])
        advance(h, to: 160 + second, from: start)
        #expect(h.held(long).isEmpty && h.scheduler.pendingCount == 1)
        #expect(away(h, short).count == 2 && away(h, long).count == 1)
    }

    @Test func anAwayServiceIsntListedAsKeepingTheMacAwake() async throws {
        let h = try HoldsHarness()
        let id = h.add(keepAwake: .thirtyMinutes)
        let start = h.clock.now
        h.services.start(id)
        #expect(h.caffeine.snapshot.serviceHolds.map(\.name) == ["Web dev server"])
        advance(h, to: 31, from: start)
        #expect(h.caffeine.snapshot.serviceHolds.isEmpty && h.header.title == "Caffeine is off")
    }

    // MARK: The copy (UX: keep awake from the last activity)

    @Test func theRowSaysAwayAndTheLimit() async throws {
        let h = try HoldsHarness()
        let id = h.add(keepAwake: .twoHours)
        var row = try #require(h.row(id))
        #expect(row.keepAwakeHelp == "Keeps your Mac awake while it runs, until you've been away 2h")
        #expect(
            row.accessibilityLabel
                == "Web dev server, stopped, keeps your Mac awake while it runs, until you've been away 2 hours")
        let start = h.clock.now
        h.services.start(id)
        advance(h, to: 121, from: start)
        row = try #require(h.row(id))
        #expect(row.keepAwakeAway && row.keepAwakeHelp == "Not keeping your Mac awake while you're away")
        #expect(row.accessibilityLabel == "Web dev server, running, not keeping your Mac awake while you're away")
        h.idle.input()
        h.model.hud.open()
        row = try #require(h.row(id))
        #expect(!row.keepAwakeAway && row.keepAwakeHelp == "Keeping your Mac awake")
    }

    @Test func theFormCaptionAndTheSpokenChoices() {
        #expect(
            Strings.ServiceForm.keepAwakeHelp
                == "Your Mac stays awake while this runs and you're using it. After you've been away for this long, it can sleep. Away means no keyboard, mouse or trackpad use. Unlimited keeps it awake even while you're away. The display can still sleep, and closing the lid still sleeps. Follows Caffeine's “Only on power adapter”."
        )
        #expect(
            ServiceKeepAwake.allCases.map(Strings.ServiceForm.keepAwakeChoiceSpoken) == [
                "Off", "30 minutes", "2 hours", "5 hours", "Unlimited",
            ])
    }
}
