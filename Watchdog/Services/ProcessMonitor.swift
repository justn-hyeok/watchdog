import AppKit
import Combine
import Foundation
import UserNotifications

enum ProcessScope: String, CaseIterable, Identifiable {
    case attention = "주의 필요"
    case agents = "에이전트"
    case all = "전체"

    var id: String { rawValue }
}

struct ActionFeedback: Identifiable, Equatable {
    enum Kind {
        case success
        case error
    }

    let id = UUID()
    let kind: Kind
    let message: String
}

struct DestructiveActionConfirmationRequest: Sendable {
    fileprivate let id: UUID
    fileprivate let action: ProcessControlAction
    fileprivate let identity: ProcessIdentity
    fileprivate let requestedAt: ContinuousClock.Instant
}

enum ProcessActionOutcome: Equatable, Sendable {
    case signalDelivered
    case awaitingExit
    case exited
    case stillRunning
    case identityChanged
    case verificationFailed
    case failed(String)
}

private struct NotificationCooldownKey: Hashable {
    let identity: ProcessIdentity
    let reason: AlertReason
}

@MainActor
final class ProcessMonitor: ObservableObject {
    @Published private(set) var processes: [ProcessSnapshot] = []
    @Published private(set) var hotProcesses: Set<ProcessIdentity> = []
    @Published private(set) var highMemoryProcesses: Set<ProcessIdentity> = []
    @Published private(set) var systemCPUPercent: Double = 0
    @Published private(set) var systemMemory: SystemMemorySnapshot?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var samplingError: String?
    @Published private(set) var actionFeedback: ActionFeedback?
    @Published private(set) var actionOutcomes: [ProcessIdentity: ProcessActionOutcome] = [:]
    @Published private(set) var notificationAuthorization: UNAuthorizationStatus = .notDetermined
    @Published private(set) var isRefreshing = false
    @Published var threshold: Double {
        didSet {
            let canonical = Self.normalizedCPU(threshold)
            if threshold != canonical { threshold = canonical }
            defaults.set(canonical, forKey: Keys.threshold)
        }
    }
    @Published var sustainedDuration: Double {
        didSet {
            let canonical = Self.normalizedDuration(sustainedDuration)
            if sustainedDuration != canonical { sustainedDuration = canonical }
            defaults.set(canonical, forKey: Keys.sustainedDuration)
        }
    }
    @Published var memoryThresholdGB: Double {
        didSet {
            let canonical = Self.normalizedMemory(memoryThresholdGB)
            if memoryThresholdGB != canonical { memoryThresholdGB = canonical }
            defaults.set(canonical, forKey: Keys.memoryThresholdGB)
        }
    }
    @Published var notificationsEnabled: Bool {
        didSet {
            defaults.set(notificationsEnabled, forKey: Keys.notificationsEnabled)
            if notificationsEnabled { requestNotificationPermission() }
        }
    }

    private let defaults: UserDefaults
    private let sampler = ProcessSampler()
    private let workingDirectoryResolver = WorkingDirectoryResolver()
    private let authorization: ProcessActionAuthorizationActor
    private let controller: ProcessController
    private let clock = ContinuousClock()
    private var tracker = HotProcessTracker()
    private var memoryTracker = MemoryProcessTracker()
    private var ignoredProcesses: Set<ProcessIdentity> = []
    private var ignoredAlertStates: [ProcessIdentity: (hot: Bool, highMemory: Bool)] = [:]
    private var refreshTask: Task<Void, Never>?
    private var observation: ObservationToken?
    private var generation: UInt64 = 0
    private var notificationCooldowns: [NotificationCooldownKey: ContinuousClock.Instant] = [:]
    private var actionOutcomeRecordedAt: [ProcessIdentity: ContinuousClock.Instant] = [:]
    private var pendingConfirmations: [UUID: ContinuousClock.Instant] = [:]
    private var ignorePruneCursor = 0
    private var terminationPollTasks: [ProcessIdentity: (id: UUID, task: Task<Void, Never>)] = [:]

