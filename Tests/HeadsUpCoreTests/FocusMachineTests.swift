import Foundation
import Testing

@testable import HeadsUpCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

@Suite struct FocusMachineTests {
    // MARK: idle → focus → break prompt → break → back prompt → focus

    @Test func aFocusRunsToItsEndAndCountsASession() {
        var machine = FocusMachine()
        machine.start(minutes: 25, now: t0)
        #expect(machine.phase == .focus(FocusRun(minutes: 25, endsAt: at(25), pausedLeft: nil)))
        #expect(machine.nextDeadline == at(25))
        #expect(machine.advance(now: at(24.9), autoStartMinutes: nil) == nil)
        #expect(machine.advance(now: at(25), autoStartMinutes: nil) == .focusCompleted(minutes: 25, endedAt: at(25)))
        #expect(machine.phase == .prompt(.breakPrompt(manual: false)))
        #expect(machine.nextDeadline == nil)
    }

    @Test func aBreakRunsToTheBackPrompt() {
        var machine = FocusMachine(phase: .prompt(.breakPrompt(manual: false)))
        machine.startBreak(activity: "water", minutes: 5, now: t0)
        #expect(machine.phase == .rest(FocusRun(minutes: 5, endsAt: at(5), pausedLeft: nil), activity: "water"))
        #expect(machine.advance(now: at(5), autoStartMinutes: nil) == .breakCompleted(autoStartedMinutes: nil))
        #expect(machine.phase == .prompt(.backPrompt))
        machine.start(minutes: 40, now: at(6))
        #expect(machine.phase == .focus(FocusRun(minutes: 40, endsAt: at(46), pausedLeft: nil)))
    }

    @Test func withAutoStartABreakThatEndsStartsTheNextFocus() {
        var machine = FocusMachine(phase: .rest(.running(minutes: 5, from: t0), activity: "water"))
        #expect(machine.advance(now: at(5), autoStartMinutes: 25) == .breakCompleted(autoStartedMinutes: 25))
        #expect(machine.phase == .focus(FocusRun(minutes: 25, endsAt: at(30), pausedLeft: nil)))
    }

    @Test func theNextFocusIsTheLastOnesLengthByHandOrByAutoStart() {
        var machine = FocusMachine()
        #expect(machine.nextFocusMinutes(standard: 25) == 25)  // no focus yet
        machine.start(minutes: 35, now: t0)
        #expect(machine.nextFocusMinutes(standard: 25) == 35)
        machine.takeBreak(minutes: 5, activity: "water", now: at(35))
        _ = machine.advance(now: at(40), autoStartMinutes: 50)
        #expect(machine.lastFocusMinutes == 50)
        #expect(machine.nextFocusMinutes(standard: 25) == 50)
    }

    @Test func endBreakByHandShowsTheBackPromptEvenWithAutoStart() {
        var machine = FocusMachine(phase: .rest(.running(minutes: 5, from: t0), activity: "water"))
        machine.endBreak()
        #expect(machine.phase == .prompt(.backPrompt))
    }

    // MARK: pause and resume

    @Test func pauseFreezesTheTimeLeftAndResumeSetsANewEnd() {
        var machine = FocusMachine()
        machine.start(minutes: 25, now: t0)
        machine.pause(now: at(10))
        #expect(machine.phase == .focus(FocusRun(minutes: 25, endsAt: nil, pausedLeft: 15 * 60)))
        #expect(machine.nextDeadline == nil)
        #expect(machine.advance(now: at(60), autoStartMinutes: nil) == nil)
        machine.resume(now: at(60))
        #expect(machine.phase == .focus(FocusRun(minutes: 25, endsAt: at(75), pausedLeft: nil)))
    }

    @Test func pauseWorksInABreakToo() {
        var machine = FocusMachine(phase: .rest(.running(minutes: 10, from: t0), activity: "look"))
        machine.pause(now: at(4))
        machine.resume(now: at(20))
        #expect(machine.phase == .rest(FocusRun(minutes: 10, endsAt: at(26), pausedLeft: nil), activity: "look"))
    }

    @Test func pausingTwiceOrResumingARunningTimerChangesNothing() {
        var machine = FocusMachine()
        machine.start(minutes: 25, now: t0)
        machine.resume(now: at(5))
        #expect(machine.nextDeadline == at(25))
        machine.pause(now: at(5))
        machine.pause(now: at(9))
        #expect(machine.phase == .focus(FocusRun(minutes: 25, endsAt: nil, pausedLeft: 20 * 60)))
    }

    // MARK: stop, take a break now

    @Test func stopDuringFocusOrBreakGoesIdleAndCountsNothing() {
        var machine = FocusMachine()
        machine.start(minutes: 25, now: t0)
        machine.stop()
        #expect(machine.phase == .idle)
        machine = FocusMachine(phase: .rest(.running(minutes: 5, from: t0), activity: "water"))
        machine.stop()
        #expect(machine.phase == .idle)
        machine = FocusMachine(phase: .prompt(.backPrompt))
        machine.stop()
        #expect(machine.phase == .prompt(.backPrompt))
    }

    @Test func takeABreakNowFromAnyPhaseIsAManualPrompt() {
        for phase: FocusPhase in [
            .idle, .focus(.running(minutes: 25, from: t0)), .prompt(.backPrompt),
            .snoozed(until: at(5), prompt: .backPrompt),
        ] {
            var machine = FocusMachine(phase: phase)
            machine.takeBreakNow()
            #expect(machine.phase == .prompt(.breakPrompt(manual: true)))
        }
    }

