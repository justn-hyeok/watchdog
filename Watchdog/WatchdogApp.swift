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
    private enum InstanceLockResult {
        case acquired
        case heldByAnotherInstance
        case unavailable
    }

    private var instanceLockFileDescriptor: Int32 = -1

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let isUITestFixture = arguments.contains("--ui-test-fixture")
            || arguments.contains("--ui-test-stale-fixture")
            || arguments.contains("--ui-test-outcome-fixture")
            || arguments.contains("--ui-test-exited-fixture")
            || arguments.contains("--ui-test-still-running-fixture")
        if !isUITestFixture {
            switch acquireInstanceLock() {
            case .heldByAnotherInstance:
                activateExistingInstanceIfPresent()
                NSApplication.shared.terminate(nil)
                return
            case .acquired, .unavailable:
                break
            }
        }
        NSApplication.shared.setActivationPolicy(isUITestFixture ? .regular : .accessory)
        if isUITestFixture {
            Task { @MainActor in
                await Task.yield()
                WatchdogUITestFixtureHost.showWindowIfNeeded()
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
        }
        #else
        if case .heldByAnotherInstance = acquireInstanceLock() {
            activateExistingInstanceIfPresent()
            NSApplication.shared.terminate(nil)
            return
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        #endif
    }

    private func acquireInstanceLock() -> InstanceLockResult {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return .unavailable
        }
        let directory = applicationSupport.appendingPathComponent("Watchdog", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            return .unavailable
        }

        let descriptor = Darwin.open(
            directory.appendingPathComponent("instance.lock").path,
            O_CREAT | O_RDWR,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { return .unavailable }
        var fileLock = Darwin.flock()
        fileLock.l_start = 0
        fileLock.l_len = 0
        fileLock.l_pid = 0
        fileLock.l_type = Int16(F_WRLCK)
        fileLock.l_whence = Int16(SEEK_SET)
        guard fcntl(descriptor, F_SETLK, &fileLock) == 0 else {
            let lockError = errno
            Darwin.close(descriptor)
            return lockError == EACCES || lockError == EAGAIN
                ? .heldByAnotherInstance
                : .unavailable
        }
        instanceLockFileDescriptor = descriptor
        return .acquired
    }

    private func activateExistingInstanceIfPresent() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        guard let existing = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter({ $0.processIdentifier != getpid() })
            .min(by: {
                ($0.launchDate ?? .distantFuture) < ($1.launchDate ?? .distantFuture)
            })
        else {
            return
        }
        existing.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }
}

private struct WatchdogMenuBarIcon: View {
    let alertCount: Int

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(lineWidth: alertCount == 0 ? 1 : 1.4)

            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 14, height: 16)

            if alertCount > 0 {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 6, height: 6)
                    .overlay {
                        Circle()
                            .strokeBorder(Color(nsColor: .controlBackgroundColor), lineWidth: 1)
                    }
                    .offset(x: 3, y: -3)
            }
        }
        .frame(width: 18, height: 16)
        .symbolRenderingMode(.monochrome)
        .accessibilityLabel("Watchdog")
        .accessibilityValue(
            alertCount == 0 ? "감시 중인 프로세스가 안정적입니다" : "\(alertCount)개 프로세스 주의 필요"
        )
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
            Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    monitor.refreshActionablePreviewObservation()
                }
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
            WatchdogMenuBarIcon(alertCount: monitor.alertCount)
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
