import ArgumentParser
import Foundation
import KeypoCore

struct RotateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rotate",
        abstract: "Replace a key with a new one, keeping the same label and policy",
        discussion: """
        Examples:
          keypo-signer rotate my-key
        """
    )

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "The key to rotate")
    var keyId: String

    mutating func run() throws {
        let store = makeStore(globals)
        let manager = SecureEnclaveManager()

        // Look up existing key
        let existingKey: KeyMetadata
        do {
            guard let found = try store.findKey(keyId: keyId) else {
                writeStderr("key '\(keyId)' not found")
                throw ExitCode(1)
            }
            existingKey = found
        } catch let error as KeypoError {
            writeStderr(error.description)
            throw ExitCode(1)
        }

        let oldPublicKey = existingKey.publicKey
        let policy = existingKey.policy

        // Create new SE key WITHOUT tagging (to avoid tag collision)
        let newKeyResult: (dataRepresentation: Data, publicKey: Data)
        do {
            newKeyResult = try manager.createKey(policy: policy)
        } catch {
            writeStderr("new key generation failed: \(error)")
            throw ExitCode(2)
        }

        // Delete old SE key (best-effort)
        manager.deleteKey(dataRepresentation: existingKey.dataRepresentation)

        // Update metadata
        let newPublicKeyHex = SignatureFormatter.formatHex(newKeyResult.publicKey)
        var updatedKey = existingKey
        updatedKey.publicKey = newPublicKeyHex
        updatedKey.dataRepresentation = newKeyResult.dataRepresentation.base64EncodedString()
        updatedKey.previousPublicKeys.append(oldPublicKey)
        updatedKey.signingCount = 0
        updatedKey.lastUsedAt = nil

        do {
            try store.replaceKey(updatedKey)
        } catch {
            writeStderr("failed to update metadata: \(error)")
            throw ExitCode(3)
        }

        let now = Date()
        let output = RotateOutput(
            keyId: keyId,
            publicKey: newPublicKeyHex,
            previousPublicKey: oldPublicKey,
            policy: policy.rawValue,
            rotatedAt: now
        )

        switch globals.format {
        case .json, .raw:
            try outputJSON(output)
        case .pretty:
            let fmt = makeISOFormatter()
            writeStdout("Key ID:          \(keyId)\n")
            writeStdout("Public Key:      \(newPublicKeyHex)\n")
            writeStdout("Previous Key:    \(oldPublicKey)\n")
            writeStdout("Policy:          \(policy.rawValue)\n")
            writeStdout("Rotated At:      \(fmt.string(from: now))\n")
        }

    }
}
