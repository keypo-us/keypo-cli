import ArgumentParser
import Foundation
import KeypoCore

struct CreateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Generate a new P-256 signing key in the Secure Enclave"
    )

    @OptionGroup var globals: GlobalOptions

    @Option(name: .long, help: "Human-readable key identifier")
    var label: String

    @Option(name: .long, help: "Access control policy: open, passcode, or biometric")
    var policy: KeyPolicy

    mutating func run() throws {
        // Validate label format
        guard validateLabel(label) else {
            writeStderr("invalid label format: must be lowercase alphanumeric and hyphens, start with a letter, 1-64 chars")
            throw ExitCode(1)
        }

        let store = makeStore(globals)

        // Check label uniqueness
        do {
            let existing = try store.findKey(keyId: label)
            if existing != nil {
                writeStderr("label '\(label)' already exists")
                throw ExitCode(1)
            }
        } catch let error as KeypoError {
            writeStderr(error.description)
            throw ExitCode(1)
        }

        // Check SE availability
        let manager = SecureEnclaveManager()
        guard manager.isAvailable() else {
            writeStderr("Secure Enclave is not available on this device")
            throw ExitCode(2)
        }

        // Create key
        let result: (dataRepresentation: Data, publicKey: Data)
        do {
            result = try manager.createKey(policy: policy)
        } catch {
            writeStderr("key generation failed: \(error)")
            throw ExitCode(3)
        }

        let now = Date()
        let publicKeyHex = SignatureFormatter.formatHex(result.publicKey)
        let tag = "com.keypo.signer.\(label)"

        let metadata = KeyMetadata(
            keyId: label,
            applicationTag: tag,
            publicKey: publicKeyHex,
            policy: policy,
            createdAt: now,
            signingCount: 0,
            lastUsedAt: nil,
            previousPublicKeys: [],
            dataRepresentation: result.dataRepresentation.base64EncodedString()
        )

        // Save metadata
        do {
            try store.addKey(metadata)
        } catch {
            // Clean up orphaned SE key
            manager.deleteKey(dataRepresentation: result.dataRepresentation.base64EncodedString())
            writeStderr("failed to save metadata: \(error)")
            throw ExitCode(3)
        }

        // Output
        let output = CreateOutput(keyId: label, publicKey: publicKeyHex, policy: policy.rawValue, createdAt: now)

        switch globals.format {
        case .json:
            try outputJSON(output)
        case .raw:
            writeStdout(publicKeyHex)
        case .pretty:
            let fmt = makeISOFormatter()
            writeStdout("Key ID:     \(label)\n")
            writeStdout("Public Key: \(publicKeyHex)\n")
            writeStdout("Curve:      P-256\n")
            writeStdout("Policy:     \(policy.rawValue)\n")
            writeStdout("Created:    \(fmt.string(from: now))\n")
            writeStdout("Storage:    secure-enclave\n")
        }
    }
}