    init(
        defaults: UserDefaults = .standard,
        authorization: ProcessActionAuthorizationActor = ProcessActionAuthorizationActor(),
        controller: ProcessController = ProcessController()
    ) {
        self.defaults = defaults
        self.authorization = authorization
        self.controller = controller
        threshold = Self.normalizedCPU(defaults.object(forKey: Keys.threshold) as? Double ?? 100)
        sustainedDuration = Self.normalizedDuration(defaults.object(forKey: Keys.sustainedDuration) as? Double ?? 20)
        memoryThresholdGB = Self.normalizedMemory(defaults.object(forKey: Keys.memoryThresholdGB) as? Double ?? 2)
        notificationsEnabled = defaults.object(forKey: Keys.notificationsEnabled) as? Bool ?? true
        defaults.set(threshold, forKey: Keys.threshold)
        defaults.set(sustainedDuration, forKey: Keys.sustainedDuration)
        defaults.set(memoryThresholdGB, forKey: Keys.memoryThresholdGB)
    }

    var alertCount: Int {
        let orphaned = Set(processes.filter { $0.suspectedOrphan && !ignoredProcesses.contains($0.identity) }.map(\.identity))
        return hotProcesses.union(highMemoryProcesses).union(orphaned).count
    }

    func start() {
        guard refreshTask == nil else { return }
        requestNotificationPermission()

        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let sample = try await sampler.sample()
            let increment = generation.addingReportingOverflow(1)
            guard !increment.overflow else {
                throw ProcessControlError.staleObservation
            }
            let nextGeneration = increment.partialValue
            generation = nextGeneration
            let token = ObservationToken(generation: nextGeneration, instant: clock.now)
            observation = token
            let snapshots = OrphanClassifier.classify(sample.processes)

            let liveIdentities = Set(snapshots.map(\.identity))
            pruneNotificationCooldowns(liveIdentities: liveIdentities, at: token.instant)
            pruneActionOutcomes(at: token.instant)
            pruneIgnoredProcesses(liveIdentities: liveIdentities)

            let previousHotProcesses = hotProcesses
            let previousHighMemoryProcesses = highMemoryProcesses
            let nextHotProcesses = tracker.update(
                snapshots: snapshots,
                threshold: threshold,
                sustainedFor: sustainedDuration,
                ignoredProcesses: ignoredProcesses,
                at: token.instant
            )
            let nextHighMemoryProcesses = memoryTracker.update(
                snapshots: snapshots,
                thresholdBytes: UInt64(memoryThresholdGB * 1_024 * 1_024 * 1_024),
                sustainedFor: sustainedDuration,
                ignoredProcesses: ignoredProcesses,
                at: token.instant
            )

            processes = snapshots.sorted {
                if $0.suspectedOrphan != $1.suspectedOrphan {
                    return $0.suspectedOrphan
                }
                return $0.cpuPercent > $1.cpuPercent
            }
            hotProcesses = nextHotProcesses
            highMemoryProcesses = nextHighMemoryProcesses
            if let systemCPUPercent = sample.systemCPUPercent {
                self.systemCPUPercent = systemCPUPercent
            }
            systemMemory = sample.systemMemory
            lastUpdated = Date()
            samplingError = nil
            await workingDirectoryResolver.resolve(
                snapshots,
                generation: token.generation
            ) { [weak self] result in
                await self?.mergeWorkingDirectory(result)
            }

            let newHotProcesses = nextHotProcesses.subtracting(previousHotProcesses)
            if notificationsEnabled, !newHotProcesses.isEmpty {
                sendCPUNotifications(
                    for: snapshots.filter { newHotProcesses.contains($0.identity) },
                    at: token.instant
                )
            }

            let newHighMemoryProcesses = nextHighMemoryProcesses.subtracting(previousHighMemoryProcesses)
            if notificationsEnabled, !newHighMemoryProcesses.isEmpty {
                sendMemoryNotifications(
                    for: snapshots.filter { newHighMemoryProcesses.contains($0.identity) },
                    at: token.instant
                )
            }
        } catch {
            samplingError = error.localizedDescription
            observation = nil
            tracker.reset()
            memoryTracker.reset()
            hotProcesses.removeAll()
            highMemoryProcesses.removeAll()
            await authorization.invalidateAll()
            pendingConfirmations.removeAll(keepingCapacity: true)
            await workingDirectoryResolver.cancel(generation: generation)
        }
    }

    func visibleProcesses(scope: ProcessScope, search: String) -> [ProcessSnapshot] {
        let scoped: [ProcessSnapshot]

        switch scope {
        case .attention:
            scoped = processes.filter {
                !ignoredProcesses.contains($0.identity)
                    && (hotProcesses.contains($0.identity)
                    || highMemoryProcesses.contains($0.identity)
                    || $0.suspectedOrphan)
            }
        case .agents:
            scoped = processes.filter { $0.kind == .agent }
        case .all:
            scoped = processes
        }

        let filtered: [ProcessSnapshot]
        if search.isEmpty {
            filtered = scoped
        } else {
            let query = search.lowercased()
            filtered = scoped.filter {
                $0.displayName.lowercased().contains(query)
                    || $0.executablePath.lowercased().contains(query)
                    || ($0.workingDirectory?.lowercased().contains(query) ?? false)
                    || String($0.id).contains(query)
            }
        }

        return scope == .all ? Array(filtered.prefix(60)) : filtered
    }

    func isHot(_ process: ProcessSnapshot) -> Bool {
        hotProcesses.contains(process.identity)
    }

    func isHighMemory(_ process: ProcessSnapshot) -> Bool {
        highMemoryProcesses.contains(process.identity)
    }

    func isIgnored(_ process: ProcessSnapshot) -> Bool {
        ignoredProcesses.contains(process.identity)
    }

    func alertReasons(for process: ProcessSnapshot) -> [AlertReason] {
        guard !isIgnored(process) else { return [] }
        var reasons: [AlertReason] = []
        if isHot(process) {
            reasons.append(.sustainedCPU(percent: threshold))
        }
        if isHighMemory(process) {
            reasons.append(.sustainedMemory(bytes: UInt64(memoryThresholdGB * 1_024 * 1_024 * 1_024)))
        }
        if let orphanReason = process.orphanReason {
            reasons.append(.orphan(orphanReason))
        }
        return reasons
    }

    func actionability(of process: ProcessSnapshot) -> ProcessActionability {
        let freshness: ObservationFreshness
        if let observation {
            freshness = observation.instant.duration(to: clock.now) < .seconds(5) ? .current : .stale
        } else {
            freshness = .unavailable
        }
        return ProcessActionability(
            identity: process.identity,
            observation: observation,
            freshness: freshness,
            isIgnored: isIgnored(process),
            isProtected: process.isProtected
        )
    }

    func suspend(_ process: ProcessSnapshot) {
        performImmediate(.suspend, process: process, success: "일시 정지: \(process.displayName)")
    }

    func resume(_ process: ProcessSnapshot) {
        performImmediate(.resume, process: process, success: "재개: \(process.displayName)")
    }

    func destructiveActionRequest(
        _ action: ProcessControlAction,
        for process: ProcessSnapshot
    ) throws -> DestructiveActionConfirmationRequest {
        guard action.isDestructive,
              observation != nil,
              actionability(of: process).canAct,
              processes.contains(where: { $0.identity == process.identity })
        else {
            throw ProcessControlError.staleObservation
        }
        let requestedAt = clock.now
        pendingConfirmations = pendingConfirmations.filter {
            requestedAt < $0.value.advanced(by: .seconds(30))
        }
        guard pendingConfirmations.count < 256 else {
            throw ProcessControlError.authorizationCapacityReached
        }
        let request = DestructiveActionConfirmationRequest(
            id: UUID(),
            action: action,
            identity: process.identity,
            requestedAt: requestedAt
        )
        pendingConfirmations[request.id] = requestedAt
        return request
    }

    func completeDestructiveConfirmation(
        _ request: DestructiveActionConfirmationRequest
    ) async throws {
        guard pendingConfirmations.removeValue(forKey: request.id) == request.requestedAt,
              request.action.isDestructive,
              let observation,
              clock.now < request.requestedAt.advanced(by: .seconds(30)),
              processes.contains(where: { $0.identity == request.identity }),
              let process = processes.first(where: { $0.identity == request.identity }),
              actionability(of: process).canAct
        else {
            throw ProcessControlError.staleObservation
        }
        let nonce = try await authorization.mint(
            action: request.action,
            identity: request.identity,
            observation: observation,
            at: clock.now
        )
        try await consumeAction(nonce, action: request.action, process: process)
    }

    func ignoreUntilExit(_ process: ProcessSnapshot) {
        guard ignoredProcesses.contains(process.identity) || ignoredProcesses.count < 512 else {
            showFeedback(.init(kind: .error, message: "무시 목록이 가득 찼습니다"))
            return
        }
        ignoredAlertStates[process.identity] = (
            hot: hotProcesses.contains(process.identity),
            highMemory: highMemoryProcesses.contains(process.identity)
        )
        ignoredProcesses.insert(process.identity)
        hotProcesses.remove(process.identity)
        highMemoryProcesses.remove(process.identity)
        showFeedback(.init(kind: .success, message: "이 프로세스는 종료할 때까지 무시합니다"))
    }

    func undoIgnore(_ process: ProcessSnapshot) {
        guard ignoredProcesses.remove(process.identity) != nil else { return }
        if let state = ignoredAlertStates.removeValue(forKey: process.identity) {
            if state.hot { hotProcesses.insert(process.identity) }
            if state.highMemory { highMemoryProcesses.insert(process.identity) }
        }
        showFeedback(.init(kind: .success, message: "이 프로세스를 다시 감시합니다"))
    }

