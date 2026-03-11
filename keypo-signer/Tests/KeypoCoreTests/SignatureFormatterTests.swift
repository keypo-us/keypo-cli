import XCTest
@testable import KeypoCore

final class SignatureFormatterTests: XCTestCase {

    // MARK: - Hex Parsing

    func testParseHexWithPrefix() throws {
        let data = try SignatureFormatter.parseHex("0xdeadbeef")
        XCTAssertEqual(data, Data([0xde, 0xad, 0xbe, 0xef]))
    }

    func testParseHexWithoutPrefix() throws {
        let data = try SignatureFormatter.parseHex("deadbeef")
        XCTAssertEqual(data, Data([0xde, 0xad, 0xbe, 0xef]))
    }

    func testParseHexRejectsOddLength() {
        XCTAssertThrowsError(try SignatureFormatter.parseHex("0x123"))
    }

    func testParseHexRejectsEmpty() {
        XCTAssertThrowsError(try SignatureFormatter.parseHex(""))
    }

    func testParseHexRejectsNonHex() {
        XCTAssertThrowsError(try SignatureFormatter.parseHex("not-hex"))
    }

    func testParseHexTrimsWhitespace() throws {
        let data = try SignatureFormatter.parseHex("  0xab  \n")
        XCTAssertEqual(data, Data([0xab]))
    }

    // MARK: - Hex Formatting

    func testFormatHexWithPrefix() {
        let hex = SignatureFormatter.formatHex(Data([0xde, 0xad]))
        XCTAssertEqual(hex, "0xdead")
    }

    func testFormatHexWithoutPrefix() {
        let hex = SignatureFormatter.formatHex(Data([0xde, 0xad]), prefix: false)
        XCTAssertEqual(hex, "dead")
    }

    // MARK: - Big-Endian Comparison

    func testCompareBigEndianEqual() {
        let a = Data([0x01, 0x02])
        let b = Data([0x01, 0x02])
        XCTAssertEqual(SignatureFormatter.compareBigEndian(a, b), 0)
    }

    func testCompareBigEndianLess() {
        let a = Data([0x01, 0x02])
        let b = Data([0x01, 0x03])
        XCTAssertEqual(SignatureFormatter.compareBigEndian(a, b), -1)
    }

    func testCompareBigEndianGreater() {
        let a = Data([0x02, 0x00])
        let b = Data([0x01, 0xFF])
        XCTAssertEqual(SignatureFormatter.compareBigEndian(a, b), 1)
    }

    func testCompareDifferentLengths() {
        let a = Data([0x01, 0x00])  // 256
        let b = Data([0xFF])        // 255
        XCTAssertEqual(SignatureFormatter.compareBigEndian(a, b), 1)
    }

    // MARK: - Big-Endian Subtraction

    func testSubtractBigEndian() {
        let a = Data([0x10])
        let b = Data([0x03])
        let result = SignatureFormatter.subtractBigEndian(a, b)
        XCTAssertEqual(result, Data([0x0d]))
    }

    func testSubtractWithBorrow() {
        let a = Data([0x01, 0x00])  // 256
        let b = Data([0x00, 0x01])  // 1
        let result = SignatureFormatter.subtractBigEndian(a, b)
        XCTAssertEqual(result, Data([0xff]))  // 255
    }

    // MARK: - Low-S Normalization

    func testLowSAtHalfOrder() {
        // s exactly at halfOrder should NOT normalize
        let halfOrder = SignatureFormatter.halfOrder
        let result = SignatureFormatter.applyLowS(s: halfOrder)
        XCTAssertEqual(result, halfOrder)
    }

    func testLowSAboveHalfOrder() {
        // s = halfOrder + 1 should normalize to curveOrder - s
        let halfOrder = SignatureFormatter.halfOrder
        let one = Data([0x01])
        // halfOrder + 1
        let s = addBigEndian(halfOrder, one)
        let result = SignatureFormatter.applyLowS(s: s)
        // result should be curveOrder - s
        let expected = SignatureFormatter.subtractBigEndian(
            SignatureFormatter.leftPad(SignatureFormatter.curveOrder, to: 32),
            SignatureFormatter.leftPad(s, to: 32)
        )
        XCTAssertEqual(
            SignatureFormatter.compareBigEndian(result, expected),
            0
        )
    }

    func testLowSBelowHalfOrder() {
        // s well below halfOrder should not change
        let s = Data([0x01, 0x02, 0x03])
        let result = SignatureFormatter.applyLowS(s: s)
        XCTAssertEqual(result, s)
    }

    // MARK: - DER Parsing and Reconstruction

    func testDERRoundTrip() throws {
        // Build a simple DER signature
        let r = Data([0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
                      0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
                      0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
                      0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef])
        let s = Data([0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
                      0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
                      0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
                      0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef])

        let der = SignatureFormatter.reconstructDER(r: r, s: s)
        let (parsedR, parsedS) = try SignatureFormatter.parseDERSignature(der)
        XCTAssertEqual(parsedR, r)
        XCTAssertEqual(parsedS, s)
    }

    func testDERWithLeadingZeroPaddingOnHighBit() throws {
        // r with high bit set should get 0x00 padding in DER
        let r = Data([0x80, 0x00, 0x00, 0x01])
        let s = Data([0x01, 0x02, 0x03, 0x04])
        let der = SignatureFormatter.reconstructDER(r: r, s: s)
        // Parse back
        let (parsedR, parsedS) = try SignatureFormatter.parseDERSignature(der)
        XCTAssertEqual(parsedR, r)
        XCTAssertEqual(parsedS, s)
    }

    // MARK: - Label Validation

    func testValidLabels() {
        XCTAssertTrue(validateLabel("my-key"))
        XCTAssertTrue(validateLabel("a"))
        XCTAssertTrue(validateLabel("test-key-123"))
        XCTAssertTrue(validateLabel("abcdefghijklmnopqrstuvwxyz0123456789"))
    }

    func testInvalidLabels() {
        XCTAssertFalse(validateLabel(""))
        XCTAssertFalse(validateLabel("Has-Caps"))
        XCTAssertFalse(validateLabel("123-starts-number"))
        XCTAssertFalse(validateLabel("-starts-hyphen"))
        XCTAssertFalse(validateLabel("has spaces"))
        // 65 chars (too long)
        XCTAssertFalse(validateLabel(String(repeating: "a", count: 65)))
    }

    // MARK: - Helpers

    private func addBigEndian(_ a: Data, _ b: Data) -> Data {
        let maxLen = max(a.count, b.count)
        let aPadded = SignatureFormatter.leftPad(a, to: maxLen)
        let bPadded = SignatureFormatter.leftPad(b, to: maxLen)
        var result = [UInt8](repeating: 0, count: maxLen)
        var carry: Int = 0
        for i in stride(from: maxLen - 1, through: 0, by: -1) {
            let sum = Int(aPadded[aPadded.startIndex + i]) + Int(bPadded[bPadded.startIndex + i]) + carry
            result[i] = UInt8(sum & 0xFF)
            carry = sum >> 8
        }
        if carry > 0 {
            return Data([UInt8(carry)] + result)
        }
        return Data(result)
    }
}
