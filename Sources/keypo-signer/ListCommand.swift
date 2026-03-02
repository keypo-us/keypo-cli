import ArgumentParser
import Foundation
import KeypoCore

struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all managed keys and their status"
    )

    @OptionGroup var globals: GlobalOptions

    mutating func run() throws {
        let store = makeStore(globals)
        let manager = SecureEnclaveManager()

        let keys: [KeyMetadata]
        do {
            keys = try store.loadKeys()
        } catch let error as KeypoError {
            writeStderr(error.description)
            throw ExitCode(1)
        }

        var entries: [ListKeyEntry] = []
        for key in keys {
            let status = manager.lookupKeyByDataRep(key.dataRepresentation) ? "active" : "missing"
            entries.append(ListKeyEntry(
                keyId: key.keyId,
                publicKey: key.publicKey,
                policy: key.policy.rawValue,
                status: status,
                createdAt: key.createdAt,
                signingCount: key.signingCount,
                lastUsedAt: key.lastUsedAt
            ))
        }

        let output = ListOutput(keys: entries)

        switch globals.format {
        case .json, .raw:
            try outputJSON(output)
        case .pretty:
            if entries.isEmpty {
                writeStdout("No keys found.\n")
            } else {
                let fmt = makeISOFormatter()
                for entry in entries {
                    writeStdout("Key ID:     \(entry.keyId)\n")
                    writeStdout("Public Key: \(entry.publicKey)\n")
                    writeStdout("Policy:     \(entry.policy)\n")
                    writeStdout("Status:     \(entry.status)\n")
                    writeStdout("Created:    \(fmt.string(from: entry.createdAt))\n")
                    writeStdout("Signs:      \(entry.signingCount)\n")
                    if let lastUsed = entry.lastUsedAt {
                        writeStdout("Last Used:  \(fmt.string(from: lastUsed))\n")
                    } else {
                        writeStdout("Last Used:  never\n")
                    }
                    writeStdout("\n")
                }
            }
        }
    }
}
