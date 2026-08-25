import Foundation

struct ProcessSample: Sendable {
    let processes: [ProcessSnapshot]
    let systemCPUPercent: Double?
    let systemMemory: SystemMemorySnapshot?
}

actor ProcessSampler {
    typealias Runner = @Sendable (String, [String], Duration) async throws -> String

    private let runner: Runner
    private var processCPUTracker = ProcessCPUTracker()
    private var systemCPUTracker = SystemCPUTracker()

    init(runner: @escaping Runner = { executable, arguments, deadline in
        try await CommandRunner.run(executable, arguments: arguments, deadline: deadline)
    }) {
        self.runner = runner
    }

    func sample() async throws -> ProcessSample {
        let output = try await runner(
            "/bin/ps",
            ["-axo", "pid=,ppid=,pgid=,uid=,tty=,rss=,state=,etime=,comm="],
            .seconds(2)
        )
        let parsed = ProcessListParser.parse(output)

        let uptime = DispatchTime.now().uptimeNanoseconds
        var processes: [ProcessSnapshot] = []
        var metricPoints: [(identity: ProcessIdentity, totalCPUTimeNanoseconds: UInt64)] = []

        for var snapshot in parsed {
            guard let metrics = ProcessMetricsReader.read(pid: snapshot.id),
                  metrics.userID == snapshot.userID
            else {
                processes.append(snapshot)
                continue
            }

            snapshot.startTimeMicroseconds = metrics.startTimeMicroseconds
            snapshot.residentBytes = metrics.residentBytes
            metricPoints.append((snapshot.identity, metrics.totalCPUTimeNanoseconds))
            processes.append(snapshot)
        }

        let percentages = processCPUTracker.percentages(for: metricPoints, at: uptime)
        for index in processes.indices {
            processes[index].cpuPercent = percentages[processes[index].identity] ?? 0
        }

        let systemCPUPercent = SystemMetricsReader.cpuTicks().flatMap {
            systemCPUTracker.percentage(for: $0)
        }

        return ProcessSample(
            processes: processes,
            systemCPUPercent: systemCPUPercent,
            systemMemory: SystemMetricsReader.memory()
        )
    }
}

struct WorkingDirectoryResult: Sendable {
    let generation: UInt64
    let identity: ProcessIdentity
    let workingDirectory: String?
}

