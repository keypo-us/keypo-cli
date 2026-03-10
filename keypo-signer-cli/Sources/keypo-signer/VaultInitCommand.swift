import ArgumentParser
import Foundation
import KeypoCore

struct VaultInitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Initialize the vault with Secure Enclave keys"
    )

    @OptionGroup var globals: GlobalOptions

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

        let policies: [(name: String, policy: KeyPolicy)] = [
            ("open", .open),
            ("passcode", .passcode),
            ("biometric", .biometric),
        ]

        do {
            for (name, policy) in policies {
                // Create SE KeyAgreement key
                let keyResult = try manager.createKeyAgreementKey(policy: policy)
                createdKeys.append((policy: name, dataRep: keyResult.dataRepresentation))

                // Create integrity envelope (triggers access control for passcode/biometric)
                let envelope = try manager.createIntegrityEnvelope(
                    seKeyDataRepresentation: keyResult.dataRepresentation
                )

                let entry = VaultEntry(
                    vaultKeyId: "com.keypo.vault.\(name)",
                    dataRepresentation: keyResult.dataRepresentation.base64EncodedString(),
                    publicKey: SignatureFormatter.formatHex(keyResult.publicKey),
                    integrityEphemeralPublicKey: SignatureFormatter.formatHex(envelope.ephemeralPublicKey),
                    integrityHmac: envelope.hmac.base64EncodedString(),
                    createdAt: now
                )
                vaults[name] = entry
            }
        } catch let error as VaultError {
            // Clean up already-created SE keys on failure
            for created in createdKeys {
                manager.deleteKeyAgreementKey(dataRepresentation: created.dataRep)
            }
            if case .authenticationCancelled = error {
                writeStderr("authentication cancelled")
                throw ExitCode(4)
            }
            writeStderr("\(error)")
            throw ExitCode(3)
        } catch {
            // Clean up already-created SE keys on failure
            for created in createdKeys {
                manager.deleteKeyAgreementKey(dataRepresentation: created.dataRep)
            }
            writeStderr("vault initialization failed: \(error)")
            throw ExitCode(3)
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
        let output = VaultInitOutput(
            vaults: policies.map { VaultInitOutput.VaultInitEntry(vaultKeyId: "com.keypo.vault.\($0.name)", policy: $0.name) },
            createdAt: now
        )

        switch globals.format {
        case .json:
            try outputJSON(output)
        case .raw, .pretty:
            writeStdout("Vault initialized with 3 vaults: open, passcode, biometric\n")
        }
    }
}

import CryptoKit
