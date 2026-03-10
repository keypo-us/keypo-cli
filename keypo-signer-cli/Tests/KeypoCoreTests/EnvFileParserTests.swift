import XCTest
@testable import KeypoCore

final class EnvFileParserTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keypo-env-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private func writeTempEnv(_ content: String, filename: String = ".env") -> String {
        let path = tempDir.appendingPathComponent(filename).path
        FileManager.default.createFile(atPath: path, contents: content.data(using: .utf8))
        return path
    }

    private func writeTempEnvData(_ data: Data, filename: String = ".env") -> String {
        let path = tempDir.appendingPathComponent(filename).path
        FileManager.default.createFile(atPath: path, contents: data)
        return path
    }

    // MARK: - Tests

    func testBasicKeyValue() throws {
        let path = writeTempEnv("KEY=VALUE")
        let entries = try EnvFileParser.parseEntries(from: path)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].key, "KEY")
        XCTAssertEqual(entries[0].value, "VALUE")
    }

    func testEmptyValue() throws {
        let path = writeTempEnv("KEY=")
        let entries = try EnvFileParser.parseEntries(from: path)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].key, "KEY")
        XCTAssertEqual(entries[0].value, "")
    }

    func testQuotedValue() throws {
        let path = writeTempEnv("KEY=\"value\"")
        let entries = try EnvFileParser.parseEntries(from: path)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].key, "KEY")
        XCTAssertEqual(entries[0].value, "value")
    }

    func testSingleQuotedValue() throws {
        let path = writeTempEnv("KEY='value'")
        let entries = try EnvFileParser.parseEntries(from: path)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].key, "KEY")
        XCTAssertEqual(entries[0].value, "value")
    }

    func testExportPrefix() throws {
        let path = writeTempEnv("export KEY=value")
        let entries = try EnvFileParser.parseEntries(from: path)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].key, "KEY")
        XCTAssertEqual(entries[0].value, "value")
    }

    func testCommentLinesSkipped() throws {
        let content = "# this is a comment\n# another comment"
        let keys = EnvFileParser.parseKeyNamesFromString(content)
        XCTAssertEqual(keys.count, 0)
    }

    func testBlankLinesSkipped() throws {
        let content = "\n\n\n"
        let keys = EnvFileParser.parseKeyNamesFromString(content)
        XCTAssertEqual(keys.count, 0)
    }

    func testNoEqualsSignSkipped() {
        let content = "THIS_HAS_NO_EQUALS"
        let keys = EnvFileParser.parseKeyNamesFromString(content)
        XCTAssertEqual(keys.count, 0)
    }

    func testDuplicateKeys() {
        let content = "KEY=value1\nKEY=value2"
        let keys = EnvFileParser.parseKeyNamesFromString(content)
        XCTAssertEqual(keys.count, 1)
        XCTAssertEqual(keys[0], "KEY")
    }

    func testMixedValidAndInvalid() {
        let content = """
        # comment
        VALID_KEY=value
        no-equals-here
        ANOTHER_KEY=value2

        # another comment
        THIRD=val
        """
        let keys = EnvFileParser.parseKeyNamesFromString(content)
        XCTAssertEqual(keys.count, 3)
        XCTAssertEqual(keys[0], "VALID_KEY")
        XCTAssertEqual(keys[1], "ANOTHER_KEY")
        XCTAssertEqual(keys[2], "THIRD")
    }

    func testWindowsLineEndings() throws {
        let content = "KEY1=val1\r\nKEY2=val2\r\n"
        let path = writeTempEnv(content)
        let entries = try EnvFileParser.parseEntries(from: path)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].key, "KEY1")
        XCTAssertEqual(entries[0].value, "val1")
        XCTAssertEqual(entries[1].key, "KEY2")
        XCTAssertEqual(entries[1].value, "val2")
    }

    func testLeadingTrailingWhitespace() throws {
        let path = writeTempEnv("  KEY = value  ")
        let entries = try EnvFileParser.parseEntries(from: path)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].key, "KEY")
        XCTAssertEqual(entries[0].value, "value")
    }

    func testEmptyFile() throws {
        let path = writeTempEnv("")
        let entries = try EnvFileParser.parseEntries(from: path)
        XCTAssertEqual(entries.count, 0)
    }

    func testUTF8BOM() throws {
        // UTF-8 BOM: EF BB BF
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append("KEY=value\n".data(using: .utf8)!)
        let path = writeTempEnvData(data, filename: "bom.env")
        let entries = try EnvFileParser.parseEntries(from: path)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].key, "KEY")
        XCTAssertEqual(entries[0].value, "value")
    }

    func testFileNotFound() {
        let bogusPath = tempDir.appendingPathComponent("nonexistent.env").path
        XCTAssertThrowsError(try EnvFileParser.parseEntries(from: bogusPath)) { error in
            guard let vaultError = error as? VaultError else {
                XCTFail("Expected VaultError, got \(error)")
                return
            }
            if case .serializationFailed(let msg) = vaultError {
                XCTAssertTrue(msg.contains("cannot read file"), "Unexpected message: \(msg)")
            } else {
                XCTFail("Expected serializationFailed, got \(vaultError)")
            }
        }
    }
}