actor WorkingDirectoryResolver {
    typealias ResultHandler = @Sendable (WorkingDirectoryResult) async -> Void
    typealias Runner = @Sendable (Int32, Duration) async -> String?

    struct Policy: Sendable {
        let maximumConcurrentLookups: Int
        let lookupBudgetPerGeneration: Int
        let lookupDeadline: Duration
        let cacheCapacity: Int
        let positiveTTL: Duration
        let negativeTTL: Duration

        static let standard = Policy(
            maximumConcurrentLookups: 2,
            lookupBudgetPerGeneration: 8,
            lookupDeadline: .milliseconds(1_500),
            cacheCapacity: 512,
            positiveTTL: .seconds(60),
            negativeTTL: .seconds(15)
        )
    }

    private struct CacheEntry {
        let directory: String?
        let resolvedAt: ContinuousClock.Instant
        var lastAccess: UInt64
    }

    private struct Request {
        let identity: ProcessIdentity
        var waiters: [(generation: UInt64, handler: ResultHandler)]
    }

    private let now: @Sendable () -> ContinuousClock.Instant
    private let runner: Runner
    private let policy: Policy
    private let maximumQueuedLookups = 16
    private let maximumWaitersPerLookup = 64

    private var cache: [ProcessIdentity: CacheEntry] = [:]
    private var accessCounter: UInt64 = 0
    private var queued: [Request] = []
    private var active: [ProcessIdentity: Task<Void, Never>] = [:]
    private var generationLookupCounts: [UInt64: Int] = [:]

    init(
        policy: Policy = .standard,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now },
        runner: @escaping Runner = WorkingDirectoryResolver.defaultLookup
    ) {
        self.policy = policy
        self.now = now
        self.runner = runner
    }

    func resolve(
        _ snapshots: [ProcessSnapshot],
        generation: UInt64,
        onResult: @escaping ResultHandler
    ) {
        let now = now()
        var seen: Set<ProcessIdentity> = []
        generationLookupCounts = generationLookupCounts.filter {
            $0.key >= generation || generation - $0.key < 64
        }

        for snapshot in snapshots where snapshot.kind == .agent {
            let identity = snapshot.identity
            guard seen.insert(identity).inserted else { continue }

            if let directory = cachedDirectory(for: identity, at: now) {
                deliver(directory, identity: identity, generation: generation, to: onResult)
                continue
            }

            if appendWaiterIfInFlight(
                identity: identity,
                generation: generation,
                handler: onResult
            ) {
                continue
            }

            let lookupCount = generationLookupCounts[generation, default: 0]
            guard lookupCount < policy.lookupBudgetPerGeneration,
                  queued.count < maximumQueuedLookups
            else {
                continue
            }
            generationLookupCounts[generation] = lookupCount + 1
            queued.append(
                Request(
                    identity: identity,
                    waiters: [(generation: generation, handler: onResult)]
                )
            )
        }

        startQueuedLookups()
    }

    func cancel(generation: UInt64) {
        generationLookupCounts[generation] = nil
        queued = queued.compactMap { request in
            var request = request
            request.waiters.removeAll { $0.generation == generation }
            return request.waiters.isEmpty ? nil : request
        }

        for identity in Array(active.keys) {
            guard var request = activeRequest(for: identity) else { continue }
            request.waiters.removeAll { $0.generation == generation }
            setActiveRequest(request, for: identity)
            if request.waiters.isEmpty {
                active[identity]?.cancel()
            }
        }
    }

    private var activeRequests: [ProcessIdentity: Request] = [:]

    private func activeRequest(for identity: ProcessIdentity) -> Request? {
        activeRequests[identity]
    }

    private func setActiveRequest(_ request: Request, for identity: ProcessIdentity) {
        activeRequests[identity] = request
    }

    private func appendWaiterIfInFlight(
        identity: ProcessIdentity,
        generation: UInt64,
        handler: @escaping ResultHandler
    ) -> Bool {
        if let index = queued.firstIndex(where: { $0.identity == identity }) {
            if queued[index].waiters.count < maximumWaitersPerLookup {
                queued[index].waiters.append((generation, handler))
            }
            return true
        }
        if var request = activeRequests[identity] {
            if request.waiters.count < maximumWaitersPerLookup {
                request.waiters.append((generation, handler))
            }
            activeRequests[identity] = request
            return true
        }
        return false
    }

    private func startQueuedLookups() {
        while active.count < policy.maximumConcurrentLookups, !queued.isEmpty {
            let request = queued.removeFirst()
            let identity = request.identity
            activeRequests[identity] = request
            active[identity] = Task { [weak self] in
                guard let self else { return }
                let directory = await self.runner(identity.pid, self.policy.lookupDeadline)
                await self.lookupFinished(identity: identity, directory: directory)
            }
        }
    }

    private func lookupFinished(identity: ProcessIdentity, directory: String?) {
        let taskWasCancelled = active[identity]?.isCancelled == true
        active[identity] = nil
        let request = activeRequests.removeValue(forKey: identity)

        if !taskWasCancelled {
            store(directory, for: identity)
            if let request {
                for waiter in request.waiters {
                    deliver(
                        directory,
                        identity: identity,
                        generation: waiter.generation,
                        to: waiter.handler
                    )
                }
            }
        }
        startQueuedLookups()
    }

    private func cachedDirectory(
        for identity: ProcessIdentity,
        at now: ContinuousClock.Instant
    ) -> String?? {
        guard var entry = cache[identity] else { return nil }
        let ttl = entry.directory == nil ? policy.negativeTTL : policy.positiveTTL
        guard now - entry.resolvedAt < ttl else {
            cache[identity] = nil
            return nil
        }
        accessCounter &+= 1
        entry.lastAccess = accessCounter
        cache[identity] = entry
        return .some(entry.directory)
    }

    private func store(_ directory: String?, for identity: ProcessIdentity) {
        accessCounter &+= 1
        cache[identity] = CacheEntry(
            directory: directory,
            resolvedAt: now(),
            lastAccess: accessCounter
        )
        if cache.count > policy.cacheCapacity,
           let oldest = cache.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
            cache[oldest] = nil
        }
    }

    private func deliver(
        _ directory: String?,
        identity: ProcessIdentity,
        generation: UInt64,
        to handler: @escaping ResultHandler
    ) {
        Task {
            await handler(
                WorkingDirectoryResult(
                    generation: generation,
                    identity: identity,
                    workingDirectory: directory
                )
            )
        }
    }

    private static func defaultLookup(pid: Int32, deadline: Duration) async -> String? {
        do {
            let output = try await CommandRunner.run(
                "/usr/sbin/lsof",
                arguments: ["-a", "-p", String(pid), "-d", "cwd", "-Fn"],
                deadline: deadline
            )
            return output
                .split(whereSeparator: \Character.isNewline)
                .first(where: { $0.hasPrefix("n/") })
                .map { String($0.dropFirst()) }
        } catch {
            return nil
        }
    }
}
