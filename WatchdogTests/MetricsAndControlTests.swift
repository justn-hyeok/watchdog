import Darwin
import Foundation
import XCTest
@testable import Watchdog

final class MetricsAndControlTests: XCTestCase {
    func testSmokeMetricsReaderInspectsCurrentProcess() throws {
        let metrics = try XCTUnwrap(ProcessMetricsReader.read(pid: getpid()))
        XCTAssertEqual(metrics.userID, getuid())
        XCTAssertGreaterThan(metrics.startTimeMicroseconds, 0)
        XCTAssertGreaterThan(metrics.residentBytes, 0)
    }

    func testSmokeSystemReadersReturnBoundedMetrics() throws {
        let ticks = try XCTUnwrap(SystemMetricsReader.cpuTicks())
        let memory = try XCTUnwrap(SystemMetricsReader.memory())
        XCTAssertGreaterThan(ticks.user + ticks.system + ticks.idle + ticks.nice, 0)
        XCTAssertGreaterThan(memory.totalBytes, 0)
        XCTAssertLessThanOrEqual(memory.usedBytes, memory.totalBytes)
        XCTAssertGreaterThanOrEqual(memory.usedPercent, 0)
        XCTAssertLessThanOrEqual(memory.usedPercent, 100)
        XCTAssertLessThanOrEqual(memory.compressedBytes, memory.totalBytes)
        let swapUsed = try XCTUnwrap(memory.swapUsedBytes)
        let swapTotal = try XCTUnwrap(memory.swapTotalBytes)
        XCTAssertLessThanOrEqual(swapUsed, swapTotal)
    }

    func testSmokeLiveSamplerProducesStableIdentity() async throws {
        let sample = try await ProcessSampler().sample()
        let current = try XCTUnwrap(sample.processes.first { $0.id == getpid() })
        XCTAssertGreaterThan(current.startTimeMicroseconds, 0)
        XCTAssertNotNil(sample.systemMemory)
    }

    func testAsyncCommandRunnerEnforcesDeadlineAndTearsDownChild() async throws {
        let started = ContinuousClock().now
        do {
            _ = try await CommandRunner.run(
                "/bin/sh",
                arguments: ["-c", "trap '' TERM; sleep 1"],
                deadline: .milliseconds(100)
            )
            XCTFail("Expected command deadline")
        } catch CommandRunnerError.timedOut {
            XCTAssertLessThan(started.duration(to: ContinuousClock().now), .seconds(2))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertLessThanOrEqual(CommandRunner.activeProcessCountPreview, 1)
        await waitForHelperCleanup()
    }

    func testAsyncCommandRunnerReturnsPromptlyWhenParentTaskIsCancelled() async {
        let started = ContinuousClock().now
        let task = Task {
            try await CommandRunner.run(
                "/bin/sh",
                arguments: ["-c", "trap '' TERM; sleep 1"],
                deadline: .seconds(10)
            )
        }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected command cancellation")
        } catch CommandRunnerError.cancelled {
            XCTAssertLessThan(started.duration(to: ContinuousClock().now), .seconds(2))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertLessThanOrEqual(CommandRunner.activeProcessCountPreview, 1)
        await waitForHelperCleanup()
    }

    func testAsyncCommandRunnerBoundsTimedOutLiveHelpers() async {
        let errors = await withTaskGroup(of: CommandRunnerError?.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    do {
                        _ = try await CommandRunner.run(
                            "/bin/sh",
                            arguments: ["-c", "trap '' TERM; sleep 1"],
                            deadline: .milliseconds(100)
                        )
                        return nil
                    } catch let error as CommandRunnerError {
                        return error
                    } catch {
                        return nil
                    }
                }
            }
            var errors: [CommandRunnerError] = []
            for await error in group {
                if let error {
                    errors.append(error)
                }
            }
            return errors
        }

