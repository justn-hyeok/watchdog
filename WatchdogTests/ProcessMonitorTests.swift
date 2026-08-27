import Darwin
import Foundation
import XCTest
@testable import Watchdog

@MainActor
final class ProcessMonitorTests: XCTestCase {
    func testSearchRunsBeforeAllScopeLimit() {
        let monitor = makeMonitor()
        var processes: [ProcessSnapshot] = []
        for index in 0..<61 {
            processes.append(
                snapshot(
                    pid: Int32(1_000 + index),
                    name: index == 60 ? "/usr/local/bin/needle-process" : "/usr/local/bin/process-\(index)",
                    cpu: Double(100 - index)
                )
            )
        }
        monitor.loadPreview(processes: processes, hotProcesses: [], updatedAt: Date())

        XCTAssertEqual(monitor.visibleProcesses(scope: .all, search: "needle").map(\.displayName), ["needle-process"])
    }

    func testAttentionAndAlertCountDeduplicateAllReasons() {
        let monitor = makeMonitor()
        var process = snapshot(pid: 2_000, name: "/usr/local/bin/gjc", cpu: 120, memoryGB: 3)
        process.orphanReason = .detachedSession
        monitor.loadPreview(
            processes: [process],
            hotProcesses: [process.identity],
            highMemoryProcesses: [process.identity],
            updatedAt: Date()
        )

        XCTAssertEqual(monitor.alertCount, 1)
        XCTAssertEqual(monitor.visibleProcesses(scope: .attention, search: ""), [process])
        XCTAssertEqual(
            monitor.alertReasons(for: process),
            [
                .sustainedCPU(percent: monitor.threshold),
                .sustainedMemory(bytes: UInt64(monitor.memoryThresholdGB * 1_024 * 1_024 * 1_024)),
                .orphan(.detachedSession),
            ]
        )
    }

    func testIgnoreSuppressesAllAttentionAndUndoRestoresOrphanAttention() {
        let monitor = makeMonitor()
        var process = snapshot(pid: 2_000, name: "/usr/local/bin/gjc", cpu: 120, memoryGB: 3)
        process.orphanReason = .missingParent
        monitor.loadPreview(
            processes: [process],
            hotProcesses: [process.identity],
            highMemoryProcesses: [process.identity],
            updatedAt: Date()
        )

        monitor.ignoreUntilExit(process)
        XCTAssertTrue(monitor.isIgnored(process))
        XCTAssertFalse(monitor.isHot(process))
        XCTAssertFalse(monitor.isHighMemory(process))
        XCTAssertEqual(monitor.alertReasons(for: process), [])
        XCTAssertEqual(monitor.alertCount, 0)
        XCTAssertEqual(monitor.visibleProcesses(scope: .attention, search: ""), [])

        monitor.undoIgnore(process)
        XCTAssertFalse(monitor.isIgnored(process))
        XCTAssertEqual(
            monitor.alertReasons(for: process),
            [
                .sustainedCPU(percent: monitor.threshold),
                .sustainedMemory(bytes: UInt64(monitor.memoryThresholdGB * 1_024 * 1_024 * 1_024)),
                .orphan(.missingParent),
            ]
        )
        XCTAssertEqual(monitor.alertCount, 1)
        XCTAssertEqual(monitor.visibleProcesses(scope: .attention, search: ""), [process])
    }

    func testIgnoreIsIsolatedFromReusedPID() {
        let monitor = makeMonitor()
        var old = snapshot(pid: 2_000, name: "/usr/local/bin/gjc", startTime: 1_000_000)
        old.orphanReason = .detachedSession
        monitor.loadPreview(processes: [old], hotProcesses: [old.identity], updatedAt: Date())
        monitor.ignoreUntilExit(old)

        var reused = snapshot(pid: 2_000, name: "/usr/local/bin/gjc", startTime: 2_000_000)
        reused.orphanReason = .detachedSession
        monitor.loadPreview(processes: [reused], hotProcesses: [reused.identity], updatedAt: Date())

        XCTAssertFalse(monitor.isIgnored(reused))
        XCTAssertTrue(monitor.isHot(reused))
        XCTAssertEqual(monitor.alertCount, 1)
        XCTAssertEqual(monitor.visibleProcesses(scope: .attention, search: ""), [reused])
    }

