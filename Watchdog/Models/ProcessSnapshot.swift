import Darwin
import Foundation

enum ProcessKind: String, Sendable {
    case agent
    case browserRenderer
    case application
    case system
    case other
}

struct ProcessIdentity: Hashable, Sendable {
    let pid: Int32
    let startTimeMicroseconds: UInt64
    let userID: UInt32
}

struct ObservationToken: Sendable {
    let generation: UInt64
    let instant: ContinuousClock.Instant
}

enum ObservationFreshness: String, Sendable {
    case current
    case stale
    case unavailable
}

enum AlertReason: Hashable, Sendable {
    case sustainedCPU(percent: Double)
    case sustainedMemory(bytes: UInt64)
    case orphan(OrphanReason)

    var text: String {
        switch self {
        case let .sustainedCPU(percent):
            return "CPU \(Int(percent))% 이상이 지속됨"
        case let .sustainedMemory(bytes):
            return "메모리 \(ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)) 이상이 지속됨"
        case let .orphan(reason):
            return reason.localizedDescription
        }
    }
}

struct ProcessActionability: Sendable {
    let identity: ProcessIdentity
    let observation: ObservationToken?
    let freshness: ObservationFreshness
    let isIgnored: Bool
    let isProtected: Bool

    var canAct: Bool {
        observation != nil && freshness == .current && !isIgnored && !isProtected
    }
}

enum OrphanReason: String, Sendable {
    case reparentedToLaunchd
    case missingParent
    case cyclicLineage
    case detachedSession

    var localizedDescription: String {
        switch self {
        case .reparentedToLaunchd:
            return "부모 프로세스가 launchd로 바뀌었습니다"
        case .missingParent:
            return "부모 프로세스를 찾을 수 없습니다"
        case .cyclicLineage:
            return "비정상적인 부모 계보가 감지됐습니다"
        case .detachedSession:
            return "연결된 터미널 세션을 찾을 수 없습니다"
        }
    }
}

struct ProcessSnapshot: Identifiable, Equatable, Sendable {
    let id: Int32
    let parentPID: Int32
    let processGroupID: Int32
    let userID: UInt32
    let tty: String
    var cpuPercent: Double
    var residentBytes: UInt64
    let state: String
    let elapsed: String
    let executablePath: String
    var startTimeMicroseconds: UInt64 = 0
    var workingDirectory: String?
    var orphanReason: OrphanReason? = nil

    var identity: ProcessIdentity {
        ProcessIdentity(
            pid: id,
            startTimeMicroseconds: startTimeMicroseconds,
            userID: userID
        )
    }

    var suspectedOrphan: Bool {
        orphanReason != nil
    }

    var displayName: String {
        if executablePath.contains("Google Chrome Helper (Renderer)") {
            return "Chrome 렌더러"
        }

        if executablePath.contains("Google Chrome Helper") {
            return "Chrome 도우미"
        }

        let name = URL(fileURLWithPath: executablePath).lastPathComponent
        return name.isEmpty ? executablePath : name
    }

    var kind: ProcessKind {
        let lowercasePath = executablePath.lowercased()

        if executablePath.contains("Google Chrome Helper (Renderer)") {
            return .browserRenderer
        }

        if lowercasePath.hasPrefix("/system/") || lowercasePath.hasPrefix("/usr/libexec/") {
            return .system
        }

        if lowercasePath.contains(".app/contents/") {
            return .application
        }

        if Self.agentNames.contains(displayName.lowercased()) {
            return .agent
        }

        return .other
    }

    var projectName: String? {
        guard let workingDirectory,
              !workingDirectory.isEmpty,
              workingDirectory != "/"
        else {
            return nil
        }

        let name = URL(fileURLWithPath: workingDirectory).lastPathComponent
        return name.isEmpty ? nil : name
    }

    var isSuspended: Bool {
        state.contains("T")
    }

    var isProtected: Bool {
        let lowercasePath = executablePath.lowercased()
        return id <= 1
            || id == getpid()
            || startTimeMicroseconds == 0
            || userID != getuid()
            || lowercasePath.hasPrefix("/system/")
            || lowercasePath.hasPrefix("/usr/libexec/")
            || lowercasePath.hasPrefix("/usr/sbin/")
            || lowercasePath.hasPrefix("/sbin/")
    }

    var canControl: Bool {
        !isProtected
    }

    private static let agentNames: Set<String> = [
        "claude",
        "codex",
        "cursor-agent",
        "gjc",
        "opencode",
        "pi",
    ]
}