#if DEBUG
    func loadStalePreview(
        processes: [ProcessSnapshot],
        hotProcesses: Set<ProcessIdentity>,
        highMemoryProcesses: Set<ProcessIdentity> = [],
        updatedAt: Date
    ) {
        generation &+= 1
        observation = ObservationToken(
            generation: generation,
            instant: clock.now.advanced(by: .seconds(-6))
        )
        loadPreview(
            processes: processes,
            hotProcesses: hotProcesses,
            highMemoryProcesses: highMemoryProcesses,
            updatedAt: updatedAt
        )
    }

    func loadActionablePreview(
        processes: [ProcessSnapshot],
        hotProcesses: Set<ProcessIdentity>,
        highMemoryProcesses: Set<ProcessIdentity> = [],
        updatedAt: Date
    ) {
        generation &+= 1
        observation = ObservationToken(generation: generation, instant: clock.now)
        loadPreview(
            processes: processes,
            hotProcesses: hotProcesses,
            highMemoryProcesses: highMemoryProcesses,
            updatedAt: updatedAt
        )
    }

    func loadPreview(
        processes: [ProcessSnapshot],
        hotProcesses: Set<ProcessIdentity>,
        highMemoryProcesses: Set<ProcessIdentity> = [],
        updatedAt: Date
    ) {
        self.processes = processes
        self.hotProcesses = hotProcesses
        self.highMemoryProcesses = highMemoryProcesses
        systemCPUPercent = 37
        systemMemory = SystemMemorySnapshot(
            totalBytes: 48 * 1_024 * 1_024 * 1_024,
            usedBytes: 44 * 1_024 * 1_024 * 1_024,
            compressedBytes: 6 * 1_024 * 1_024 * 1_024,
            swapUsedBytes: 12 * 1_024 * 1_024 * 1_024,
            swapTotalBytes: 16 * 1_024 * 1_024 * 1_024,
            pressureLevel: .normal
        )
        lastUpdated = updatedAt
        samplingError = nil
    }

    var previewGeneration: UInt64 { generation }

    func mergeWorkingDirectoryPreview(_ result: WorkingDirectoryResult) {
        mergeWorkingDirectory(result)
    }

    func setActionOutcomePreview(_ outcome: ProcessActionOutcome, for process: ProcessSnapshot) {
        recordActionOutcome(outcome, for: process.identity)
    }

    func pruneActionOutcomesPreview(at instant: ContinuousClock.Instant) {
        pruneActionOutcomes(at: instant)
    }

    func reserveNotificationPreview(
        identity: ProcessIdentity,
        reason: AlertReason,
        at instant: ContinuousClock.Instant
    ) -> Bool {
        reserveNotification(identity: identity, reason: reason, at: instant)
    }

    var notificationCooldownCountPreview: Int { notificationCooldowns.count }
    var terminationPollCountPreview: Int { terminationPollTasks.count }

    func startTerminationPollPreview(for identity: ProcessIdentity) {
        pollTerminationOutcome(for: identity)
    }
