import ArgumentParser
import Foundation
import KeypoCore
import CryptoKit
import LocalAuthentication

struct VaultRestoreCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore",
        abstract: "Restore vault secrets from an iCloud Drive backup"
    )

    @OptionGroup var globals: GlobalOptions

    @Flag(name: .long, help: "Restore from the previous backup instead of the current one")
    var previous: Bool = false

    mutating func run() throws {
        let store = makeVaultStore(globals)

        // 1. Check for existing local vault
        if store.vaultExists() {
            writeStderr("Existing local vault detected. Destroy it first with 'vault destroy' before restoring.")
            throw ExitCode(1)
        }

        // 2. Read synced key from iCloud Keychain
        guard let syncedKey = try KeychainSync.readSyncedBackupKey() else {
            writeStderr("Backup encryption key not found in iCloud Keychain.")
            writeStderr("Ensure iCloud Keychain sync is enabled and this device is signed into the same Apple ID.")
            throw ExitCode(1)
        }

        // 3. Read backup blob from iCloud Drive
        let iCloudDrive = iCloudDriveManager()
        guard let blob = try iCloudDrive.readBackup(previous: previous) else {
            writeStderr("Backup file not found in iCloud Drive.")
            writeStderr("Ensure iCloud Drive sync is enabled and the backup has finished syncing.")
            throw ExitCode(1)
        }

        // 4. Prompt for passphrase
        guard let input = readSecretFromTerminal(prompt: "Enter your backup passphrase: ") else {
            writeStderr("failed to read passphrase")
            throw ExitCode(1)
        }
        let passphrase = input.trimmingCharacters(in: .whitespacesAndNewlines)

        // 5. Derive backup key from synced key + passphrase + salts from blob
        guard let argon2Salt = Data(base64Encoded: blob.argon2Salt),
              let hkdfSalt = Data(base64Encoded: blob.hkdfSalt) else {
            writeStderr("corrupt salt data in backup")
            throw ExitCode(1)
        }

        let backupKey = try BackupCrypto.deriveBackupKey(
            syncedKey: syncedKey,
            passphrase: passphrase,
            argon2Salt: argon2Salt,
            hkdfSalt: hkdfSalt
        )

        // 6. Decrypt ciphertext
        guard let nonce = Data(base64Encoded: blob.nonce),
              let ciphertext = Data(base64Encoded: blob.ciphertext),
              let authTag = Data(base64Encoded: blob.authTag) else {
            writeStderr("corrupt encrypted data in backup")
            throw ExitCode(1)
        }

        let payloadData: Data
        do {
            payloadData = try BackupCrypto.decrypt(
                ciphertext: ciphertext, nonce: nonce, authTag: authTag, key: backupKey
            )
        } catch {
            writeStderr("Decryption failed. Check your passphrase and try again.")
            throw ExitCode(1)
        }

        // 7. Parse payload
        let payload: BackupPayload
        do {
            payload = try JSONDecoder().decode(BackupPayload.self, from: payloadData)
        } catch {
            writeStderr("failed to parse backup payload: \(error)")
            throw ExitCode(1)
        }

        // 8. Create new SE keys and re-encrypt secrets
        let manager = VaultManager()
        let now = Date()
        var vaults: [String: VaultEntry] = [:]
        var createdKeys: [(policy: String, dataRep: Data)] = []

        // Determine which policies we need SE keys for
        let allPolicies: [(name: String, policy: KeyPolicy)] = [
            ("open", .open),
            ("passcode", .passcode),
            ("biometric", .biometric),
        ]

        // Create SE keys for all 3 policies (matching vault init)
        do {
            for (name, policy) in allPolicies {
                let keyResult = try manager.createKeyAgreementKey(policy: policy)
                createdKeys.append((policy: name, dataRep: keyResult.dataRepresentation))

                let envelope = try manager.createIntegrityEnvelope(
                    seKeyDataRepresentation: keyResult.dataRepresentation
                )

                var entry = VaultEntry(
                    vaultKeyId: "com.keypo.vault.\(name)",
                    dataRepresentation: keyResult.dataRepresentation.base64EncodedString(),
                    publicKey: SignatureFormatter.formatHex(keyResult.publicKey),
                    integrityEphemeralPublicKey: SignatureFormatter.formatHex(envelope.ephemeralPublicKey),
                    integrityHmac: envelope.hmac.base64EncodedString(),
                    createdAt: now
                )

                // Re-encrypt secrets that belong to this policy
                let publicKey = try P256.KeyAgreement.PublicKey(x963Representation: keyResult.publicKey)

                if let backupVault = payload.vaults.first(where: { $0.name == name }) {
                    for secret in backupVault.secrets {
                        let plaintext = Data(secret.value.utf8)
                        let encrypted = try manager.encrypt(
                            plaintext: plaintext,
                            secretName: secret.name,
                            sePublicKey: publicKey
                        )
                        entry.secrets[secret.name] = EncryptedSecret(from: encrypted)
                    }
                }

                // Recompute HMAC with all secrets
                if !entry.secrets.isEmpty {
                    let secretDataMap = try buildSecretDataMap(from: entry.secrets)
                    let integrityKey = try SignatureFormatter.parseHex(entry.integrityEphemeralPublicKey)
                    let hmac = try manager.computeHMAC(
                        secrets: secretDataMap,
                        seKeyDataRepresentation: keyResult.dataRepresentation,
                        integrityEphemeralPublicKey: integrityKey
                    )
                    entry.integrityHmac = hmac.base64EncodedString()
                }

                vaults[name] = entry
            }
        } catch {
            // Clean up SE keys on failure
            for created in createdKeys {
                manager.deleteKeyAgreementKey(dataRepresentation: created.dataRep)
            }
            writeStderr("restore failed: \(error)")
            throw ExitCode(1)
        }

        // 9. Save vault
        let vaultFile = VaultFile(version: 2, vaults: vaults)
        do {
            try store.saveVaultFile(vaultFile)
        } catch {
            for created in createdKeys {
                manager.deleteKeyAgreementKey(dataRepresentation: created.dataRep)
            }
            writeStderr("failed to write vault.json: \(error)")
            throw ExitCode(1)
        }

        // 10. Initialize backup state
        let stateManager = BackupStateManager(configDir: store.configDir)
        try stateManager.resetAfterBackup()

        // Output
        let secretCount = payload.vaults.reduce(0) { $0 + $1.secrets.count }
        let vaultNames = payload.vaults.map(\.name)

        let output = VaultRestoreOutput(
            restored: true,
            secretCount: secretCount,
            vaultNames: vaultNames,
            restoredAt: ISO8601DateFormatter().string(from: now),
            fromPrevious: previous
        )

        switch globals.format {
        case .json:
            try outputJSON(output)
        case .raw, .pretty:
            writeStdout("Vault restored: \(secretCount) secrets from \(vaultNames.joined(separator: ", "))\n")
        }
    }
}

// MARK: - Output

struct VaultRestoreOutput: Codable {
    let restored: Bool
    let secretCount: Int
    let vaultNames: [String]
    let restoredAt: String
    let fromPrevious: Bool
}
