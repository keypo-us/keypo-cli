import ArgumentParser
import Foundation
import KeypoCore

struct VaultDestroyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "destroy",
        abstract: "Destroy all vaults, deleting all encrypted secrets and vault keys"
    )

    @OptionGroup var globals: GlobalOptions

    @Flag(name: .long, help: "Confirm vault destruction (required)")
    var confirm: Bool = false

    mutating func run() throws {
        guard confirm else {
            writeStderr("--confirm flag is required for vault destruction")
            throw ExitCode(2)
        }

        let store = makeVaultStore(globals)

        guard store.vaultExists() else {
            writeStderr("vault not initialized")
            throw ExitCode(1)
        }

        let vaultFile: VaultFile
        do {
            vaultFile = try store.loadVaultFile()
        } catch {
            writeStderr("failed to load vault: \(error)")
            throw ExitCode(1)
        }

        let manager = VaultManager()
        var totalSecrets = 0
        var destroyedVaults: [String] = []

        // Delete SE keys in order: open, passcode, biometric
        for policyName in ["open", "passcode", "biometric"] {
            guard let entry = vaultFile.vaults[policyName] else { continue }
            totalSecrets += entry.secrets.count

            // Best-effort SE key deletion
            if let dataRep = Data(base64Encoded: entry.dataRepresentation) {
                manager.deleteKeyAgreementKey(dataRepresentation: dataRep)
            }
            destroyedVaults.append(policyName)
        }

        // Delete vault.json
        do {
            try store.deleteVaultFile()
        } catch {
            writeStderrWarning("failed to delete vault.json: \(error)")
        }

        // Output
        let output = VaultDestroyOutput(
            vaultsDestroyed: destroyedVaults,
            totalSecretsDeleted: totalSecrets,
            destroyedAt: Date()
        )

        switch globals.format {
        case .json:
            try outputJSON(output)
        case .raw, .pretty:
            writeStdout("Vault destroyed: \(destroyedVaults.count) vault(s), \(totalSecrets) secret(s) deleted\n")
        }
    }
}