#endif

    private func requestImmediateAction(
        _ action: ProcessControlAction,
        for process: ProcessSnapshot
    ) async throws -> ProcessActionNonce {
        guard !action.isDestructive else { throw ProcessControlError.authorizationInvalid }
        let state = actionability(of: process)
        guard state.canAct,
              let observation = state.observation,
              processes.contains(where: { $0.identity == process.identity })
        else {
            throw ProcessControlError.staleObservation
        }
        return try await authorization.mint(
            action: action,
            identity: process.identity,
            observation: observation,
            at: clock.now
        )
    }

    func consumeAction(
        _ nonce: ProcessActionNonce,
        action: ProcessControlAction,
        process: ProcessSnapshot
    ) async throws {
        guard let observation,
              actionability(of: process).canAct,
              processes.contains(where: { $0.identity == process.identity })
        else {
            throw ProcessControlError.staleObservation
        }
        let instant = clock.now
        let authorized = try await authorization.consume(
            nonce,
            action: action,
            identity: process.identity,
            currentGeneration: observation.generation,
            at: instant
        )
        guard let currentObservation = self.observation,
              currentObservation.generation == authorized.observationGeneration,
              actionability(of: process).canAct,
              processes.contains(where: { $0.identity == process.identity })
        else {
            throw ProcessControlError.staleObservation
        }
        try controller.execute(
            authorized,
            currentGeneration: currentObservation.generation
        )
        recordActionOutcome(.signalDelivered, for: process.identity)

        if action.isDestructive {
            recordActionOutcome(.awaitingExit, for: process.identity)
            pollTerminationOutcome(for: process.identity)
        }
    }

    private func performImmediate(
        _ action: ProcessControlAction,
        process: ProcessSnapshot,
        success message: String
    ) {
        Task {
            do {
                let nonce = try await requestImmediateAction(action, for: process)
                try await consumeAction(nonce, action: action, process: process)
                showFeedback(.init(kind: .success, message: message))
            } catch {
                recordActionOutcome(.failed(error.localizedDescription), for: process.identity)
                showFeedback(.init(kind: .error, message: error.localizedDescription))
            }
        }
    }

    private func mergeWorkingDirectory(_ result: WorkingDirectoryResult) {
        guard observation?.generation == result.generation,
              let index = processes.firstIndex(where: { $0.identity == result.identity })
        else {
            return
        }
        processes[index].workingDirectory = result.workingDirectory
    }

    private func pruneIgnoredProcesses(liveIdentities: Set<ProcessIdentity>) {
        let candidates = ignoredProcesses
            .filter { !liveIdentities.contains($0) }
            .sorted {
                if $0.pid != $1.pid { return $0.pid < $1.pid }
                if $0.startTimeMicroseconds != $1.startTimeMicroseconds {
                    return $0.startTimeMicroseconds < $1.startTimeMicroseconds
                }
                return $0.userID < $1.userID
            }
        guard !candidates.isEmpty else {
            ignorePruneCursor = 0
            return
        }

        let count = min(16, candidates.count)
        let start = ignorePruneCursor % candidates.count
        for offset in 0..<count {
            let identity = candidates[(start + offset) % candidates.count]
            switch controller.lookup(pid: identity.pid) {
            case .absent:
                ignoredProcesses.remove(identity)
                ignoredAlertStates[identity] = nil
            case let .found(facts) where facts.identity != identity:
                ignoredProcesses.remove(identity)
                ignoredAlertStates[identity] = nil
            case .found, .failed:
                break
            }
        }
        ignorePruneCursor = (start + count) % candidates.count
    }

    private func pollTerminationOutcome(for identity: ProcessIdentity) {
        terminationPollTasks[identity]?.task.cancel()
        let pollID = UUID()
        let controller = controller
        let task = Task { [weak self] in
            defer { self?.finishTerminationPoll(identity: identity, id: pollID) }
            for attempt in 0..<20 {
                do {
                    try await Task.sleep(for: .milliseconds(500))
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                let lookup = await Task.detached(priority: .utility) {
                    controller.lookup(pid: identity.pid)
                }.value
                guard !Task.isCancelled else { return }
                if let outcome = Self.terminationOutcome(for: lookup, identity: identity) {
                    self.recordActionOutcome(outcome, for: identity)
                    return
                }
                if attempt == 19 {
                    self.recordActionOutcome(.stillRunning, for: identity)
                }
            }
        }
        terminationPollTasks[identity] = (pollID, task)
    }

    static func terminationOutcome(
        for lookup: LiveProcessLookup,
        identity: ProcessIdentity
    ) -> ProcessActionOutcome? {
        switch lookup {
        case .absent: return .exited
        case let .found(facts) where facts.identity != identity: return .identityChanged
        case .failed: return .verificationFailed
        case .found: return nil
        }
    }

    private func finishTerminationPoll(identity: ProcessIdentity, id: UUID) {
        guard terminationPollTasks[identity]?.id == id else { return }
        terminationPollTasks[identity] = nil
    }

    private func recordActionOutcome(
        _ outcome: ProcessActionOutcome,
        for identity: ProcessIdentity
    ) {
        let recordedAt = clock.now
        actionOutcomes[identity] = outcome
        actionOutcomeRecordedAt[identity] = recordedAt
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard self?.actionOutcomeRecordedAt[identity] == recordedAt else { return }
            self?.actionOutcomeRecordedAt[identity] = nil
            self?.actionOutcomes[identity] = nil
        }
    }

    private func pruneActionOutcomes(at instant: ContinuousClock.Instant) {
        let retained = actionOutcomeRecordedAt.filter {
            $0.value.duration(to: instant) < .seconds(30)
        }
        actionOutcomeRecordedAt = retained
        actionOutcomes = actionOutcomes.filter { retained[$0.key] != nil }
    }

    private func showFeedback(_ feedback: ActionFeedback) {
        actionFeedback = feedback
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard self?.actionFeedback?.id == feedback.id else { return }
            self?.actionFeedback = nil
        }
    }

    private func requestNotificationPermission() {
        let shouldRequestAuthorization = notificationsEnabled
        Task {
            let center = UNUserNotificationCenter.current()
            if shouldRequestAuthorization {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            }
            center.getNotificationSettings { [weak self] settings in
                let authorizationStatus = settings.authorizationStatus
                Task { @MainActor [weak self] in
                    self?.notificationAuthorization = authorizationStatus
                }
            }
        }
    }

    private func sendCPUNotifications(
        for snapshots: [ProcessSnapshot],
        at instant: ContinuousClock.Instant
    ) {
        for snapshot in snapshots.prefix(3) {
            let reason = AlertReason.sustainedCPU(percent: threshold)
            guard reserveNotification(identity: snapshot.identity, reason: reason, at: instant) else {
                continue
            }
            let content = UNMutableNotificationContent()
            content.title = "\(snapshot.displayName)의 CPU 사용량이 높습니다"
            content.body = "PID \(snapshot.id) · CPU \(Int(threshold))%를 계속 초과하고 있습니다"
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "watchdog-hot-\(snapshot.id)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }
    }

    private func sendMemoryNotifications(
        for snapshots: [ProcessSnapshot],
        at instant: ContinuousClock.Instant
    ) {
        for snapshot in snapshots.prefix(3) {
            let reason = AlertReason.sustainedMemory(
                bytes: UInt64(memoryThresholdGB * 1_024 * 1_024 * 1_024)
            )
            guard reserveNotification(identity: snapshot.identity, reason: reason, at: instant) else {
                continue
            }
            let content = UNMutableNotificationContent()
            content.title = "\(snapshot.displayName)의 메모리 사용량이 높습니다"
            let current = WatchdogFormatters.memory.string(fromByteCount: Int64(snapshot.residentBytes))
            content.body = "PID \(snapshot.id) · 현재 \(current) · 제한 \(memoryThresholdGB.formatted(.number.precision(.fractionLength(1))))GB"
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "watchdog-memory-\(snapshot.id)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }
    }

    private func reserveNotification(
        identity: ProcessIdentity,
        reason: AlertReason,
        at instant: ContinuousClock.Instant
    ) -> Bool {
        let key = NotificationCooldownKey(identity: identity, reason: reason)
        if let sentAt = notificationCooldowns[key],
           sentAt.duration(to: instant) < .seconds(600) {
            return false
        }
        guard notificationCooldowns[key] != nil || notificationCooldowns.count < 512 else {
            return false
        }
        notificationCooldowns[key] = instant
        return true
    }

    private func pruneNotificationCooldowns(
        liveIdentities: Set<ProcessIdentity>,
        at instant: ContinuousClock.Instant
    ) {
        notificationCooldowns = notificationCooldowns.filter { key, sentAt in
            liveIdentities.contains(key.identity)
                && sentAt.duration(to: instant) < .seconds(600)
        }
    }

    private enum Keys {
        static let threshold = "threshold"
        static let sustainedDuration = "sustainedDuration"
        static let memoryThresholdGB = "memoryThresholdGB"
        static let notificationsEnabled = "notificationsEnabled"
    }

    private static func normalizedCPU(_ value: Double) -> Double {
        guard value.isFinite else { return 100 }
        return min(max(value, 1), 1_000)
    }

    private static func normalizedDuration(_ value: Double) -> Double {
        guard value.isFinite else { return 20 }
        return min(max(value, 2), 300)
    }

    private static func normalizedMemory(_ value: Double) -> Double {
        guard value.isFinite else { return 2 }
        return min(max(value, 0.1), 1_024)
    }
}
