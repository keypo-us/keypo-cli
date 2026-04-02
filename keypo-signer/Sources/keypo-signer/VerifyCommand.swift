import ArgumentParser
import CryptoKit
import Foundation
import KeypoCore

struct VerifyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Verify a signature against a public key",
        discussion: """
        Examples:
          keypo-signer verify 0xdeadbeef 0x3045... --key my-key
          keypo-signer verify 0xdeadbeef 0x3045... --public-key 0x04abcd...
        """
    )

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Hex-encoded data that was signed")
    var data: String

    @Argument(help: "Hex-encoded DER signature")
    var signature: String

    @Option(name: .long, help: "Verify against this key's public key")
    var key: String?

    @Option(name: .customLong("public-key"), help: "Verify against an explicit public key hex")
    var publicKey: String?

    mutating func run() throws {
        // Validate that exactly one key source is specified
        if key != nil && publicKey != nil {
            writeStderr("specify either --key or --public-key, not both")
            throw ExitCode(2)
        }
        if key == nil && publicKey == nil {
            writeStderr("specify --key or --public-key")
            throw ExitCode(2)
        }

        // Parse data hex
        let dataBytes: Data
        do {
            dataBytes = try SignatureFormatter.parseHex(data)
        } catch {
            writeStderr("invalid hex data")
            throw ExitCode(2)
        }

        // Parse signature hex
        let sigBytes: Data
        do {
            sigBytes = try SignatureFormatter.parseHex(signature)
        } catch {
            writeStderr("invalid hex signature")
            throw ExitCode(2)
        }

        // Validate DER structure
        do {
            _ = try SignatureFormatter.parseDERSignature(sigBytes)
        } catch {
            writeStderr("invalid DER signature")
            throw ExitCode(2)
        }

        // Get public key bytes
        let pubKeyBytes: Data
        if let keyId = key {
            let store = makeStore(globals)
            do {
                guard let found = try store.findKey(keyId: keyId) else {
                    writeStderr("key '\(keyId)' not found")
                    throw ExitCode(2)
                }
                pubKeyBytes = try SignatureFormatter.parseHex(found.publicKey)
            } catch let error as KeypoError {
                writeStderr(error.description)
                throw ExitCode(2)
            }
        } else {
            do {
                pubKeyBytes = try SignatureFormatter.parseHex(publicKey!)
            } catch {
                writeStderr("invalid public key hex")
                throw ExitCode(2)
            }
        }

        // Verify
        let valid: Bool
        do {
            let cryptoPubKey = try P256.Signing.PublicKey(x963Representation: pubKeyBytes)
            let ecdsaSig = try P256.Signing.ECDSASignature(derRepresentation: sigBytes)
            valid = cryptoPubKey.isValidSignature(ecdsaSig, for: dataBytes)
        } catch {
            writeStderr("verification error: \(error)")
            throw ExitCode(2)
        }

        let pubKeyHex: String
        if let keyId = key {
            let store = makeStore(globals)
            pubKeyHex = (try? store.findKey(keyId: keyId))?.publicKey ?? SignatureFormatter.formatHex(pubKeyBytes)
        } else {
            pubKeyHex = SignatureFormatter.formatHex(pubKeyBytes)
        }

        let output = VerifyOutput(valid: valid, publicKey: pubKeyHex)

        switch globals.format {
        case .json, .raw:
            try outputJSON(output)
        case .pretty:
            writeStdout("Valid:      \(valid)\n")
            writeStdout("Public Key: \(pubKeyHex)\n")
            writeStdout("Algorithm:  ES256\n")
        }

        if !valid {
            // Use Darwin.exit to avoid swift-argument-parser printing to stderr
            fflush(stdout)
            Darwin.exit(1)
        }
    }
}
