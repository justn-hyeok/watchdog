import Darwin
import XCTest
@testable import Watchdog

/// Tests for the auto-suspend policy: only newly flagged processes are
/// SIGSTOPed, suspended or protected ones are skipped, and every signal goes
/// through the standard authorization pipeline.
@MainActor
final class AutoSuspendPolicyTests: XCTestCase {
    func testAutoSuspendSendsSIGSTOPToNewlyHotProcessWhenEnabled() async throws {
        let signals = SignalRecorder()
        let process = snapshot(pid: 7_001, name: "/usr/local/bin/claude", cpu: 180)
        let controller = makeController(signals: signals, facts: process)
        let monitor = ProcessMonitor(defaults: makeDefaults(), controller: controller)
        monitor.autoSuspendEnabled = true

        monitor.loadActionablePreview(processes: [process], hotProcesses: [], updatedAt: Date())
        await monitor.refreshAutoSuspendPreview(
            hot: [process.identity],
            highMemory: [],
            snapshots: [process]
        )

        let recorded = signals.values
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded.first?.pid, process.id)
        XCTAssertEqual(recorded.first?.signal, SIGSTOP)
    }

    func testAutoSuspendDisabledSendsNoSignals() async throws {
        let signals = SignalRecorder()
        let process = snapshot(pid: 7_002, name: "/usr/local/bin/claude", cpu: 180)
        let controller = makeController(signals: signals, facts: process)
        let monitor = ProcessMonitor(defaults: makeDefaults(), controller: controller)
        monitor.autoSuspendEnabled = false

        monitor.loadActionablePreview(processes: [process], hotProcesses: [], updatedAt: Date())
        await monitor.refreshAutoSuspendPreview(
            hot: [process.identity],
            highMemory: [],
            snapshots: [process]
        )

        let recorded = signals.values
        XCTAssertTrue(recorded.isEmpty)
    }

    func testAutoSuspendSkipsProtectedProcesses() async throws {
        let signals = SignalRecorder()
        // System-path processes are protected and must never be signaled.
        let process = snapshot(pid: 7_003, name: "/usr/sbin/systemd-helper", cpu: 180)
        let controller = makeController(signals: signals, facts: process)
        let monitor = ProcessMonitor(defaults: makeDefaults(), controller: controller)
        monitor.autoSuspendEnabled = true

        monitor.loadActionablePreview(processes: [process], hotProcesses: [], updatedAt: Date())
        await monitor.refreshAutoSuspendPreview(
            hot: [process.identity],
            highMemory: [],
            snapshots: [process]
        )

        let recorded = signals.values
        XCTAssertTrue(recorded.isEmpty)
    }

    func testAutoSuspendSkipsAlreadySuspendedProcesses() async throws {
        let signals = SignalRecorder()
        let process = snapshot(pid: 7_004, name: "/usr/local/bin/claude", cpu: 180, state: "T")
        let controller = makeController(signals: signals, facts: process)
        let monitor = ProcessMonitor(defaults: makeDefaults(), controller: controller)
        monitor.autoSuspendEnabled = true

        monitor.loadActionablePreview(processes: [process], hotProcesses: [], updatedAt: Date())
        await monitor.refreshAutoSuspendPreview(
            hot: [process.identity],
            highMemory: [],
            snapshots: [process]
        )

        let recorded = signals.values
        XCTAssertTrue(recorded.isEmpty)
    }

    // MARK: - Helpers

    private func makeController(
        signals: SignalRecorder,
        facts process: ProcessSnapshot
    ) -> ProcessController {
        ProcessController(
            factsReader: { _ in
                .found(
                    LiveProcessFacts(
                        identity: process.identity,
                        executablePath: process.executablePath,
                        isSuspended: process.isSuspended
                    )
                )
            },
            signalSender: { pid, signal in
                signals.record(pid: pid, signal: signal)
                return 0
            }
        )
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
        state: String = "R"
    ) -> ProcessSnapshot {
        ProcessSnapshot(
            id: pid,
            parentPID: 2,
            processGroupID: pid,
            userID: getuid(),
            tty: "ttys001",
            cpuPercent: cpu,
            residentBytes: 0,
            state: state,
            elapsed: "00:10",
            executablePath: name,
            startTimeMicroseconds: UInt64(pid) * 1_000_000,
            workingDirectory: nil
        )
    }
}

private final class SignalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(pid: Int32, signal: Int32)] = []

    var values: [(pid: Int32, signal: Int32)] {
        lock.withLock { storage }
    }

    func record(pid: Int32, signal: Int32) {
        lock.withLock {
            storage.append((pid: pid, signal: signal))
        }
    }
}
