import XCTest
@testable import KeypoCore

final class TTLParserTests: XCTestCase {

    // MARK: - Valid inputs

    func testParseSeconds() {
        XCTAssertEqual(TTLParser.parse("90s"), 90)
        XCTAssertEqual(TTLParser.parse("1s"), 1)
    }

    func testParseMinutes() {
        XCTAssertEqual(TTLParser.parse("30m"), 1800)
        XCTAssertEqual(TTLParser.parse("1m"), 60)
    }

    func testParseHours() {
        XCTAssertEqual(TTLParser.parse("2h"), 7200)
        XCTAssertEqual(TTLParser.parse("24h"), 86400)
        XCTAssertEqual(TTLParser.parse("48h"), 172800)
    }

    func testParseDays() {
        XCTAssertEqual(TTLParser.parse("1d"), 86400)
        XCTAssertEqual(TTLParser.parse("7d"), 604800)
    }

    // MARK: - Values above 24h parse successfully (no hard cap)

    func testAbove24hParses() {
        XCTAssertNotNil(TTLParser.parse("25h"))
        XCTAssertEqual(TTLParser.parse("25h"), 90000)
        XCTAssertNotNil(TTLParser.parse("7d"))
        XCTAssertEqual(TTLParser.parse("7d"), 604800)
    }

    // MARK: - Invalid inputs return nil

    func testEmptyStringReturnsNil() {
        XCTAssertNil(TTLParser.parse(""))
    }

    func testInvalidSuffixReturnsNil() {
        XCTAssertNil(TTLParser.parse("30x"))
        XCTAssertNil(TTLParser.parse("abc"))
    }

    func testNonNumericReturnsNil() {
        XCTAssertNil(TTLParser.parse("abcm"))
    }

    // MARK: - Zero and negative return nil

    func testZeroReturnsNil() {
        XCTAssertNil(TTLParser.parse("0s"))
        XCTAssertNil(TTLParser.parse("0m"))
        XCTAssertNil(TTLParser.parse("0h"))
    }

    func testNegativeReturnsNil() {
        XCTAssertNil(TTLParser.parse("-5m"))
        XCTAssertNil(TTLParser.parse("-1h"))
    }

    // MARK: - Format roundtrip

    func testFormatDays() {
        XCTAssertEqual(TTLParser.format(86400), "1d")
    }

    func testFormatHours() {
        XCTAssertEqual(TTLParser.format(7200), "2h")
    }

    func testFormatMinutes() {
        XCTAssertEqual(TTLParser.format(1800), "30m")
    }

    func testFormatSeconds() {
        XCTAssertEqual(TTLParser.format(90), "90s")
    }
}
