import ArgumentParser
import Foundation
import KeypoCore

struct VaultListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all vaults and their secrets (no decryption)",
        discussion: """
        Examples:
          keypo-signer vault list
          keypo-signer vault list --format pretty
        """
    )

    @OptionGroup var globals: GlobalOptions

    mutating func run() throws {
        let store = makeVaultStore(globals)

        // Not an error if vault doesn't exist — return empty list
        guard store.vaultExists() else {
            let output = VaultListOutput(vaults: [])
            switch globals.format {
            case .json:
                try outputJSON(output)
            case .raw, .pretty:
                writeStdout("No vault initialized\n")
            }
            return
        }

        let vaultFile: VaultFile
        do {
            vaultFile = try store.loadVaultFile()
        } catch {
            writeStderr("failed to load vault: \(error)")
            throw ExitCode(1)
        }

        let policyOrder = ["biometric", "passcode", "open"]
        var entries: [VaultListOutput.VaultListEntry] = []

        for policyName in policyOrder {
            guard let vaultEntry = vaultFile.vaults[policyName] else { continue }
            let secrets = vaultEntry.secrets.keys.sorted().map { secretName -> VaultListOutput.VaultListSecret in
                let secret = vaultEntry.secrets[secretName]!
                return VaultListOutput.VaultListSecret(
                    name: secretName,
                    createdAt: secret.createdAt,
                    updatedAt: secret.updatedAt
                )
            }
            entries.append(VaultListOutput.VaultListEntry(
                policy: policyName,
                vaultKeyId: vaultEntry.vaultKeyId,
                createdAt: vaultEntry.createdAt,
                secrets: secrets,
                secretCount: secrets.count
            ))
        }

        let output = VaultListOutput(vaults: entries)

        switch globals.format {
        case .json:
            try outputJSON(output)
        case .raw:
            for entry in entries {
                for secret in entry.secrets {
                    writeStdout("\(secret.name)\n")
                }
            }
        case .pretty:
            for entry in entries {
                writeStdout("[\(entry.policy)] \(entry.secretCount) secret(s)\n")
                for secret in entry.secrets {
                    writeStdout("  \(secret.name)\n")
                }
            }
        }
    }
}
