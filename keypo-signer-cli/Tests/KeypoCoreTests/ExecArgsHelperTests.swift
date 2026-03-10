import XCTest
@testable import KeypoCore

final class ExecArgsHelperTests: XCTestCase {

    func testStripsDashDashAndCoalesces() {
        let input = ["--", "sh", "-c", "npm", "run", "build", "&&", "npm", "run", "start"]
        XCTAssertEqual(ExecArgsHelper.prepareExecArgs(input),
                       ["sh", "-c", "npm run build && npm run start"])
    }

    func testNoDashDash() {
        let input = ["sh", "-c", "echo", "hello"]
        XCTAssertEqual(ExecArgsHelper.prepareExecArgs(input),
                       ["sh", "-c", "echo hello"])
    }

    func testPlainCommand() {
        let input = ["--", "echo", "test"]
        XCTAssertEqual(ExecArgsHelper.prepareExecArgs(input),
                       ["echo", "test"])
    }

    func testBashVariant() {
        let input = ["--", "/bin/bash", "-c", "ls", "&&", "pwd"]
        XCTAssertEqual(ExecArgsHelper.prepareExecArgs(input),
                       ["/bin/bash", "-c", "ls && pwd"])
    }

    func testDashDashOnly() {
        XCTAssertEqual(ExecArgsHelper.prepareExecArgs(["--"]), [])
    }

    func testEmptyArray() {
        XCTAssertEqual(ExecArgsHelper.prepareExecArgs([]), [])
    }
}
