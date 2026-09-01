import Darwin
import XCTest
@testable import Watchdog

final class OrphanClassifierTests: XCTestCase {
    func testAgentUnderSessionHostHasNoOrphanReason() throws {
        let orca = snapshot(pid: 100, parent: 1, name: "/Applications/Orca.app/Contents/Frameworks/Orca Helper.app/Contents/MacOS/Orca Helper")
        let login = snapshot(pid: 101, parent: 100, name: "/usr/bin/login")
        let shell = snapshot(pid: 102, parent: 101, name: "/bin/zsh")
        let agent = snapshot(pid: 103, parent: 102, name: "/Users/test/.local/bin/gjc", tty: "ttys009")

        let result = try classified(agent.id, in: [orca, login, shell, agent])

        XCTAssertNil(result.orphanReason)
        XCTAssertFalse(result.suspectedOrphan)
    }

    func testReparentedAgentHasExactLaunchdReason() throws {
        let agent = snapshot(pid: 103, parent: 1, name: "/Users/test/.local/bin/gjc")

        XCTAssertEqual(try classified(agent.id, in: [agent]).orphanReason, .reparentedToLaunchd)
    }

    func testMissingParentHasExactReason() throws {
        let agent = snapshot(pid: 103, parent: 999, name: "/Users/test/.local/bin/gjc")

        XCTAssertEqual(try classified(agent.id, in: [agent]).orphanReason, .missingParent)
    }

    func testCycleHasExactReason() throws {
        let agent = snapshot(pid: 103, parent: 104, name: "/Users/test/.local/bin/gjc")
        let ancestor = snapshot(pid: 104, parent: 103, name: "/bin/zsh")

        XCTAssertEqual(try classified(agent.id, in: [agent, ancestor]).orphanReason, .cyclicLineage)
    }

    func testDetachedLineageHasExactReasonButAttachedTTYDoesNot() throws {
        let detachedAgent = snapshot(pid: 103, parent: 104, name: "/Users/test/.local/bin/gjc")
        let detachedShell = snapshot(pid: 104, parent: 1, name: "/bin/zsh")
        XCTAssertEqual(
            try classified(detachedAgent.id, in: [detachedAgent, detachedShell]).orphanReason,
            .detachedSession
        )

        let attachedAgent = snapshot(pid: 203, parent: 204, name: "/Users/test/.local/bin/gjc", tty: "ttys009")
        let attachedShell = snapshot(pid: 204, parent: 1, name: "/bin/zsh", tty: "ttys009")
        XCTAssertNil(try classified(attachedAgent.id, in: [attachedAgent, attachedShell]).orphanReason)
    }

    func testNonAgentIsNeverClassifiedAsOrphan() throws {
        let ordinary = snapshot(pid: 103, parent: 1, name: "/usr/local/bin/worker")

        let result = try classified(ordinary.id, in: [ordinary])

        XCTAssertEqual(result.kind, .other)
        XCTAssertNil(result.orphanReason)
        XCTAssertFalse(result.suspectedOrphan)
    }

    func testDuplicatePIDLinesDoNotCrashAndStayClassified() throws {
        let first = snapshot(pid: 103, parent: 1, name: "/Users/test/.local/bin/gjc")
        let duplicate = snapshot(pid: 103, parent: 1, name: "/Users/test/.local/bin/gjc")

        let result = try classified(103, in: [first, duplicate])

        XCTAssertEqual(result.orphanReason, .reparentedToLaunchd)
        XCTAssertEqual(OrphanClassifier.classify([first, duplicate]).count, 2)
    }

    private func classified(_ pid: Int32, in snapshots: [ProcessSnapshot]) throws -> ProcessSnapshot {
        try XCTUnwrap(OrphanClassifier.classify(snapshots).first { $0.id == pid })
    }

    private func snapshot(
        pid: Int32,
        parent: Int32,
        name: String,
        tty: String = "??"
    ) -> ProcessSnapshot {
        ProcessSnapshot(
            id: pid,
            parentPID: parent,
            processGroupID: pid,
            userID: getuid(),
            tty: tty,
            cpuPercent: 0,
            residentBytes: 0,
            state: "S",
            elapsed: "00:01",
            executablePath: name,
            startTimeMicroseconds: UInt64(pid) * 1_000_000,
            workingDirectory: nil
        )
    }
}
