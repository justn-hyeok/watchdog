import Darwin
import Foundation

struct RawProcessMetrics: Sendable {
    let startTimeMicroseconds: UInt64
    let totalCPUTimeNanoseconds: UInt64
    let residentBytes: UInt64
    let userID: UInt32
}

struct LiveProcessFacts: Sendable {
    let identity: ProcessIdentity
    let executablePath: String
    let isSuspended: Bool

    var isSystemPath: Bool {
        let path = executablePath.lowercased()
        return path.hasPrefix("/system/")
            || path.hasPrefix("/usr/libexec/")
            || path.hasPrefix("/usr/sbin/")
            || path.hasPrefix("/sbin/")
    }
}

enum LiveProcessLookup: Sendable {
    case found(LiveProcessFacts)
    case absent
    case failed
}

enum ProcessMetricsReader {
    static func read(pid: Int32) -> RawProcessMetrics? {
        var bsdInfo = proc_bsdinfo()
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let bsdResult = withUnsafeMutablePointer(to: &bsdInfo) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, bsdSize)
        }

        guard bsdResult == bsdSize else { return nil }

        var taskInfo = proc_taskinfo()
        let taskSize = Int32(MemoryLayout<proc_taskinfo>.stride)
        let taskResult = withUnsafeMutablePointer(to: &taskInfo) { pointer in
            proc_pidinfo(pid, PROC_PIDTASKINFO, 0, pointer, taskSize)
        }

        guard taskResult == taskSize else { return nil }

        return RawProcessMetrics(
            startTimeMicroseconds: bsdInfo.pbi_start_tvsec * 1_000_000 + bsdInfo.pbi_start_tvusec,
            totalCPUTimeNanoseconds: taskInfo.pti_total_user + taskInfo.pti_total_system,
            residentBytes: taskInfo.pti_resident_size,
            userID: bsdInfo.pbi_uid
        )
    }

    static func liveFacts(pid: Int32) -> LiveProcessLookup {
        guard pid > 0 else { return .absent }
        var bsdInfo = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        errno = 0
        let result = withUnsafeMutablePointer(to: &bsdInfo) {
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, size)
        }
        guard result == size else {
            return errno == ESRCH ? .absent : .failed
        }

        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN * 4))
        errno = 0
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard pathLength > 0 else {
            return errno == ESRCH ? .absent : .failed
        }

        return .found(
            LiveProcessFacts(
                identity: ProcessIdentity(
                    pid: pid,
                    startTimeMicroseconds: bsdInfo.pbi_start_tvsec * 1_000_000
                        + bsdInfo.pbi_start_tvusec,
                    userID: bsdInfo.pbi_uid
                ),
                executablePath: String(
                    decoding: pathBuffer.prefix(Int(pathLength)).map { UInt8(bitPattern: $0) },
                    as: UTF8.self
                ),
                isSuspended: bsdInfo.pbi_status == UInt32(SSTOP)
            )
        )
    }
}

struct ProcessCPUTracker {
    private var previousCPUTime: [ProcessIdentity: UInt64] = [:]
    private var previousUptimeNanoseconds: UInt64?

    mutating func percentages(
        for metrics: [(identity: ProcessIdentity, totalCPUTimeNanoseconds: UInt64)],
        at uptimeNanoseconds: UInt64
    ) -> [ProcessIdentity: Double] {
        defer {
            previousCPUTime = Dictionary(uniqueKeysWithValues: metrics.map {
                ($0.identity, $0.totalCPUTimeNanoseconds)
            })
            previousUptimeNanoseconds = uptimeNanoseconds
        }

        guard let previousUptimeNanoseconds,
              uptimeNanoseconds > previousUptimeNanoseconds
        else {
            return [:]
        }

        let elapsed = uptimeNanoseconds - previousUptimeNanoseconds
        var result: [ProcessIdentity: Double] = [:]

        for metric in metrics {
            guard let previous = previousCPUTime[metric.identity],
                  metric.totalCPUTimeNanoseconds >= previous
            else {
                continue
            }

            let delta = metric.totalCPUTimeNanoseconds - previous
            result[metric.identity] = Double(delta) / Double(elapsed) * 100
        }

        return result
    }
}

