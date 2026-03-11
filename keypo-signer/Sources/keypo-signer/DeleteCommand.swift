import ArgumentParser
import Foundation
import KeypoCore

struct DeleteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Permanently destroy a Secure Enclave key"
    )

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "The key to destroy")
    var keyId: String

    @Flag(name: .long, help: "Confirm deletion (required)")
    var confirm: Bool = false

    mutating func run() throws {
        let store = makeStore(globals)
        let manager = SecureEnclaveManager()

        // Look up key in metadata
        let key: KeyMetadata
        do {
            guard let found = try store.findKey(keyId: keyId) else {
                writeStderr("key '\(keyId)' not found")
                throw ExitCode(1)
            }
            key = found
        } catch let error as KeypoError {
            writeStderr(error.description)
            throw ExitCode(1)
        }

        // Require --confirm
        if !confirm {
            writeStderrRaw("WARNING: This will permanently destroy the key '\(keyId)'")
            writeStderrRaw("Public Key: \(key.publicKey)")
            writeStderrRaw("Use --confirm to proceed with deletion.")
            throw ExitCode(2)
        }

        // Delete SE key (best-effort — may not work without Keychain entitlements)
        let seKeyExists = manager.lookupKeyByDataRep(key.dataRepresentation)
        if seKeyExists {
            manager.deleteKey(dataRepresentation: key.dataRepresentation)
        } else {
            if !globals.quiet {
                writeStderrWarning("SE key already missing, metadata cleaned up")
            }
        }

        // Remove metadata
        do {
            try store.removeKey(keyId: keyId)
        } catch {
            writeStderr("failed to remove metadata: \(error)")
            throw ExitCode(3)
        }

        let now = Date()
        let output = DeleteOutput(keyId: keyId, deletedAt: now)

        switch globals.format {
        case .json, .raw:
            try outputJSON(output)
        case .pretty:
            let fmt = makeISOFormatter()
            writeStdout("Deleted key: \(keyId)\n")
            writeStdout("Deleted at:  \(fmt.string(from: now))\n")
        }
    }
}
