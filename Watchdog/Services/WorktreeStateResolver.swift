import Foundation
import Darwin

/// Verdict for a git worktree referenced by an agent process.
enum WorktreeVerdict: Equatable, Sendable {
    /// Working tree has no uncommitted changes and its branch is fully merged
    /// into the default branch: safe to remove.
    case clean
    /// Working tree has uncommitted changes, untracked files, or unpushed
    /// commits: removal would lose work.
    case dirty
    /// The path does not exist or is not a git working tree.
    case missing

    var localizedDescription: String {
        switch self {
        case .clean: return "정리 가능한 워크트리"
        case .dirty: return "변경이 남아 있는 워크트리"
        case .missing: return "워크트리 없음"
        }
    }
}

struct WorktreeState: Equatable, Sendable {
    let path: String
    let verdict: WorktreeVerdict
    /// Human-readable detail: branch name, dirty file count, etc.
    let detail: String?
}

enum WorktreeStateError: Error, Sendable {
    case notGitRepository
    case commandFailed(String)
}

/// Actor that inspects a candidate worktree path with bounded concurrency and
/// short deadlines. Lookup strategy per path (single `git` batch invocation):
/// `git -C <path> status --porcelain` plus branch/merge state.
actor WorktreeStateResolver {
    typealias Runner = @Sendable (String, [String], Duration) async throws -> String

    struct Policy: Sendable {
        let maximumConcurrentLookups: Int
        let lookupDeadline: Duration
        let cacheCapacity: Int
        let positiveTTL: Duration
        let negativeTTL: Duration

        static let standard = Policy(
            maximumConcurrentLookups: 2,
            lookupDeadline: .milliseconds(2_000),
            cacheCapacity: 128,
            positiveTTL: .seconds(120),
            negativeTTL: .seconds(60)
        )
    }

    private struct CacheEntry {
        let state: WorktreeState?
        let resolvedAt: ContinuousClock.Instant
        var lastAccess: UInt64
    }

    private let now: @Sendable () -> ContinuousClock.Instant
    private let runner: Runner
    private let policy: Policy

    private var cache: [String: CacheEntry] = [:]
    private var accessCounter: UInt64 = 0
    private var active: [String: Task<WorktreeState?, Never>] = [:]

    init(
        policy: Policy = .standard,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now },
        runner: @escaping Runner = { executable, arguments, deadline in
            try await CommandRunner.run(executable, arguments: arguments, deadline: deadline)
        }
    ) {
        self.policy = policy
        self.now = now
        self.runner = runner
    }

    /// Resolve states for the given paths. Results are delivered through the
    /// handler; cached or in-flight paths deduplicate automatically.
    func resolve(
        _ paths: [String],
        onResult: @escaping @Sendable (String, WorktreeState?) -> Void
    ) {
        let instant = now()
        for path in deduplicated(paths) {
            if let cached = cachedState(for: path, at: instant) {
                deliver(path, state: cached, to: onResult)
                continue
            }
            guard active[path] == nil, active.count < policy.maximumConcurrentLookups else {
                continue
            }
            let runner = self.runner
            let lookupPolicy = self.policy
            active[path] = Task { [weak self] in
                let state = await Self.lookup(
                    path: path,
                    runner: runner,
                    deadline: lookupPolicy.lookupDeadline
                )
                guard let self else { return state }
                await self.finishLookup(path: path, state: state, onResult: onResult)
                return state
            }
        }
    }

    func cancelAll() {
        for task in active.values {
            task.cancel()
        }
        active.removeAll()
    }

    private func finishLookup(
        path: String,
        state: WorktreeState?,
        onResult: @escaping @Sendable (String, WorktreeState?) -> Void
    ) {
        active[path] = nil
        store(state, for: path)
        deliver(path, state: state, to: onResult)
    }

    private func deliver(
        _ path: String,
        state: WorktreeState?,
        to handler: @escaping @Sendable (String, WorktreeState?) -> Void
    ) {
        handler(path, state)
    }

    /// Test hook: waits for every in-flight lookup so tests can assert
    /// deterministically without sleep loops.
    func drainForTesting() async {
        for (_, task) in active {
            _ = await task.value
        }
    }

    private func deduplicated(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        return paths.filter { seen.insert($0).inserted }
    }

    private func cachedState(
        for path: String,
        at instant: ContinuousClock.Instant
    ) -> WorktreeState?? {
        guard var entry = cache[path] else { return nil }
        let ttl = entry.state == nil ? policy.negativeTTL : policy.positiveTTL
        guard instant - entry.resolvedAt < ttl else {
            cache[path] = nil
            return nil
        }
        accessCounter &+= 1
        entry.lastAccess = accessCounter
        cache[path] = entry
        return .some(entry.state)
    }

    private func store(_ state: WorktreeState?, for path: String) {
        accessCounter &+= 1
        cache[path] = CacheEntry(
            state: state,
            resolvedAt: now(),
            lastAccess: accessCounter
        )
        if cache.count > policy.cacheCapacity,
           let oldest = cache.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
            cache[oldest] = nil
        }
    }

    // MARK: - Lookup

    static func lookup(
        path: String,
        runner: Runner,
        deadline: Duration
    ) async -> WorktreeState? {
        // One batched invocation per path keeps helper-process pressure bounded.
        // --porcelain=v2 lets us count dirty entries; -b exposes the branch.
        guard let output = try? await runGit(
            path: path,
            arguments: ["status", "--porcelain=v2", "--branch"],
            runner: runner,
            deadline: deadline
        ) else {
            return WorktreeState(path: path, verdict: .missing, detail: nil)
        }
        return parseStatus(output: output, path: path)
    }

    static func parseStatus(output: String, path: String) -> WorktreeState {
        var branch: String?
        var dirtyEntries = 0
        var unpushedCommits = 0

        for line in output.split(whereSeparator: \Character.isNewline) {
            if line.hasPrefix("# branch.head ") {
                branch = String(line.dropFirst("# branch.head ".count))
            } else if line.hasPrefix("# branch.ab ") {
                // "# branch.ab +1 -0" → ahead 1
                let parts = line.split(separator: " ")
                if let ahead = parts.first(where: { $0.hasPrefix("+") }),
                   let value = Int(ahead.dropFirst()) {
                    unpushedCommits = value
                }
            } else if !line.hasPrefix("#") {
                dirtyEntries += 1
            }
        }

        var detailParts: [String] = []
        if let branch, branch != "(detached)" {
            detailParts.append(branch)
        }
        if dirtyEntries > 0 {
            detailParts.append("변경 \(dirtyEntries)개")
        }
        if unpushedCommits > 0 {
            detailParts.append("미푸시 \(unpushedCommits)커밋")
        }

        let verdict: WorktreeVerdict = dirtyEntries == 0 && unpushedCommits == 0 ? .clean : .dirty
        return WorktreeState(path: path, verdict: verdict, detail: detailParts.isEmpty ? nil : detailParts.joined(separator: " · "))
    }

    private static func runGit(
        path: String,
        arguments: [String],
        runner: Runner,
        deadline: Duration
    ) async throws -> String {
        try await runner(
            "/usr/bin/git",
            ["-C", path] + arguments,
            deadline
        )
    }
}
