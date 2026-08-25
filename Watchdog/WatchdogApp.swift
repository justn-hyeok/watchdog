import AppKit
import Darwin
import SwiftUI

#if DEBUG
@MainActor
private enum WatchdogUITestFixtureHost {
    static var monitor: ProcessMonitor?
    static var window: NSWindow?

    static func showWindowIfNeeded() {
        guard window == nil, let monitor else { return }
        let hosting = NSHostingView(rootView: WatchdogMenuView(monitor: monitor))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 590),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Watchdog UI 테스트"
        window.contentView = hosting
        window.center()
        window.makeKeyAndOrderFront(nil)
        Self.window = window
    }
}
#endif

@MainActor
final class WatchdogAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let isUITestFixture = arguments.contains("--ui-test-fixture")
            || arguments.contains("--ui-test-stale-fixture")
            || arguments.contains("--ui-test-outcome-fixture")
            || arguments.contains("--ui-test-exited-fixture")
            || arguments.contains("--ui-test-still-running-fixture")
        NSApplication.shared.setActivationPolicy(isUITestFixture ? .regular : .accessory)
        if isUITestFixture {
            Task { @MainActor in
                await Task.yield()
                WatchdogUITestFixtureHost.showWindowIfNeeded()
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
        }
        #else
        NSApplication.shared.setActivationPolicy(.accessory)
        #endif
        terminateOlderInstances()
    }

    private func terminateOlderInstances() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }

        for application in NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        where application.processIdentifier != getpid() {
            application.terminate()
        }
    }
}

@main
struct WatchdogApp: App {
    @NSApplicationDelegateAdaptor(WatchdogAppDelegate.self) private var appDelegate
    @StateObject private var monitor: ProcessMonitor
    private let showsFixtureWindow: Bool

    @MainActor
    init() {
        let monitor = ProcessMonitor()
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let usesActionableFixture = arguments.contains("--ui-test-fixture")
        let usesStaleFixture = arguments.contains("--ui-test-stale-fixture")
        let usesOutcomeFixture = arguments.contains("--ui-test-outcome-fixture")
        let usesExitedFixture = arguments.contains("--ui-test-exited-fixture")
        let usesStillRunningFixture = arguments.contains("--ui-test-still-running-fixture")
        showsFixtureWindow = usesActionableFixture || usesStaleFixture
            || usesOutcomeFixture || usesExitedFixture || usesStillRunningFixture
        if usesActionableFixture || usesOutcomeFixture || usesExitedFixture || usesStillRunningFixture {
            monitor.loadActionablePreview(
                processes: Self.fixtureProcesses,
                hotProcesses: [Self.fixtureProcesses[0].identity],
                highMemoryProcesses: [Self.fixtureProcesses[0].identity],
                updatedAt: Date()
            )
            if usesOutcomeFixture {
                monitor.setActionOutcomePreview(.verificationFailed, for: Self.fixtureProcesses[0])
            } else if usesExitedFixture {
                monitor.setActionOutcomePreview(.exited, for: Self.fixtureProcesses[0])
            } else if usesStillRunningFixture {
                monitor.setActionOutcomePreview(.stillRunning, for: Self.fixtureProcesses[0])
            }
        } else if usesStaleFixture {
            monitor.loadStalePreview(
                processes: Self.fixtureProcesses,
                hotProcesses: [Self.fixtureProcesses[0].identity],
                highMemoryProcesses: [Self.fixtureProcesses[0].identity],
                updatedAt: Date(timeIntervalSinceNow: -6)
            )
        } else {
            monitor.start()
        }
        if showsFixtureWindow {
            WatchdogUITestFixtureHost.monitor = monitor
        }
        #else
        showsFixtureWindow = false
        monitor.start()
        #endif
        _monitor = StateObject(wrappedValue: monitor)
    }

    var body: some Scene {
        MenuBarExtra {
            WatchdogMenuView(monitor: monitor)
        } label: {
            Label("Watchdog", systemImage: monitor.alertCount == 0 ? "waveform.path.ecg" : "exclamationmark.triangle.fill")
        }
        .menuBarExtraStyle(.window)
    }

    #if DEBUG
    private static let fixtureProcesses: [ProcessSnapshot] = [
        ProcessSnapshot(
            id: 71_001,
            parentPID: 600,
            processGroupID: 71_001,
            userID: getuid(),
            tty: "ttys001",
            cpuPercent: 184,
            residentBytes: 5 * 1_024 * 1_024 * 1_024,
            state: "R",
            elapsed: "00:12:34",
            executablePath: "/usr/local/bin/claude",
            startTimeMicroseconds: 9_071_001,
            workingDirectory: "/tmp/watchdog-fixture",
            orphanReason: .detachedSession
        ),
        ProcessSnapshot(
            id: 71_002,
            parentPID: 600,
            processGroupID: 71_002,
            userID: getuid(),
            tty: "ttys002",
            cpuPercent: 12,
            residentBytes: 256 * 1_024 * 1_024,
            state: "R",
            elapsed: "00:02:10",
            executablePath: "/usr/local/bin/codex",
            startTimeMicroseconds: 9_071_002,
            workingDirectory: "/tmp/watchdog-second"
        ),
    ]
    #endif
}