    // MARK: snooze, show now, done

    @Test func aSnoozedPromptReturnsWhenItsTimeIsUp() {
        var machine = FocusMachine(phase: .prompt(.breakPrompt(manual: false)))
        machine.snooze(minutes: 5, now: t0)
        #expect(machine.phase == .snoozed(until: at(5), prompt: .breakPrompt(manual: false)))
        #expect(machine.nextDeadline == at(5))
        #expect(machine.advance(now: at(5), autoStartMinutes: nil) == .snoozeEnded(.breakPrompt(manual: false)))
        #expect(machine.phase == .prompt(.breakPrompt(manual: false)))
    }

    @Test func showNowBringsTheSnoozedPromptBack() {
        var machine = FocusMachine(phase: .prompt(.backPrompt))
        machine.snooze(minutes: 2, now: t0)
        machine.showNow()
        #expect(machine.phase == .prompt(.backPrompt))
    }

    @Test func doneEndsTheLoopFromEitherPrompt() {
        for prompt: FocusPrompt in [.breakPrompt(manual: false), .breakPrompt(manual: true), .backPrompt] {
            var machine = FocusMachine(phase: .prompt(prompt))
            machine.doneForNow()
            #expect(machine.phase == .idle)
        }
    }

    @Test func doneOutsideAPromptChangesNothing() {
        for phase: FocusPhase in [
            .idle, .focus(.running(minutes: 25, from: t0)), .rest(.running(minutes: 5, from: t0), activity: "water"),
            .snoozed(until: at(5), prompt: .backPrompt),
        ] {
            var machine = FocusMachine(phase: phase)
            machine.doneForNow()
            #expect(machine.phase == phase)
        }
    }

    @Test func movesThatDontApplyChangeNothing() {
        var machine = FocusMachine()
        machine.startBreak(activity: "water", minutes: 5, now: t0)
        machine.snooze(minutes: 5, now: t0)
        machine.showNow()
        machine.endBreak()
        machine.pause(now: t0)
        #expect(machine.phase == .idle)
    }

    // MARK: sleep and wake

    @Test func afterSleepAFocusThatEndedIsCountedOnTheDayItEnded() {
        var machine = FocusMachine()
        machine.start(minutes: 25, now: t0)
        // The Mac slept through the end; it wakes three hours later.
        #expect(machine.advance(now: at(180), autoStartMinutes: nil) == .focusCompleted(minutes: 25, endedAt: at(25)))
        #expect(machine.phase == .prompt(.breakPrompt(manual: false)))
        // Late, never early, and only one step: the prompt waits for the user.
        #expect(machine.advance(now: at(181), autoStartMinutes: nil) == nil)
    }

    @Test func progressAndTimeLeftFollowTheWallClock() {
        let run = FocusRun.running(minutes: 10, from: t0)
        #expect(run.timeLeft(at: at(4)) == 6 * 60)
        #expect(run.progress(at: at(5)) == 0.5)
        #expect(run.timeLeft(at: at(11)) == 0)
        #expect(run.progress(at: at(11)) == 1)
    }
}

/// Debug quick timers (`just app-quick`): every timer minute lasts 5 seconds.
@Suite struct QuickTimerTests {
    @Test func aQuickMinuteScalesFocusBreakAndSnoozeAlike() {
        var machine = FocusMachine(secondsPerMinute: 5)
        machine.start(minutes: 25, now: t0)
        #expect(machine.nextDeadline == t0.addingTimeInterval(125))
        if case .focus(let run) = machine.phase {
            #expect(run.minutes == 25)
            #expect(run.progress(at: t0.addingTimeInterval(62.5)) == 0.5)
        }
        _ = machine.advance(now: t0.addingTimeInterval(125), autoStartMinutes: nil)
        machine.snooze(minutes: 5, now: t0.addingTimeInterval(125))
        #expect(machine.nextDeadline == t0.addingTimeInterval(150))
        _ = machine.advance(now: t0.addingTimeInterval(150), autoStartMinutes: nil)
        machine.startBreak(activity: "water", minutes: 5, now: t0.addingTimeInterval(150))
        #expect(machine.nextDeadline == t0.addingTimeInterval(175))
    }

    @Test func pauseAndResumeKeepTheQuickDuration() {
        var machine = FocusMachine(secondsPerMinute: 5)
        machine.start(minutes: 2, now: t0)
        machine.pause(now: t0.addingTimeInterval(5))
        machine.resume(now: t0.addingTimeInterval(100))
        if case .focus(let run) = machine.phase {
            #expect(run.duration == 10)
            #expect(run.endsAt == t0.addingTimeInterval(105))
        }
    }
}

@MainActor
@Suite struct QuickBuildDataTests {
    @Test func theQuickBuildKeepsItsDataApart() {
        let support = URL(fileURLWithPath: "/Users/me/Library/Application Support")
        #expect(
            SettingsStore.dataFolder(quickTimers: false, applicationSupport: support).path
                == "/Users/me/Library/Application Support/HeadsUp")
        #expect(
            SettingsStore.dataFolder(quickTimers: true, applicationSupport: support).path
                == "/Users/me/Library/Application Support/HeadsUp-Quick")
        #expect(SettingsStore.defaultFolder.lastPathComponent == "HeadsUp")
    }
}