    func testIgnoreListRefusesEntriesBeyondCapacity() {
        let monitor = makeMonitor()
        let processes = (0..<513).map {
            snapshot(pid: Int32(6_000 + $0), name: "/usr/local/bin/gjc")
        }
        monitor.loadPreview(processes: processes, hotProcesses: [], updatedAt: Date())
        for process in processes.prefix(512) {
            monitor.ignoreUntilExit(process)
        }

        monitor.ignoreUntilExit(processes[512])

        XCTAssertTrue(processes.prefix(512).allSatisfy(monitor.isIgnored))
        XCTAssertFalse(monitor.isIgnored(processes[512]))
        guard case .error? = monitor.actionFeedback?.kind else {
            return XCTFail("Capacity refusal must surface error feedback")
        }
    }

    func testSettingsCanonicalizeNonFiniteAndOutOfRangeValues() {
        let monitor = makeMonitor()

        monitor.threshold = .nan
        XCTAssertEqual(monitor.threshold, 100)
        monitor.threshold = -.infinity
        XCTAssertEqual(monitor.threshold, 100)
        monitor.threshold = -1
        XCTAssertEqual(monitor.threshold, 1)
        monitor.threshold = 2_000
        XCTAssertEqual(monitor.threshold, 1_000)

        monitor.sustainedDuration = .infinity
        XCTAssertEqual(monitor.sustainedDuration, 20)
        monitor.sustainedDuration = 0
        XCTAssertEqual(monitor.sustainedDuration, 2)
        monitor.sustainedDuration = 400
        XCTAssertEqual(monitor.sustainedDuration, 300)

        monitor.memoryThresholdGB = .nan
        XCTAssertEqual(monitor.memoryThresholdGB, 2)
        monitor.memoryThresholdGB = 0
        XCTAssertEqual(monitor.memoryThresholdGB, 0.1)
        monitor.memoryThresholdGB = 2_000
        XCTAssertEqual(monitor.memoryThresholdGB, 1_024)
    }

    func testSettingsCanonicalizeInvalidPersistedValuesAtInitialization() {
        let defaults = makeDefaults()
        defaults.set(Double.nan, forKey: "threshold")
        defaults.set(Double.infinity, forKey: "sustainedDuration")
        defaults.set(-100.0, forKey: "memoryThresholdGB")

        let monitor = ProcessMonitor(defaults: defaults)

        XCTAssertEqual(monitor.threshold, 100)
        XCTAssertEqual(monitor.sustainedDuration, 20)
        XCTAssertEqual(monitor.memoryThresholdGB, 0.1)
        XCTAssertEqual(defaults.double(forKey: "threshold"), 100)
        XCTAssertEqual(defaults.double(forKey: "sustainedDuration"), 20)
        XCTAssertEqual(defaults.double(forKey: "memoryThresholdGB"), 0.1)
    }

    func testResolverUsesRawIdentityBeforeEnrichmentAndCapsGenerationAtEight() async {
        let calls = LockedResolverCalls()
        let resolver = WorkingDirectoryResolver(
            policy: resolverPolicy(),
            runner: { pid, deadline in
                calls.record(pid: pid, deadline: deadline)
                return "/projects/\(pid)"
            }
        )
        let delivered = expectation(description: "eight results")
        delivered.expectedFulfillmentCount = 8
        let snapshots = (0..<10).map {
            snapshot(pid: Int32(3_000 + $0), name: "/usr/local/bin/gjc")
        }

        await resolver.resolve(snapshots, generation: 7) { result in
            XCTAssertEqual(result.generation, 7)
            XCTAssertNil(snapshots.first { $0.identity == result.identity }?.workingDirectory)
            delivered.fulfill()
        }
        await fulfillment(of: [delivered], timeout: 1)

        XCTAssertEqual(calls.pids.count, 8)
        XCTAssertEqual(Set(calls.pids), Set(snapshots.prefix(8).map(\.id)))
        XCTAssertTrue(calls.deadlines.allSatisfy { $0 == .milliseconds(1_500) })
    }

