import Darwin
import XCTest
@testable import Watchdog

final class HotProcessTrackerTests: XCTestCase {
    private let clock = ContinuousClock()

    func testThresholdAndDurationBoundariesAreInclusive() {
        var tracker = HotProcessTracker()
        let start = clock.now
        let process = snapshot(pid: 42, cpu: 100)

        XCTAssertTrue(update(&tracker, [process], at: start).isEmpty)
        XCTAssertTrue(update(&tracker, [process], at: start.advanced(by: .seconds(5))).isEmpty)
        XCTAssertTrue(update(&tracker, [process], at: start.advanced(by: .seconds(10))).isEmpty)
        XCTAssertTrue(update(&tracker, [process], at: start.advanced(by: .seconds(15))).isEmpty)
        XCTAssertTrue(update(&tracker, [process], at: start.advanced(by: .seconds(19.999))).isEmpty)
        XCTAssertEqual(update(&tracker, [process], at: start.advanced(by: .seconds(20))), [process.identity])
    }

    func testContinuityGapExactlyFiveSecondsContinuesButOverFiveResets() {
        var exact = HotProcessTracker()
        let start = clock.now
        let process = snapshot(pid: 42, cpu: 150)

        _ = update(&exact, [process], duration: 10, at: start)
        _ = update(&exact, [process], duration: 10, at: start.advanced(by: .seconds(5)))
        XCTAssertEqual(
            update(&exact, [process], duration: 10, at: start.advanced(by: .seconds(10))),
            [process.identity]
        )

        var over = HotProcessTracker()
        _ = update(&over, [process], duration: 10, at: start)
        XCTAssertTrue(update(&over, [process], duration: 10, at: start.advanced(by: .seconds(5.001))).isEmpty)
        XCTAssertTrue(update(&over, [process], duration: 10, at: start.advanced(by: .seconds(10))).isEmpty)
    }

    func testBelowMissingIgnoredAndSamplingFailureResetClearAccumulation() {
        let start = clock.now
        let process = snapshot(pid: 42, cpu: 150)
        let below = snapshot(pid: 42, cpu: 99)

        var belowTracker = HotProcessTracker()
        _ = update(&belowTracker, [process], duration: 5, at: start)
        _ = update(&belowTracker, [below], duration: 5, at: start.advanced(by: .seconds(4)))
        XCTAssertTrue(update(&belowTracker, [process], duration: 5, at: start.advanced(by: .seconds(5))).isEmpty)

        var missingTracker = HotProcessTracker()
        _ = update(&missingTracker, [process], duration: 5, at: start)
        _ = update(&missingTracker, [], duration: 5, at: start.advanced(by: .seconds(4)))
        XCTAssertTrue(update(&missingTracker, [process], duration: 5, at: start.advanced(by: .seconds(5))).isEmpty)

        var ignoredTracker = HotProcessTracker()
        _ = update(&ignoredTracker, [process], duration: 5, at: start)
        _ = update(&ignoredTracker, [process], duration: 5, ignored: [process.identity], at: start.advanced(by: .seconds(4)))
        XCTAssertTrue(update(&ignoredTracker, [process], duration: 5, at: start.advanced(by: .seconds(5))).isEmpty)

        var resetTracker = HotProcessTracker()
        _ = update(&resetTracker, [process], duration: 5, at: start)
        resetTracker.reset()
        XCTAssertTrue(update(&resetTracker, [process], duration: 5, at: start.advanced(by: .seconds(5))).isEmpty)
    }

    func testPIDReuseIsIndependentAndMultipleIdentitiesAccumulateSeparately() {
        var tracker = HotProcessTracker()
        let start = clock.now
        let old = snapshot(pid: 42, cpu: 150, startTime: 1_000_000)
        let reused = snapshot(pid: 42, cpu: 150, startTime: 2_000_000)
        let other = snapshot(pid: 43, cpu: 150, startTime: 3_000_000)

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
        _ tracker: inout HotProcessTracker,
        _ snapshots: [ProcessSnapshot],
        threshold: Double = 100,
        duration: TimeInterval = 20,
        ignored: Set<ProcessIdentity> = [],
        at instant: ContinuousClock.Instant
    ) -> Set<ProcessIdentity> {
        tracker.update(
            snapshots: snapshots,
            threshold: threshold,
            sustainedFor: duration,
            ignoredProcesses: ignored,
            at: instant
        )
    }

    private func snapshot(
        pid: Int32,
        cpu: Double,
        startTime: UInt64 = 1_000_000
    ) -> ProcessSnapshot {
        ProcessSnapshot(
            id: pid,
            parentPID: 2,
            processGroupID: pid,
            userID: getuid(),
            tty: "ttys001",
            cpuPercent: cpu,
            residentBytes: 1_024,
            state: "R",
            elapsed: "00:10",
            executablePath: "/Applications/Test.app/Contents/MacOS/Test",
            startTimeMicroseconds: startTime,
            workingDirectory: nil
        )
    }
}
