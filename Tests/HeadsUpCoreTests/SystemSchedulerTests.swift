import Foundation
import Testing

@testable import HeadsUpCore

/// The real scheduler, on real time (card focus-end-auto-open): jobs fire at their date even
/// when nobody keeps their handle, a cancelled one never does, and it knows while one waits,
/// which is when it keeps macOS from napping the app.
@MainActor
@Suite(.serialized) struct SystemSchedulerTests {
    private func wait(until condition: () -> Bool, seconds: Double = 2) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @Test func aJobFiresAtItsDateEvenWhenItsHandleIsDropped() async throws {
        let scheduler = SystemScheduler()
        let start = Date()
        var firedAt: Date?
        // Most callers drop the handle: the job must still run.
        _ = scheduler.schedule(at: start.addingTimeInterval(0.2)) { firedAt = Date() }
        #expect(scheduler.pendingCount == 1 && scheduler.isHoldingOff)
        try await wait { firedAt != nil }
        let fired = try #require(firedAt)
        #expect(fired.timeIntervalSince(start) >= 0.2)
        #expect(fired.timeIntervalSince(start) < 1)
        #expect(scheduler.pendingCount == 0 && !scheduler.isHoldingOff)
    }

    @Test func aCancelledJobNeverFiresAndIsLetGo() async throws {
        let scheduler = SystemScheduler()
        var fired = false
        let job = scheduler.schedule(at: Date().addingTimeInterval(0.1)) { fired = true }
        job.cancel()
        job.cancel()
        #expect(scheduler.pendingCount == 0 && !scheduler.isHoldingOff)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(!fired)
    }

    @Test func aPastDateFiresAtOnceInOrder() async throws {
        let scheduler = SystemScheduler()
        var order: [Int] = []
        _ = scheduler.schedule(at: Date().addingTimeInterval(-60)) { order.append(1) }
        _ = scheduler.schedule(at: Date().addingTimeInterval(0.05)) { order.append(2) }
        try await wait { order.count == 2 }
        #expect(order == [1, 2] && scheduler.pendingCount == 0)
    }

    @Test func itHoldsOffWhileAnyJobWaits() async throws {
        let scheduler = SystemScheduler()
        var fired = 0
        let long = scheduler.schedule(at: Date().addingTimeInterval(60)) { fired += 1 }
        _ = scheduler.schedule(at: Date().addingTimeInterval(0.05)) { fired += 1 }
        try await wait { fired == 1 }
        #expect(scheduler.pendingCount == 1 && scheduler.isHoldingOff)
        long.cancel()
        #expect(!scheduler.isHoldingOff)
    }
}