    func testResolverPositiveAndNegativeCacheTTLsAndPIDReuseIsolation() async {
        let clock = MutableTestInstant()
        let calls = LockedResolverCalls { pid, invocation in
            switch (pid, invocation) {
            case (4_000, 1): return "/project"
            case (4_000, 2): return "/reused"
            case (4_000, 3): return "/project-refreshed"
            case (4_001, 1): return nil
            case (4_001, 2): return "/negative-refreshed"
            default: return nil
            }
        }
        let resolver = WorkingDirectoryResolver(
            policy: resolverPolicy(),
            now: { clock.now },
            runner: { pid, deadline in calls.next(pid: pid, deadline: deadline) }
        )
        let original = snapshot(pid: 4_000, name: "/usr/local/bin/gjc", startTime: 1)
        let negative = snapshot(pid: 4_001, name: "/usr/local/bin/gjc", startTime: 1)
        let reused = snapshot(pid: 4_000, name: "/usr/local/bin/gjc", startTime: 2)

        await resolveAndWait(resolver, snapshots: [original, negative], generation: 1, expected: 2)
        clock.advance(by: .seconds(14.999))
        await resolveAndWait(resolver, snapshots: [original, negative], generation: 2, expected: 2)
        XCTAssertEqual(calls.pids.count, 2)
        XCTAssertEqual(Set(calls.pids), Set<Int32>([4_000, 4_001]))

        await resolveAndWait(resolver, snapshots: [reused], generation: 3, expected: 1)
        XCTAssertEqual(calls.pids.count, 3)
        XCTAssertEqual(calls.pids.last, 4_000)

        clock.advance(by: .milliseconds(1))
        await resolveAndWait(resolver, snapshots: [negative], generation: 4, expected: 1)
        XCTAssertEqual(calls.pids.count, 4)
        XCTAssertEqual(calls.pids.last, 4_001)

        clock.advance(by: .seconds(45))
        await resolveAndWait(resolver, snapshots: [original], generation: 5, expected: 1)
        XCTAssertEqual(calls.pids.count, 5)
        XCTAssertEqual(calls.pids.last, 4_000)
    }

    func testResolverLimitsConcurrencyToTwoAndCancellationSuppressesResult() async {
        let gate = ResolverGate()
        let resolver = WorkingDirectoryResolver(
            policy: resolverPolicy(),
            runner: { pid, _ in await gate.run(pid: pid) }
        )
        let firstTwoEntered = expectation(description: "two active")
        firstTwoEntered.expectedFulfillmentCount = 2
        await gate.setOnEntry { firstTwoEntered.fulfill() }
        let unexpected = expectation(description: "cancelled generation result")
        unexpected.isInverted = true

        await resolver.resolve(
            (0..<3).map { snapshot(pid: Int32(5_000 + $0), name: "/usr/local/bin/gjc") },
            generation: 9
        ) { _ in unexpected.fulfill() }
        await fulfillment(of: [firstTwoEntered], timeout: 1)
        let maximumActive = await gate.maximumActive
        XCTAssertEqual(maximumActive, 2)
        await resolver.cancel(generation: 9)
        await gate.releaseAll()
        await fulfillment(of: [unexpected], timeout: 0.05)
    }

    func testDestructiveConfirmationUsesFreshObservationAfterRefresh() async throws {
        let signals = LockedSignals()
        let process = snapshot(pid: 5_500, name: "/usr/local/bin/gjc")
        let controller = ProcessController(
            factsReader: { _ in
                .found(
                    LiveProcessFacts(
                        identity: process.identity,
                        executablePath: process.executablePath,
                        isSuspended: false
                    )
                )
            },
            signalSender: { pid, signal in
                signals.record(pid: pid, signal: signal)
                return 0
            }
        )
        let monitor = ProcessMonitor(defaults: makeDefaults(), controller: controller)
        monitor.loadActionablePreview(processes: [process], hotProcesses: [], updatedAt: Date())
        let request = try monitor.destructiveActionRequest(.terminate, for: process)

        monitor.loadActionablePreview(processes: [process], hotProcesses: [], updatedAt: Date())
        try await monitor.completeDestructiveConfirmation(request)

        XCTAssertEqual(signals.values.count, 1)
        XCTAssertEqual(signals.values.first?.pid, process.id)
        XCTAssertEqual(signals.values.first?.signal, SIGTERM)
    }

