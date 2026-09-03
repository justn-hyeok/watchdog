import Foundation
import XCTest
@testable import Watchdog

final class WorktreeStateResolverTests: XCTestCase {
    func testParseStatusCleanWorktree() {
        let output = """
        # branch.oid 1234abcd
        # branch.head feature/alert-policy
        # branch.upstream origin/feature/alert-policy
        # branch.ab +0 -0
        """

        let state = WorktreeStateResolver.parseStatus(output: output, path: "/tmp/wt")

        XCTAssertEqual(state.verdict, .clean)
        XCTAssertEqual(state.detail, "feature/alert-policy")
    }

    func testParseStatusDirtyWorktreeCountsEntries() {
        let output = """
        # branch.head main
        1 .M N... 100644 100644 100644 abc def Watchdog/App.swift
        ? untracked-file.txt
        """

        let state = WorktreeStateResolver.parseStatus(output: output, path: "/tmp/wt")

        XCTAssertEqual(state.verdict, .dirty)
        XCTAssertEqual(state.detail, "main · 변경 2개")
    }

    func testParseStatusUnpushedCommitsMarkDirty() {
        let output = """
        # branch.head main
        # branch.ab +3 -0
        """

        let state = WorktreeStateResolver.parseStatus(output: output, path: "/tmp/wt")

        XCTAssertEqual(state.verdict, .dirty)
        XCTAssertEqual(state.detail, "main · 미푸시 3커밋")
    }

    func testParseStatusDetachedHeadOmitsBranchFromDetail() {
        let output = """
        # branch.head (detached)
        """

        let state = WorktreeStateResolver.parseStatus(output: output, path: "/tmp/wt")

        XCTAssertEqual(state.verdict, .clean)
        XCTAssertNil(state.detail)
    }

    func testLookupFailingCommandReportsMissing() async {
        let resolver = WorktreeStateResolver(
            runner: { _, _, _ in
                throw CommandRunnerError.failed(
                    executable: "/usr/bin/git",
                    status: 128,
                    message: "not a git repository"
                )
            }
        )
        let collector = StateCollector()

        await resolver.resolve(["/tmp/definitely-not-a-repo"]) { path, state in
            collector.record(path: path, state: state)
        }
        await resolver.drainForTesting()

        let states = collector.states
        XCTAssertEqual(states.first?.value.verdict, .missing)
    }

    func testResolveDeduplicatesPathsAndCachesWithinTTL() async {
        let counter = InvocationCounter()
        let resolver = WorktreeStateResolver(
            runner: { _, _, _ in
                await counter.increment()
                return "# branch.head main\n"
            }
        )
        let collector = StateCollector()

        await resolver.resolve(["/repo-a", "/repo-a", "/repo-b"]) { path, state in
            collector.record(path: path, state: state)
        }
        await resolver.drainForTesting()

        let firstRound = counter.count
        XCTAssertEqual(firstRound, 2, "duplicate path must collapse to one lookup")

        // Cached result: no new git invocation.
        await resolver.resolve(["/repo-a"]) { _, _ in }
        await resolver.drainForTesting()

        let cachedRound = counter.count
        XCTAssertEqual(cachedRound, 2, "cached path must not re-invoke git")

        let states = collector.states
        XCTAssertEqual(states["/repo-a"]?.verdict, .clean)
    }

    func testResolveDeliversParsedStatusFromRunner() async {
        let resolver = WorktreeStateResolver(
            runner: { _, _, _ in
                "# branch.head feature/alert-policy\n# branch.ab +0 -0\n"
            }
        )
        let collector = StateCollector()

        await resolver.resolve(["/tmp/fake-checkout"]) { path, state in
            collector.record(path: path, state: state)
        }
        await resolver.drainForTesting()

        let states = collector.states
        XCTAssertEqual(states["/tmp/fake-checkout"]?.verdict, .clean)
        XCTAssertEqual(states["/tmp/fake-checkout"]?.detail, "feature/alert-policy")
    }
}


private final class StateCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: WorktreeState] = [:]

    var states: [String: WorktreeState] {
        lock.withLock { storage }
    }

    func record(path: String, state: WorktreeState?) {
        lock.withLock {
            if let state {
                storage[path] = state
            }
        }
    }
}

private final class InvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.withLock { value }
    }

    func increment() {
        lock.withLock { value += 1 }
    }
}
