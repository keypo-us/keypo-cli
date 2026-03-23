import ArgumentParser
import Foundation
import KeypoCore

struct VaultInitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Initialize the vault with Secure Enclave keys"
    )

    @OptionGroup var globals: GlobalOptions

    @Flag(name: .customLong("open-only"), help: "Create only the open vault (for headless devices without Touch ID)")
    var openOnly: Bool = false

    mutating func run() throws {
        let store = makeVaultStore(globals)

        // Check if already initialized
        if store.vaultExists() {
            writeStderr("vault already initialized")
            throw ExitCode(1)
        }

        // Check SE availability
        let manager = VaultManager()
        guard SecureEnclave.isAvailable else {
            writeStderr("Secure Enclave is not available on this device")
            throw ExitCode(2)
        }

        let now = Date()
        var vaults: [String: VaultEntry] = [:]
        var createdKeys: [(policy: String, dataRep: Data)] = []
        var skippedPolicies: [String] = []

        let policies: [(name: String, policy: KeyPolicy)] = openOnly
            ? [("open", .open)]
            : [("open", .open), ("passcode", .passcode), ("biometric", .biometric)]

        for (name, policy) in policies {
            var keyDataRep: Data? = nil
            do {
                // Create SE KeyAgreement key
                let keyResult = try manager.createKeyAgreementKey(policy: policy)
                keyDataRep = keyResult.dataRepresentation

                // Create integrity envelope (triggers access control for passcode/biometric)
                let envelope = try manager.createIntegrityEnvelope(
                    seKeyDataRepresentation: keyResult.dataRepresentation
                )

                createdKeys.append((policy: name, dataRep: keyResult.dataRepresentation))
                let entry = VaultEntry(
                    vaultKeyId: "com.keypo.vault.\(name)",
                    dataRepresentation: keyResult.dataRepresentation.base64EncodedString(),
                    publicKey: SignatureFormatter.formatHex(keyResult.publicKey),
                    integrityEphemeralPublicKey: SignatureFormatter.formatHex(envelope.ephemeralPublicKey),
                    integrityHmac: envelope.hmac.base64EncodedString(),
                    createdAt: now
                )
                vaults[name] = entry
            } catch {
                // Clean up orphaned SE key if createKeyAgreementKey succeeded but envelope failed
                if let rep = keyDataRep { manager.deleteKeyAgreementKey(dataRepresentation: rep) }

                // Authentication cancellation — always abort (don't silently degrade security)
                if let vaultErr = error as? VaultError, case .authenticationCancelled = vaultErr {
                    for created in createdKeys { manager.deleteKeyAgreementKey(dataRepresentation: created.dataRep) }
                    writeStderr("authentication cancelled")
                    throw ExitCode(4)
                }

                // Open tier must succeed — abort entirely
                if name == "open" {
                    for created in createdKeys { manager.deleteKeyAgreementKey(dataRepresentation: created.dataRep) }
                    writeStderr("failed to create open vault: \(error)")
                    throw ExitCode(3)
                }

                // passcode/biometric — skip with warning
                skippedPolicies.append(name)
                writeStderr("skipping \(name) vault: \(error)")
            }
        }

        let vaultFile = VaultFile(version: 2, vaults: vaults)
        do {
            try store.saveVaultFile(vaultFile)
        } catch {
            // Clean up SE keys if file write fails
            for created in createdKeys {
                manager.deleteKeyAgreementKey(dataRepresentation: created.dataRep)
            }
            writeStderr("failed to write vault.json: \(error)")
            throw ExitCode(3)
        }

        // Output
        let initEntries = createdKeys.map {
            VaultInitOutput.VaultInitEntry(vaultKeyId: "com.keypo.vault.\($0.policy)", policy: $0.policy)
        }
        let output = VaultInitOutput(vaults: initEntries, skipped: skippedPolicies, createdAt: now)

        switch globals.format {
        case .json:
            try outputJSON(output)
        case .raw, .pretty:
            let vaultNames = createdKeys.map(\.policy).joined(separator: ", ")
            var msg = "Vault initialized with \(createdKeys.count) vault(s): \(vaultNames)"
            if !skippedPolicies.isEmpty && !openOnly {
                msg += " (skipped: \(skippedPolicies.joined(separator: ", ")) — not available on this device)"
            }
            writeStdout(msg + "\n")
        }
    }
}

import CryptoKit