struct SystemCPUTicks: Equatable, Sendable {
    let user: UInt64
    let system: UInt64
    let idle: UInt64
    let nice: UInt64
}

enum MemoryPressureLevel: Int32, Sendable {
    case normal = 1
    case warning = 2
    case critical = 4
    case unknown = 0

    var localizedDescription: String {
        switch self {
        case .normal: return "정상"
        case .warning: return "주의"
        case .critical: return "위험"
        case .unknown: return "확인 불가"
        }
    }
}

struct SystemMemorySnapshot: Equatable, Sendable {
    let totalBytes: UInt64
    let usedBytes: UInt64
    let compressedBytes: UInt64
    let swapUsedBytes: UInt64?
    let swapTotalBytes: UInt64?
    let pressureLevel: MemoryPressureLevel

    init(
        totalBytes: UInt64,
        usedBytes: UInt64,
        compressedBytes: UInt64,
        swapUsedBytes: UInt64? = nil,
        swapTotalBytes: UInt64? = nil,
        pressureLevel: MemoryPressureLevel
    ) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.compressedBytes = compressedBytes
        self.swapUsedBytes = swapUsedBytes
        self.swapTotalBytes = swapTotalBytes
        self.pressureLevel = pressureLevel
    }

    var usedPercent: Double {
        guard totalBytes > 0 else { return 0 }
        return min(100, Double(usedBytes) / Double(totalBytes) * 100)
    }
}

enum SystemMetricsReader {
    static func cpuTicks() -> SystemCPUTicks? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)

        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else { return nil }

        return SystemCPUTicks(
            user: UInt64(info.cpu_ticks.0),
            system: UInt64(info.cpu_ticks.1),
            idle: UInt64(info.cpu_ticks.2),
            nice: UInt64(info.cpu_ticks.3)
        )
    }

    static func memory() -> SystemMemorySnapshot? {
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }

        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else { return nil }

        let total = ProcessInfo.processInfo.physicalMemory
        let reclaimablePages = UInt64(statistics.free_count + statistics.speculative_count)
        let reclaimableBytes = reclaimablePages * UInt64(pageSize)
        let used = total > reclaimableBytes ? total - reclaimableBytes : 0
        let compressed = UInt64(statistics.compressor_page_count) * UInt64(pageSize)

        var pressureRaw: Int32 = 0
        var pressureSize = MemoryLayout<Int32>.size
        let pressureResult = sysctlbyname(
            "kern.memorystatus_vm_pressure_level",
            &pressureRaw,
            &pressureSize,
            nil,
            0
        )
        let pressure = pressureResult == 0
            ? MemoryPressureLevel(rawValue: pressureRaw) ?? .unknown
            : .unknown

        var swapUsage = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let swapResult = sysctlbyname(
            "vm.swapusage",
            &swapUsage,
            &swapSize,
            nil,
            0
        )

        return SystemMemorySnapshot(
            totalBytes: total,
            usedBytes: used,
            compressedBytes: compressed,
            swapUsedBytes: swapResult == 0 ? swapUsage.xsu_used : nil,
            swapTotalBytes: swapResult == 0 ? swapUsage.xsu_total : nil,
            pressureLevel: pressure
        )
    }
}

struct SystemCPUTracker {
    private var previous: SystemCPUTicks?

    mutating func percentage(for current: SystemCPUTicks) -> Double? {
        defer { previous = current }
        guard let previous else { return nil }

        let user = delta(current.user, previous.user)
        let system = delta(current.system, previous.system)
        let idle = delta(current.idle, previous.idle)
        let nice = delta(current.nice, previous.nice)
        let total = user + system + idle + nice

        guard total > 0 else { return nil }
        return Double(user + system + nice) / Double(total) * 100
    }

    private func delta(_ current: UInt64, _ previous: UInt64) -> UInt64 {
        current >= previous ? current - previous : 0
    }
}
