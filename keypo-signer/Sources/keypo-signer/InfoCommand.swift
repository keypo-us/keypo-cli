import ArgumentParser
import Foundation
import KeypoCore

struct InfoCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Get detailed information about a specific key or the system"
    )

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "The key label")
    var keyId: String?

    @Flag(name: .long, help: "Show system information")
    var system: Bool = false

    mutating func run() throws {
        if system && keyId != nil {
            writeStderr("cannot specify both a key ID and --system")
            throw ExitCode(1)
        }

        if system {
            try runSystemInfo()
        } else if let keyId = keyId {
            try runKeyInfo(keyId: keyId)
        } else {
            writeStderr("specify a key ID or --system")
            throw ExitCode(1)
        }
    }

    private func runSystemInfo() throws {
        let manager = SecureEnclaveManager()
        let store = makeStore(globals)

        var keyCount = 0
        if let keys = try? store.loadKeys() {
            keyCount = keys.count
        }

        let output = SystemInfoOutput(
            secureEnclaveAvailable: manager.isAvailable(),
            chip: manager.getChipName(),
            macosVersion: manager.getMacOSVersion(),
            configDir: store.configDir.path,
            keyCount: keyCount
        )

        switch globals.format {
        case .json, .raw:
            try outputJSON(output)
        case .pretty:
            writeStdout("Secure Enclave: \(output.secureEnclaveAvailable ? "available" : "unavailable")\n")
            writeStdout("Chip:           \(output.chip)\n")
            writeStdout("macOS:          \(output.macosVersion)\n")
            writeStdout("Version:        \(output.keypoVersion)\n")
            writeStdout("Config Dir:     \(output.configDir)\n")
            writeStdout("Key Count:      \(output.keyCount)\n")
        }
    }

    private func runKeyInfo(keyId: String) throws {
        let store = makeStore(globals)
        let manager = SecureEnclaveManager()

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

        let status = manager.lookupKeyByDataRep(key.dataRepresentation) ? "active" : "missing"

        let output = InfoOutput(
            keyId: key.keyId,
            publicKey: key.publicKey,
            policy: key.policy.rawValue,
            status: status,
            createdAt: key.createdAt,
            signingCount: key.signingCount,
            lastUsedAt: key.lastUsedAt,
            previousPublicKeys: key.previousPublicKeys
        )

        switch globals.format {
        case .json:
            try outputJSON(output)
        case .raw:
            writeStdout(key.publicKey)
        case .pretty:
            let fmt = makeISOFormatter()
            writeStdout("Key ID:         \(output.keyId)\n")
            writeStdout("Public Key:     \(output.publicKey)\n")
            writeStdout("Curve:          P-256\n")
            writeStdout("Policy:         \(output.policy)\n")
            writeStdout("Status:         \(output.status)\n")
            writeStdout("Created:        \(fmt.string(from: output.createdAt))\n")
            writeStdout("Signing Count:  \(output.signingCount)\n")
            if let lastUsed = output.lastUsedAt {
                writeStdout("Last Used:      \(fmt.string(from: lastUsed))\n")
            } else {
                writeStdout("Last Used:      never\n")
            }
            if !output.previousPublicKeys.isEmpty {
                writeStdout("Previous Keys:  \(output.previousPublicKeys.count)\n")
                for pk in output.previousPublicKeys {
                    writeStdout("  - \(pk)\n")
                }
            }
        }
    }
}
