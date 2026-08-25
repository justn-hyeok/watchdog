import Darwin
import SwiftUI

@main
struct WatchdogPreviewApp: App {
    @StateObject private var monitor: ProcessMonitor

    init() {
        let monitor = ProcessMonitor()
#if DEBUG
        if CommandLine.arguments.contains("--ui-test-fixture") {
            let processes = Self.uiTestProcesses
            monitor.loadPreview(
                processes: processes,
                hotProcesses: Set(processes.filter { $0.id == 71_001 }.map(\.identity)),
                highMemoryProcesses: Set(processes.filter { $0.id == 71_002 }.map(\.identity)),
                updatedAt: Date(timeIntervalSince1970: 1_787_638_400)
            )
        }
#endif
        _monitor = StateObject(wrappedValue: monitor)
    }

    var body: some Scene {
        WindowGroup("Watchdog 미리보기") {
            WatchdogMenuView(monitor: monitor)
                .frame(minWidth: 480, minHeight: 590)
        }
        .defaultSize(width: 480, height: 590)
    }

#if DEBUG
    private static let uiTestProcesses = [
        process(
            pid: 71_001,
            parentPID: 70_001,
            cpuPercent: 188,
            residentMemoryMB: 640,
            executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome Helper (Renderer)"
        ),
        process(
            pid: 71_002,
            parentPID: 70_002,
            cpuPercent: 42,
            residentMemoryMB: 3_200,
            executablePath: "/Users/preview/.local/bin/gjc",
            workingDirectory: "/Users/preview/Projects/high-memory-agent"
        ),
        process(
            pid: 71_003,
            parentPID: 1,
            cpuPercent: 31,
            residentMemoryMB: 480,
            executablePath: "/Users/preview/.local/bin/codex",
            workingDirectory: "/Users/preview/Projects/orphan-agent",
            orphanReason: .detachedSession
        ),
    ]

    private static func process(
        pid: Int32,
        parentPID: Int32,
        cpuPercent: Double,
        residentMemoryMB: UInt64,
        executablePath: String,
        workingDirectory: String? = nil,
        orphanReason: OrphanReason? = nil
    ) -> ProcessSnapshot {
        ProcessSnapshot(
            id: pid,
            parentPID: parentPID,
            processGroupID: pid,
            userID: getuid(),
            tty: "ttys001",
            cpuPercent: cpuPercent,
            residentBytes: residentMemoryMB * 1_024 * 1_024,
            state: "R",
            elapsed: "00:42:10",
            executablePath: executablePath,
            startTimeMicroseconds: UInt64(9_000_000 + pid),
            workingDirectory: workingDirectory,
            orphanReason: orphanReason
        )
    }
#endif
}