        XCTAssertEqual(errors.count, 4)
        XCTAssertTrue(errors.contains {
            if case .resourceLimit = $0 { return true }
            return false
        })
        XCTAssertLessThanOrEqual(CommandRunner.activeProcessCountPreview, 3)
        await waitForHelperCleanup()
    }

    func testTimedOutChildThatIgnoresSIGTERMIsForceKilledAfterGrace() async {
        do {
            _ = try await CommandRunner.run(
                "/bin/sh",
                arguments: ["-c", "trap '' TERM; sleep 30"],
                deadline: .milliseconds(100)
            )
            XCTFail("Expected command deadline")
        } catch CommandRunnerError.timedOut {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        await waitForHelperCleanup(timeout: .seconds(4))
    }

    func testProcessCPUUsesIntervalDelta() throws {
        var tracker = ProcessCPUTracker()
        let identity = ProcessIdentity(pid: 42, startTimeMicroseconds: 1_000, userID: getuid())
        XCTAssertTrue(tracker.percentages(for: [(identity, 1_000_000_000)], at: 10_000_000_000).isEmpty)
        let result = tracker.percentages(for: [(identity, 2_000_000_000)], at: 12_000_000_000)
        XCTAssertEqual(try XCTUnwrap(result[identity]), 50, accuracy: 0.001)
    }

    func testSystemCPUUsesTickDelta() throws {
        var tracker = SystemCPUTracker()
        XCTAssertNil(tracker.percentage(for: .init(user: 100, system: 50, idle: 850, nice: 0)))
        let result = try XCTUnwrap(tracker.percentage(for: .init(user: 140, system: 60, idle: 900, nice: 0)))
        XCTAssertEqual(result, 50, accuracy: 0.001)
    }

    func testSnapshotProtectedMatrixAndSameUserControl() {
        let protected: [ProcessSnapshot] = [
            snapshot(pid: 0),
            snapshot(pid: 1),
            snapshot(pid: getpid()),
            snapshot(startTime: 0),
            snapshot(userID: getuid() &+ 1),
            snapshot(path: "/System/Library/tool"),
            snapshot(path: "/usr/libexec/tool"),
            snapshot(path: "/usr/sbin/tool"),
            snapshot(path: "/sbin/tool"),
        ]
        for process in protected {
            XCTAssertTrue(process.isProtected, "Expected protected: \(process)")
            XCTAssertFalse(process.canControl)
        }
        XCTAssertFalse(snapshot().isProtected)
        XCTAssertTrue(snapshot().canControl)
    }

    func testAllSignalPlans() {
        XCTAssertEqual(ProcessController.signalPlan(for: .suspend, isSuspended: false), [SIGSTOP])
        XCTAssertEqual(ProcessController.signalPlan(for: .resume, isSuspended: true), [SIGCONT])
        XCTAssertEqual(ProcessController.signalPlan(for: .terminate, isSuspended: false), [SIGTERM])
        XCTAssertEqual(ProcessController.signalPlan(for: .terminate, isSuspended: true), [SIGCONT, SIGTERM])
        XCTAssertEqual(ProcessController.signalPlan(for: .forceQuit, isSuspended: true), [SIGKILL])
    }

    func testLiveStateAuthoritativelyAddsContinueBeforeTerminate() async throws {
        let process = snapshot(state: "R")
        let instant = ContinuousClock().now
        let authorization = try await authorization(for: process, action: .terminate, at: instant)
        let probe = ControlProbe(lookups: Array(repeating: .found(facts(process, state: "T")), count: 3))
        let controller = controller(probe, now: instant)

        try controller.execute(authorization, currentGeneration: 7)

        XCTAssertEqual(probe.signals, [SIGCONT, SIGTERM])
    }

    func testAuthoritativeLiveProtectedPathsAndOtherUIDRejectWithoutSignals() async throws {
        let instant = ContinuousClock().now
        let process = snapshot()
        let protectedPaths = [
            facts(process, path: "/System/Library/tool"),
            facts(process, path: "/usr/libexec/tool"),
            facts(process, path: "/usr/sbin/tool"),
            facts(process, path: "/sbin/tool"),
        ]

        for live in protectedPaths {
            let authorization = try await authorization(for: process, action: .suspend, at: instant)
            let probe = ControlProbe(lookups: [.found(live)])
            XCTAssertThrowsError(try controller(probe, now: instant).execute(authorization, currentGeneration: 7)) {
                guard case ProcessControlError.protectedProcess = $0 else { return XCTFail("Unexpected: \($0)") }
            }
            XCTAssertEqual(probe.signals, [])
        }

        let otherUID = LiveProcessFacts(
            identity: ProcessIdentity(pid: process.id, startTimeMicroseconds: process.startTimeMicroseconds, userID: getuid() &+ 1),
            executablePath: process.executablePath,
            isSuspended: false
        )
        let authorization = try await authorization(for: process, action: .suspend, at: instant)
        let probe = ControlProbe(lookups: [.found(otherUID)])
        XCTAssertThrowsError(try controller(probe, now: instant).execute(authorization, currentGeneration: 7)) {
            guard case ProcessControlError.processChanged = $0 else { return XCTFail("Unexpected: \($0)") }
        }
        XCTAssertEqual(probe.signals, [])
    }

    func testAuthoritativeLiveExecutableOverridesStaleSnapshotPath() async throws {
        let instant = ContinuousClock().now
        let staleSnapshot = snapshot(path: "/System/Library/old-tool")
        XCTAssertTrue(staleSnapshot.isProtected)
        let live = LiveProcessFacts(
            identity: staleSnapshot.identity,
            executablePath: "/usr/local/bin/current-tool",
            isSuspended: false
        )
        let authorization = try await authorization(for: staleSnapshot, action: .suspend, at: instant)
        let probe = ControlProbe(lookups: [.found(live), .found(live)])

        try controller(probe, now: instant).execute(authorization, currentGeneration: 7)

        XCTAssertEqual(probe.signals, [SIGSTOP])
    }

    func testControllerProtectedIdentityMatrixRejectsBeforeLookupOrSignal() async throws {
        let instant = ContinuousClock().now
        let identities = [
            snapshot(pid: 0), snapshot(pid: 1), snapshot(pid: 99, startTime: 0),
            snapshot(pid: 99, userID: 0), snapshot(pid: 99, userID: getuid() &+ 1),
        ]
        for process in identities {
            let authorization = try await authorization(for: process, action: .suspend, at: instant)
            let probe = ControlProbe(lookups: [.found(facts(process))])
            let target = controller(probe, currentPID: process.id == 99 ? 500 : 99, now: instant)
            XCTAssertThrowsError(try target.execute(authorization, currentGeneration: 7)) {
                guard case ProcessControlError.protectedProcess = $0 else { return XCTFail("Unexpected: \($0)") }
            }
            XCTAssertEqual(probe.lookupCount, 0)
            XCTAssertEqual(probe.signals, [])
        }

        let selfProcess = snapshot(pid: 99)
        let selfAuthorization = try await authorization(for: selfProcess, action: .suspend, at: instant)
        let selfProbe = ControlProbe(lookups: [.found(facts(selfProcess))])
        XCTAssertThrowsError(try controller(selfProbe, currentPID: 99, now: instant).execute(selfAuthorization, currentGeneration: 7))
        XCTAssertEqual(selfProbe.lookupCount, 0)
        XCTAssertEqual(selfProbe.signals, [])
    }

    func testSameUserLiveIdentitySignalsAndLookupFailuresDoNot() async throws {
        let instant = ContinuousClock().now
        let process = snapshot()
        let firstAuthorization = try await authorization(for: process, action: .suspend, at: instant)
        let success = ControlProbe(lookups: [.found(facts(process)), .found(facts(process))])
        try controller(success, now: instant).execute(firstAuthorization, currentGeneration: 7)
        XCTAssertEqual(success.signals, [SIGSTOP])

        for lookup in [LiveProcessLookup.absent, .failed] {
            let authorization = try await authorization(for: process, action: .suspend, at: instant)
            let probe = ControlProbe(lookups: [lookup])
            XCTAssertThrowsError(try controller(probe, now: instant).execute(authorization, currentGeneration: 7))
            XCTAssertEqual(probe.signals, [])
        }
    }

    func testIdentityChangeBetweenMultiSignalStepsStopsAfterContinue() async throws {
        let instant = ContinuousClock().now
        let process = snapshot()
        let changed = ProcessIdentity(pid: process.id, startTimeMicroseconds: process.startTimeMicroseconds + 1, userID: getuid())
        let authorization = try await authorization(for: process, action: .terminate, at: instant)
        let probe = ControlProbe(lookups: [
            .found(facts(process, state: "T")),
            .found(facts(process, state: "T")),
            .found(LiveProcessFacts(identity: changed, executablePath: process.executablePath, isSuspended: true)),
        ])
        XCTAssertThrowsError(try controller(probe, now: instant).execute(authorization, currentGeneration: 7))
        XCTAssertEqual(probe.signals, [SIGCONT])
    }

    func testAuthorizationUsesMinimumExpiryAndRejectsEquality() async throws {
        let actor = ProcessActionAuthorizationActor()
        let process = snapshot()
        let origin = ContinuousClock().now
        let observation = ObservationToken(generation: 7, instant: origin)

        let observationLimited = try await actor.mint(action: .suspend, identity: process.identity, observation: observation, at: origin.advanced(by: .seconds(3)))
        _ = try await actor.consume(observationLimited, action: .suspend, identity: process.identity, currentGeneration: 7, at: origin.advanced(by: .seconds(4.999)))

        let mintLimited = try await actor.mint(action: .suspend, identity: process.identity, observation: observation, at: origin.advanced(by: .seconds(1)))
        do {
            _ = try await actor.consume(mintLimited, action: .suspend, identity: process.identity, currentGeneration: 7, at: origin.advanced(by: .seconds(4)))
            XCTFail("Equality at min(observation+5s, mint+3s) must be expired")
        } catch ProcessControlError.authorizationExpired {}
    }

    func testAuthorizationCapacityRefusesThenPrunesExpiredRecords() async throws {
        let actor = ProcessActionAuthorizationActor(capacity: 2)
        let process = snapshot()
        let origin = ContinuousClock().now
        let observation = ObservationToken(generation: 7, instant: origin)
        _ = try await actor.mint(action: .suspend, identity: process.identity, observation: observation, at: origin)
        _ = try await actor.mint(action: .resume, identity: process.identity, observation: observation, at: origin)
        do {
            _ = try await actor.mint(action: .suspend, identity: process.identity, observation: observation, at: origin)
            XCTFail("Capacity must be refused")
        } catch ProcessControlError.authorizationCapacityReached {}

        let replacement = try await actor.mint(
            action: .suspend,
            identity: process.identity,
            observation: ObservationToken(generation: 8, instant: origin.advanced(by: .seconds(3))),
            at: origin.advanced(by: .seconds(3))
        )
        _ = try await actor.consume(replacement, action: .suspend, identity: process.identity, currentGeneration: 8, at: origin.advanced(by: .seconds(3)))
    }

    func testAuthorizationIsSingleUseSequentiallyAndConcurrently() async throws {
        let actor = ProcessActionAuthorizationActor()
        let process = snapshot()
        let instant = ContinuousClock().now
        let observation = ObservationToken(generation: 7, instant: instant)
        let sequential = try await actor.mint(action: .suspend, identity: process.identity, observation: observation, at: instant)
        _ = try await actor.consume(sequential, action: .suspend, identity: process.identity, currentGeneration: 7, at: instant)
        do {
            _ = try await actor.consume(sequential, action: .suspend, identity: process.identity, currentGeneration: 7, at: instant)
            XCTFail("Consumed nonce must not replay")
        } catch ProcessControlError.authorizationInvalid {}

        let concurrent = try await actor.mint(action: .resume, identity: process.identity, observation: observation, at: instant)
        let replayResults = await withTaskGroup(of: Int.self, returning: [Int].self) { group in
            for _ in 0..<2 {
                group.addTask {
                    do {
                        _ = try await actor.consume(concurrent, action: .resume, identity: process.identity, currentGeneration: 7, at: instant)
                        return 1
                    } catch ProcessControlError.authorizationInvalid {
                        return 0
                    } catch {
                        return -1
                    }
                }
            }
            var results: [Int] = []
            for await result in group { results.append(result) }
            return results.sorted()
        }
        XCTAssertEqual(replayResults, [0, 1])
    }

    func testStaleGenerationAndExpiredAuthorizationSendNoSignals() async throws {
        let process = snapshot()
        let origin = ContinuousClock().now
        let staleAuthorization = try await authorization(for: process, action: .suspend, at: origin)
        let staleProbe = ControlProbe(lookups: [.found(facts(process))])
        XCTAssertThrowsError(try controller(staleProbe, now: origin).execute(staleAuthorization, currentGeneration: 8))
        XCTAssertEqual(staleProbe.signals, [])

        let expired = try await authorization(for: process, action: .suspend, at: origin)
        let expiredProbe = ControlProbe(lookups: [.found(facts(process))])
        XCTAssertThrowsError(try controller(expiredProbe, now: origin.advanced(by: .seconds(3))).execute(expired, currentGeneration: 7))
        XCTAssertEqual(expiredProbe.signals, [])
    }

    private func authorization(for process: ProcessSnapshot, action: ProcessControlAction, at instant: ContinuousClock.Instant) async throws -> AuthorizedProcessAction {
        let actor = ProcessActionAuthorizationActor()
        let nonce = try await actor.mint(action: action, identity: process.identity, observation: ObservationToken(generation: 7, instant: instant), at: instant)
        return try await actor.consume(nonce, action: action, identity: process.identity, currentGeneration: 7, at: instant)
    }

    private func waitForHelperCleanup(timeout: Duration = .seconds(3)) async {
        let deadline = ContinuousClock().now.advanced(by: timeout)
        while CommandRunner.activeProcessCountPreview != 0,
              ContinuousClock().now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(CommandRunner.activeProcessCountPreview, 0)
    }

    private func controller(_ probe: ControlProbe, currentPID: Int32 = 500, now: ContinuousClock.Instant) -> ProcessController {
        ProcessController(
            factsReader: { _ in probe.nextLookup() },
            signalSender: { _, signal in probe.send(signal) },
            currentUserID: { getuid() },
            currentPID: { currentPID },
            now: { now }
        )
    }

    private func facts(_ process: ProcessSnapshot, path: String? = nil, state: String? = nil) -> LiveProcessFacts {
        LiveProcessFacts(identity: process.identity, executablePath: path ?? process.executablePath, isSuspended: (state ?? process.state).contains("T"))
    }

    private func snapshot(pid: Int32 = 42, userID: UInt32 = getuid(), state: String = "R", path: String = "/usr/local/bin/test-agent", startTime: UInt64 = 1_000_000) -> ProcessSnapshot {
        ProcessSnapshot(id: pid, parentPID: 2, processGroupID: pid, userID: userID, tty: "ttys001", cpuPercent: 0, residentBytes: 1_024, state: state, elapsed: "00:10", executablePath: path, startTimeMicroseconds: startTime, workingDirectory: nil)
    }
}

private final class ControlProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var lookups: [LiveProcessLookup]
    private var recordedSignals: [Int32] = []
    private var reads = 0

    init(lookups: [LiveProcessLookup]) { self.lookups = lookups }
    var signals: [Int32] { lock.withLock { recordedSignals } }
    var lookupCount: Int { lock.withLock { reads } }
    func nextLookup() -> LiveProcessLookup { lock.withLock { reads += 1; return lookups.isEmpty ? .failed : lookups.removeFirst() } }
    func send(_ signal: Int32) -> Int32 { lock.withLock { recordedSignals.append(signal) }; return 0 }
}