    func testDestructiveConfirmationRejectsChangedIdentityAfterRefresh() async throws {
        let signals = LockedSignals()
        let process = snapshot(pid: 5_500, name: "/usr/local/bin/gjc", startTime: 1)
        let replacement = snapshot(pid: 5_500, name: "/usr/local/bin/gjc", startTime: 2)
        let controller = ProcessController(
            factsReader: { _ in
                .found(
                    LiveProcessFacts(
                        identity: replacement.identity,
                        executablePath: replacement.executablePath,
                        isSuspended: false
                    )
                )
            },
            signalSender: { pid, signal in
                signals.record(pid: pid, signal: signal)
                return 0
            }
        )
        let monitor = ProcessMonitor(defaults: makeDefaults(), controller: controller)
        monitor.loadActionablePreview(processes: [process], hotProcesses: [], updatedAt: Date())
        let request = try monitor.destructiveActionRequest(.terminate, for: process)
        monitor.loadActionablePreview(processes: [replacement], hotProcesses: [], updatedAt: Date())

        do {
            try await monitor.completeDestructiveConfirmation(request)
            XCTFail("A confirmation must remain bound to the original process identity")
        } catch ProcessControlError.staleObservation {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(signals.values.isEmpty)
    }

    func testConsumedAuthorizationCannotSignalAfterGenerationChanges() async throws {
        let gate = AuthorizationConsumeGate()
        let authorization = ProcessActionAuthorizationActor(
            consumeHook: { await gate.wait() }
        )
        let signals = LockedSignals()
        let process = snapshot(pid: 5_503, name: "/usr/local/bin/gjc")
        let controller = ProcessController(
            factsReader: { _ in
                .found(
                    LiveProcessFacts(
                        identity: process.identity,
                        executablePath: process.executablePath,
                        isSuspended: false
                    )
                )
            },
            signalSender: { pid, signal in
                signals.record(pid: pid, signal: signal)
                return 0
            }
        )
        let monitor = ProcessMonitor(
            defaults: makeDefaults(),
            authorization: authorization,
            controller: controller
        )
        monitor.loadActionablePreview(processes: [process], hotProcesses: [], updatedAt: Date())
        let request = try monitor.destructiveActionRequest(.terminate, for: process)

        let completion = Task {
            try await monitor.completeDestructiveConfirmation(request)
        }
        await gate.waitUntilEntered()
        monitor.loadActionablePreview(processes: [process], hotProcesses: [], updatedAt: Date())
        await gate.release()

        do {
            try await completion.value
            XCTFail("An authorization consumed for an old generation must not signal")
        } catch ProcessControlError.staleObservation {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(signals.values.isEmpty)
    }

    func testLateWorkingDirectoryResultCannotMergeIntoNewGeneration() {
        let monitor = makeMonitor()
        let process = snapshot(pid: 5_501, name: "/usr/local/bin/gjc")
        monitor.loadActionablePreview(processes: [process], hotProcesses: [], updatedAt: Date())
        let oldGeneration = monitor.previewGeneration
        monitor.loadActionablePreview(processes: [process], hotProcesses: [], updatedAt: Date())

        monitor.mergeWorkingDirectoryPreview(
            WorkingDirectoryResult(
                generation: oldGeneration,
                identity: process.identity,
                workingDirectory: "/stale/project"
            )
        )

        XCTAssertNil(monitor.processes.first?.workingDirectory)
    }

    func testTerminationLookupClassificationIsAuthoritative() {
        let process = snapshot(pid: 5_502, name: "/usr/local/bin/gjc")
        let same = LiveProcessFacts(
            identity: process.identity,
            executablePath: process.executablePath,
            isSuspended: false
        )
        let replacement = LiveProcessFacts(
            identity: ProcessIdentity(
                pid: process.id,
                startTimeMicroseconds: process.startTimeMicroseconds + 1,
                userID: process.userID
            ),
            executablePath: process.executablePath,
            isSuspended: false
        )

        XCTAssertNil(ProcessMonitor.terminationOutcome(for: .found(same), identity: process.identity))
        XCTAssertEqual(ProcessMonitor.terminationOutcome(for: .absent, identity: process.identity), .exited)
        XCTAssertEqual(ProcessMonitor.terminationOutcome(for: .found(replacement), identity: process.identity), .identityChanged)
        XCTAssertEqual(ProcessMonitor.terminationOutcome(for: .failed, identity: process.identity), .verificationFailed)
    }

    func testNotificationCooldownIsTenMinutesAndCappedAt512() {
        let monitor = makeMonitor()
        let instant = ContinuousClock().now
        let reason = AlertReason.sustainedCPU(percent: 100)
        let identities = (0..<513).map {
            ProcessIdentity(pid: Int32(20_000 + $0), startTimeMicroseconds: UInt64($0 + 1), userID: getuid())
        }

        for identity in identities.prefix(512) {
            XCTAssertTrue(monitor.reserveNotificationPreview(identity: identity, reason: reason, at: instant))
        }
        XCTAssertEqual(monitor.notificationCooldownCountPreview, 512)
        XCTAssertFalse(monitor.reserveNotificationPreview(identity: identities[512], reason: reason, at: instant))
        XCTAssertFalse(monitor.reserveNotificationPreview(identity: identities[0], reason: reason, at: instant.advanced(by: .seconds(599))))
        XCTAssertTrue(monitor.reserveNotificationPreview(identity: identities[0], reason: reason, at: instant.advanced(by: .seconds(600))))
    }

    func testTerminationPollIsDeduplicatedPerIdentityAndCleansUp() async {
        let monitor = makeMonitor()
        let identity = ProcessIdentity(pid: 99_991, startTimeMicroseconds: 1, userID: getuid())

        monitor.startTerminationPollPreview(for: identity)
        monitor.startTerminationPollPreview(for: identity)
        XCTAssertEqual(monitor.terminationPollCountPreview, 1)

        try? await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(monitor.terminationPollCountPreview, 0)
        XCTAssertEqual(monitor.actionOutcomes[identity], .exited)
    }

    private func resolveAndWait(
        _ resolver: WorkingDirectoryResolver,
        snapshots: [ProcessSnapshot],
        generation: UInt64,
        expected: Int
    ) async {
        let delivered = expectation(description: "resolver generation \(generation)")
        delivered.expectedFulfillmentCount = expected
        await resolver.resolve(snapshots, generation: generation) { _ in delivered.fulfill() }
        await fulfillment(of: [delivered], timeout: 1)
    }

    private func resolverPolicy() -> WorkingDirectoryResolver.Policy {
        .init(
            maximumConcurrentLookups: 2,
            lookupBudgetPerGeneration: 8,
            lookupDeadline: .milliseconds(1_500),
            cacheCapacity: 512,
            positiveTTL: .seconds(60),
            negativeTTL: .seconds(15)
        )
    }

    private func makeMonitor() -> ProcessMonitor {
        ProcessMonitor(defaults: makeDefaults())
    }

    private func makeDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "dev.justn.watchdog.tests.\(UUID().uuidString)")!
        defaults.set(false, forKey: "notificationsEnabled")
        return defaults
    }

