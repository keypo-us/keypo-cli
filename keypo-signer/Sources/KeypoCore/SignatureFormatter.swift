import Foundation

public struct SignatureFormatter {

    // P-256 curve order
    public static let curveOrder = dataFromHexLiteral("FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551")
    // curve_order / 2
    public static let halfOrder = dataFromHexLiteral("7FFFFFFF800000007FFFFFFFFFFFFFFFDE737D56D38BCF4279DCE5617E3192A8")

    // MARK: - DER Parsing

    public static func parseDERSignature(_ der: Data) throws -> (r: Data, s: Data) {
        guard der.count >= 8 else {
            throw KeypoError.invalidHex("DER signature too short")
        }
        var offset = 0

        // SEQUENCE tag
        guard der[offset] == 0x30 else {
            throw KeypoError.invalidHex("invalid DER: expected SEQUENCE tag")
        }
        offset += 1

        // Sequence length
        let seqLen = Int(der[offset])
        offset += 1

        guard offset + seqLen <= der.count else {
            throw KeypoError.invalidHex("invalid DER: sequence length exceeds data")
        }

        // INTEGER tag for r
        guard der[offset] == 0x02 else {
            throw KeypoError.invalidHex("invalid DER: expected INTEGER tag for r")
        }
        offset += 1

        let rLen = Int(der[offset])
        offset += 1

        guard offset + rLen <= der.count else {
            throw KeypoError.invalidHex("invalid DER: r length exceeds data")
        }

        var r = Data(der[offset..<(offset + rLen)])
        offset += rLen

        // INTEGER tag for s
        guard der[offset] == 0x02 else {
            throw KeypoError.invalidHex("invalid DER: expected INTEGER tag for s")
        }
        offset += 1

        let sLen = Int(der[offset])
        offset += 1

        guard offset + sLen <= der.count else {
            throw KeypoError.invalidHex("invalid DER: s length exceeds data")
        }

        var s = Data(der[offset..<(offset + sLen)])

        // Strip leading zero bytes (DER uses them to keep integers positive)
        while r.count > 1 && r[r.startIndex] == 0x00 {
            r = r.dropFirst()
        }
        while s.count > 1 && s[s.startIndex] == 0x00 {
            s = s.dropFirst()
        }

        return (r: Data(r), s: Data(s))
    }

    // MARK: - Low-S Normalization

    public static func applyLowS(s: Data) -> Data {
        // Pad to 32 bytes for comparison
        let sPadded = leftPad(s, to: 32)
        let halfPadded = leftPad(halfOrder, to: 32)

        if compareBigEndian(sPadded, halfPadded) > 0 {
            // s > halfOrder, compute curveOrder - s
            let orderPadded = leftPad(curveOrder, to: 32)
            return subtractBigEndian(orderPadded, sPadded)
        }
        return s
    }

    // MARK: - DER Reconstruction

    public static func reconstructDER(r: Data, s: Data) -> Data {
        let rDER = encodeInteger(r)
        let sDER = encodeInteger(s)
        let seqLen = rDER.count + sDER.count
        var result = Data()
        result.append(0x30) // SEQUENCE tag
        result.append(UInt8(seqLen))
        result.append(rDER)
        result.append(sDER)
        return result
    }

    private static func encodeInteger(_ value: Data) -> Data {
        var bytes = Data(value)
        // Strip leading zeros for minimal encoding
        while bytes.count > 1 && bytes[bytes.startIndex] == 0x00 {
            bytes = Data(bytes.dropFirst())
        }
        // If high bit is set, prepend 0x00 to keep positive
        var result = Data()
        result.append(0x02) // INTEGER tag
        if bytes[bytes.startIndex] & 0x80 != 0 {
            result.append(UInt8(bytes.count + 1))
            result.append(0x00)
        } else {
            result.append(UInt8(bytes.count))
        }
        result.append(bytes)
        return result
    }

    // MARK: - Hex Formatting

    public static func formatHex(_ data: Data, prefix: Bool = true) -> String {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        return prefix ? "0x\(hex)" : hex
    }

    public static func parseHex(_ hex: String) throws -> Data {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            throw KeypoError.invalidHex("empty input")
        }
        if cleaned.hasPrefix("0x") || cleaned.hasPrefix("0X") {
            cleaned = String(cleaned.dropFirst(2))
        }
        if cleaned.isEmpty {
            throw KeypoError.invalidHex("empty hex after prefix")
        }
        if cleaned.count % 2 != 0 {
            throw KeypoError.invalidHex("odd-length hex string")
        }
        // Validate all characters are hex
        guard cleaned.allSatisfy({ $0.isHexDigit }) else {
            throw KeypoError.invalidHex("contains non-hex characters")
        }
        var data = Data()
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let nextIndex = cleaned.index(index, offsetBy: 2)
            let byteString = cleaned[index..<nextIndex]
            guard let byte = UInt8(byteString, radix: 16) else {
                throw KeypoError.invalidHex("invalid hex byte: \(byteString)")
            }
            data.append(byte)
            index = nextIndex
        }
        return data
    }

    // MARK: - Big-Endian Arithmetic

    /// Compare two big-endian byte arrays. Returns -1, 0, or 1.
    public static func compareBigEndian(_ a: Data, _ b: Data) -> Int {
        let maxLen = max(a.count, b.count)
        let aPadded = leftPad(a, to: maxLen)
        let bPadded = leftPad(b, to: maxLen)
        for i in 0..<maxLen {
            if aPadded[aPadded.startIndex + i] < bPadded[bPadded.startIndex + i] { return -1 }
            if aPadded[aPadded.startIndex + i] > bPadded[bPadded.startIndex + i] { return 1 }
        }
        return 0
    }

    /// Subtract b from a (big-endian, a >= b assumed).
    public static func subtractBigEndian(_ a: Data, _ b: Data) -> Data {
        let maxLen = max(a.count, b.count)
        let aPadded = leftPad(a, to: maxLen)
        let bPadded = leftPad(b, to: maxLen)
        var result = [UInt8](repeating: 0, count: maxLen)
        var borrow: Int = 0
        for i in stride(from: maxLen - 1, through: 0, by: -1) {
            let diff = Int(aPadded[aPadded.startIndex + i]) - Int(bPadded[bPadded.startIndex + i]) - borrow
            if diff < 0 {
                result[i] = UInt8(diff + 256)
                borrow = 1
            } else {
                result[i] = UInt8(diff)
                borrow = 0
            }
        }
        // Strip leading zeros but keep at least 1 byte
        var data = Data(result)
        while data.count > 1 && data[data.startIndex] == 0x00 {
            data = Data(data.dropFirst())
        }
        return data
    }

    /// Left-pad data with zeros to reach target length.
    public static func leftPad(_ data: Data, to length: Int) -> Data {
        if data.count >= length { return data }
        var padded = Data(repeating: 0, count: length - data.count)
        padded.append(data)
        return padded
    }

    // MARK: - Helper

    private static func dataFromHexLiteral(_ hex: String) -> Data {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            let byteString = hex[index..<nextIndex]
            data.append(UInt8(byteString, radix: 16)!)
            index = nextIndex
        }
        return data
    }
}
