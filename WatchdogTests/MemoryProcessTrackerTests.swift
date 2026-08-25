import Darwin
import XCTest
@testable import Watchdog

final class MemoryProcessTrackerTests: XCTestCase {
    private let gibibyte: UInt64 = 1_024 * 1_024 * 1_024
    private let clock = ContinuousClock()

    func testThresholdAndDurationBoundariesAreInclusive() {
        var tracker = MemoryProcessTracker()
        let start = clock.now
        let process = snapshot(pid: 42, bytes: 2 * gibibyte)

        XCTAssertTrue(update(&tracker, [process], at: start).isEmpty)
        XCTAssertTrue(update(&tracker, [process], at: start.advanced(by: .seconds(5))).isEmpty)
        XCTAssertTrue(update(&tracker, [process], at: start.advanced(by: .seconds(10))).isEmpty)
        XCTAssertTrue(update(&tracker, [process], at: start.advanced(by: .seconds(15))).isEmpty)
        XCTAssertTrue(update(&tracker, [process], at: start.advanced(by: .seconds(19.999))).isEmpty)
        XCTAssertEqual(update(&tracker, [process], at: start.advanced(by: .seconds(20))), [process.identity])
    }

    func testContinuityGapExactlyFiveSecondsContinuesButOverFiveResets() {
        var exact = MemoryProcessTracker()
        let start = clock.now
        let process = snapshot(pid: 42, bytes: 3 * gibibyte)

        _ = update(&exact, [process], duration: 10, at: start)
        _ = update(&exact, [process], duration: 10, at: start.advanced(by: .seconds(5)))
        XCTAssertEqual(
            update(&exact, [process], duration: 10, at: start.advanced(by: .seconds(10))),
            [process.identity]
        )

        var over = MemoryProcessTracker()
        _ = update(&over, [process], duration: 10, at: start)
        XCTAssertTrue(update(&over, [process], duration: 10, at: start.advanced(by: .seconds(5.001))).isEmpty)
        XCTAssertTrue(update(&over, [process], duration: 10, at: start.advanced(by: .seconds(10))).isEmpty)
    }

    func testBelowMissingIgnoredAndSamplingFailureResetClearAccumulation() {
        let start = clock.now
        let process = snapshot(pid: 42, bytes: 3 * gibibyte)
        let below = snapshot(pid: 42, bytes: gibibyte)

        var belowTracker = MemoryProcessTracker()
        _ = update(&belowTracker, [process], duration: 5, at: start)
        _ = update(&belowTracker, [below], duration: 5, at: start.advanced(by: .seconds(4)))
        XCTAssertTrue(update(&belowTracker, [process], duration: 5, at: start.advanced(by: .seconds(5))).isEmpty)

        var missingTracker = MemoryProcessTracker()
        _ = update(&missingTracker, [process], duration: 5, at: start)
        _ = update(&missingTracker, [], duration: 5, at: start.advanced(by: .seconds(4)))
        XCTAssertTrue(update(&missingTracker, [process], duration: 5, at: start.advanced(by: .seconds(5))).isEmpty)

        var ignoredTracker = MemoryProcessTracker()
        _ = update(&ignoredTracker, [process], duration: 5, at: start)
        _ = update(&ignoredTracker, [process], duration: 5, ignored: [process.identity], at: start.advanced(by: .seconds(4)))
        XCTAssertTrue(update(&ignoredTracker, [process], duration: 5, at: start.advanced(by: .seconds(5))).isEmpty)

        var resetTracker = MemoryProcessTracker()
        _ = update(&resetTracker, [process], duration: 5, at: start)
        resetTracker.reset()
        XCTAssertTrue(update(&resetTracker, [process], duration: 5, at: start.advanced(by: .seconds(5))).isEmpty)
    }

    func testPIDReuseIsIndependentAndMultipleIdentitiesAccumulateSeparately() {
        var tracker = MemoryProcessTracker()
        let start = clock.now
        let old = snapshot(pid: 42, bytes: 3 * gibibyte, startTime: 1_000_000)
        let reused = snapshot(pid: 42, bytes: 3 * gibibyte, startTime: 2_000_000)
        let other = snapshot(pid: 43, bytes: 3 * gibibyte, startTime: 3_000_000)

        _ = update(&tracker, [old, other], duration: 10, at: start)
        _ = update(&tracker, [old, other], duration: 10, at: start.advanced(by: .seconds(5)))
        let result = update(
            &tracker,
            [reused, other],
            duration: 10,
            ignored: [old.identity],
            at: start.advanced(by: .seconds(10))
        )

        XCTAssertEqual(result, [other.identity])
        XCTAssertFalse(result.contains(reused.identity))
    }

    private func update(
        _ tracker: inout MemoryProcessTracker,
        _ snapshots: [ProcessSnapshot],
        threshold: UInt64? = nil,
        duration: TimeInterval = 20,
        ignored: Set<ProcessIdentity> = [],
        at instant: ContinuousClock.Instant
    ) -> Set<ProcessIdentity> {
        tracker.update(
            snapshots: snapshots,
            thresholdBytes: threshold ?? 2 * gibibyte,
            sustainedFor: duration,
            ignoredProcesses: ignored,
            at: instant
        )
    }

    private func snapshot(
        pid: Int32,
        bytes: UInt64,
        startTime: UInt64 = 1_000_000
    ) -> ProcessSnapshot {
        ProcessSnapshot(
            id: pid,
            parentPID: 2,
            processGroupID: pid,
            userID: getuid(),
            tty: "ttys001",
            cpuPercent: 0,
            residentBytes: bytes,
            state: "R",
            elapsed: "00:10",
            executablePath: "/Applications/Test.app/Contents/MacOS/Test",
            startTimeMicroseconds: startTime,
            workingDirectory: nil
        )
    }
}
