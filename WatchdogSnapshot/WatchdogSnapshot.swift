import AppKit
import Darwin
import SwiftUI

@main
@MainActor
struct WatchdogSnapshot {
    static func main() throws {
        let outputPath = CommandLine.arguments.dropFirst().first
            ?? "DerivedData/watchdog-ui.png"

        let monitor = ProcessMonitor(defaults: UserDefaults(suiteName: "dev.justn.watchdog.snapshot") ?? .standard)
        let processes = previewProcesses()
        monitor.loadPreview(
            processes: processes,
            hotProcesses: Set(processes.filter { [7_101, 7_102].contains($0.id) }.map(\.identity)),
            highMemoryProcesses: Set(processes.filter { $0.id == 7_102 }.map(\.identity)),
            updatedAt: Date(timeIntervalSince1970: 1_787_638_400)
        )

        NSApplication.shared.setActivationPolicy(.prohibited)

        let rootView = WatchdogMenuView(monitor: monitor)
            .frame(width: 480, height: 540)
            .background(Color(nsColor: .windowBackgroundColor))
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 480, height: 540)
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.layoutSubtreeIfNeeded()

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 960,
            pixelsHigh: 1_080,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw SnapshotError.couldNotCreateBitmap
        }

        bitmap.size = hostingView.bounds.size
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)

        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw SnapshotError.couldNotEncodePNG
        }

        try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }

    private static func previewProcesses() -> [ProcessSnapshot] {
        [
            process(
                pid: 7_101,
                parent: 6_789,
                cpu: 166,
                memory: 720,
                name: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome Helper (Renderer)"
            ),
            process(
                pid: 7_102,
                parent: 7_000,
                cpu: 92,
                memory: 3_100,
                name: "/Users/justn/.local/bin/gjc",
                cwd: "/Users/justn/orca/projects/jagalchi/jagalchi-client"
            ),
            process(
                pid: 7_103,
                parent: 1,
                cpu: 48,
                memory: 880,
                name: "/Users/justn/.local/bin/gjc",
                cwd: "/Users/justn/orca/projects/gh-star",
                orphan: true
            ),
        ]
    }

    private static func process(
        pid: Int32,
        parent: Int32,
        cpu: Double,
        memory: UInt64,
        name: String,
        cwd: String? = nil,
        orphan: Bool = false
    ) -> ProcessSnapshot {
        ProcessSnapshot(
            id: pid,
            parentPID: parent,
            processGroupID: pid,
            userID: getuid(),
            tty: "ttys009",
            cpuPercent: cpu,
            residentBytes: memory * 1_024 * 1_024,
            state: "R",
            elapsed: "01:34:20",
            executablePath: name,
            startTimeMicroseconds: UInt64(1_000_000 + pid),
            workingDirectory: cwd,
            orphanReason: orphan ? .detachedSession : nil
        )
    }

    private enum SnapshotError: Error {
        case couldNotCreateBitmap
        case couldNotEncodePNG
    }
}