    private func snapshot(
        pid: Int32,
        name: String,
        cpu: Double = 0,
        memoryGB: UInt64 = 0,
        startTime: UInt64? = nil
    ) -> ProcessSnapshot {
        ProcessSnapshot(
            id: pid,
            parentPID: 2,
            processGroupID: pid,
            userID: getuid(),
            tty: "ttys001",
            cpuPercent: cpu,
            residentBytes: memoryGB * 1_024 * 1_024 * 1_024,
            state: "R",
            elapsed: "00:10",
            executablePath: name,
            startTimeMicroseconds: startTime ?? UInt64(pid) * 1_000_000,
            workingDirectory: nil
        )
    }
}

private actor AuthorizationConsumeGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        for waiter in entryWaiters {
            waiter.resume()
        }
        entryWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        for waiter in releaseWaiters {
            waiter.resume()
        }
        releaseWaiters.removeAll()
    }
}

private final class LockedSignals: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(pid: Int32, signal: Int32)] = []

    var values: [(pid: Int32, signal: Int32)] {
        lock.withLock { storage }
    }

    func record(pid: Int32, signal: Int32) {
        lock.withLock {
            storage.append((pid, signal))
        }
    }
}

private final class MutableTestInstant: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock().now

    var now: ContinuousClock.Instant { lock.withLock { instant } }
    func advance(by duration: Duration) {
        lock.withLock { instant = instant.advanced(by: duration) }
    }
}

private final class LockedResolverCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedPIDs: [Int32] = []
    private var recordedDeadlines: [Duration] = []
    private var invocationCounts: [Int32: Int] = [:]
    private let resultProvider: @Sendable (Int32, Int) -> String?

    init(resultProvider: @escaping @Sendable (Int32, Int) -> String? = { _, _ in nil }) {
        self.resultProvider = resultProvider
    }

    var pids: [Int32] { lock.withLock { recordedPIDs } }
    var deadlines: [Duration] { lock.withLock { recordedDeadlines } }

    func record(pid: Int32, deadline: Duration) {
        lock.withLock {
            recordedPIDs.append(pid)
            recordedDeadlines.append(deadline)
        }
    }

    func next(pid: Int32, deadline: Duration) -> String? {
        lock.withLock {
            recordedPIDs.append(pid)
            recordedDeadlines.append(deadline)
            let invocation = invocationCounts[pid, default: 0] + 1
            invocationCounts[pid] = invocation
            return resultProvider(pid, invocation)
        }
    }
}

private actor ResolverGate {
    private var active = 0
    private(set) var maximumActive = 0
    private var waiters: [CheckedContinuation<String?, Never>] = []
    private var onEntry: (@Sendable () -> Void)?

    func setOnEntry(_ callback: @escaping @Sendable () -> Void) {
        onEntry = callback
    }

    func run(pid: Int32) async -> String? {
        active += 1
        maximumActive = max(maximumActive, active)
        onEntry?()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        } onCancel: {
            Task { await self.releaseOne() }
        }
    }

    func releaseAll() {
        let pending = waiters
        waiters.removeAll()
        active = 0
        for waiter in pending {
            waiter.resume(returning: nil)
        }
    }

    private func releaseOne() {
        guard !waiters.isEmpty else { return }
        active -= 1
        waiters.removeFirst().resume(returning: nil)
    }
}
