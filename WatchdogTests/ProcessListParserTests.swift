import XCTest
@testable import Watchdog

final class ProcessListParserTests: XCTestCase {
    func testParsesCommandWithSpaces() throws {
        let line = "77753 67890 67890 501 ?? 720384 R 02:08:58 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome Helper (Renderer)"

        let process = try XCTUnwrap(ProcessListParser.parseLine(line))

        XCTAssertEqual(process.id, 77_753)
        XCTAssertEqual(process.parentPID, 67_890)
        XCTAssertEqual(process.userID, 501)
        XCTAssertEqual(process.cpuPercent, 0, accuracy: 0.001)
        XCTAssertEqual(process.residentBytes, 720_384 * 1_024)
        XCTAssertEqual(process.displayName, "Chrome 렌더러")
        XCTAssertEqual(process.kind, .browserRenderer)
    }

    func testRejectsMalformedLine() {
        XCTAssertNil(ProcessListParser.parseLine("not a process"))
    }

    func testCodexRendererIsNotClassifiedAsAgent() throws {
        let line = "500 1 500 501 ?? 120000 S 01:00 /Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/Helpers/Codex (Renderer)"

        let process = try XCTUnwrap(ProcessListParser.parseLine(line))

        XCTAssertNotEqual(process.kind, .agent)
    }

    func testChatGPTBundledCodexIsAnApplicationProcess() throws {
        let line = "80197 80082 80082 501 ?? 92112 T 03:26:49 /Applications/ChatGPT.app/Contents/Resources/codex"

        let process = try XCTUnwrap(ProcessListParser.parseLine(line))

        XCTAssertEqual(process.kind, .application)
    }
}
