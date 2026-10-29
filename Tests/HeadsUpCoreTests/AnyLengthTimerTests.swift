import Foundation
import Testing

@testable import HeadsUpCore

/// Typed `/start 35` and `/break 5` (ADR-001 addendum: any length): the parser and the bounds.
@Suite struct QuickTimerParseTests {
    @Test(arguments: [
        ("/start 35", QuickTimer.focus(35)), ("/start 35m", .focus(35)), ("/start 35 m", .focus(35)),
        ("/start 35min", .focus(35)), ("/start 35 min", .focus(35)), ("/START 35 MIN", .focus(35)),
        ("/break 5", .break(5)), ("/break 5m", .break(5)), ("/break 5 min", .break(5)),
        ("/start 007", .focus(7)),
    ])
    func aValidCommandGivesItsLength(input: String, expected: QuickTimer) {
        #expect(QuickTimer.parse(input) == expected)
    }

    @Test func theBoundsAreTheSameForTypingAndTheTool() {
        #expect(QuickTimer.parse("/start 0") == .invalid(.outOfRange(.focus)))
        #expect(QuickTimer.parse("/start 1") == .focus(1))
        #expect(QuickTimer.parse("/start 180") == .focus(180))
        #expect(QuickTimer.parse("/start 181") == .invalid(.outOfRange(.focus)))
        #expect(QuickTimer.parse("/break 0") == .invalid(.outOfRange(.break)))
        #expect(QuickTimer.parse("/break 1") == .break(1))
        #expect(QuickTimer.parse("/break 60") == .break(60))
        #expect(QuickTimer.parse("/break 61") == .invalid(.outOfRange(.break)))
        // More digits than an Int holds is out of bounds too, not a crash.
        #expect(QuickTimer.parse("/start 99999999999999999999") == .invalid(.outOfRange(.focus)))
        #expect(FocusSettings.anyFocusRange == 1...180 && FocusSettings.anyBreakRange == 1...60)
    }

    @Test(arguments: [
        ("/start abc", QuickTimer.Kind.focus), ("/start 3.5", .focus), ("/start -5", .focus), ("/start 35x", .focus),
        ("/start 35 minutes", .focus), ("/break five", .break), ("/break 5 h", .break),
    ])
    func anythingElseAsksForTheMinutes(input: String, kind: QuickTimer.Kind) {
        #expect(QuickTimer.parse(input) == .invalid(.notANumber(kind)))
    }

    @Test func otherInputIsNotATimer() {
        for input in ["/start", "/break", "/starts 5", "start 35", "/stop 5", "/focus 35", "35", "/"] {
            #expect(QuickTimer.parse(input) == nil, "\(input)")
        }
    }

    @Test func theProblemsReadAsYukiWroteThem() {
        #expect(QuickTimer.Problem.outOfRange(.focus).text == "A focus can be 1 to 180 minutes")
        #expect(QuickTimer.Problem.outOfRange(.break).text == "A break can be 1 to 60 minutes")
        #expect(QuickTimer.Problem.notANumber(.focus).text == "Type the minutes, like /start 35")
        #expect(QuickTimer.Problem.notANumber(.break).text == "Type the minutes, like /break 5")
    }
}

/// `FocusMachine.takeBreak`: a break of any length from each phase.
@Suite struct TakeBreakTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func itStartsABreakFromEveryPhase() {
        let run = FocusRun.running(minutes: 25, from: now.addingTimeInterval(-60))
        let paused = FocusRun(minutes: 25, endsAt: nil, pausedLeft: 600)
        let phases: [FocusPhase] = [
            .idle, .focus(run), .focus(paused), .rest(run, activity: "look"), .prompt(.breakPrompt(manual: false)),
            .prompt(.backPrompt), .snoozed(until: now.addingTimeInterval(300), prompt: .breakPrompt(manual: true)),
        ]
        for phase in phases {
            var machine = FocusMachine(phase: phase)
            machine.takeBreak(minutes: 7, activity: "water", now: now)
            #expect(
                machine.phase
                    == .rest(
                        FocusRun(minutes: 7, endsAt: now.addingTimeInterval(420), pausedLeft: nil), activity: "water"),
                "\(phase)")
            #expect(machine.nextDeadline == now.addingTimeInterval(420))
        }
    }
}
