import ArgumentParser
import Foundation
import KeypoCore
import CryptoKit
import LocalAuthentication

struct VaultBackupCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "backup",
        abstract: "Encrypt and back up vault secrets to iCloud Drive",
        discussion: """
        Examples:
          keypo-signer vault backup
        """
    )

    @OptionGroup var globals: GlobalOptions

    mutating func run() throws {
        let store = makeVaultStore(globals)

        guard store.vaultExists() else {
            writeStderr("vault not initialized")
            throw ExitCode(1)
        }

        // Pre-flight: check iCloud availability
        if !iCloudStatus.isSignedIntoICloud {
            writeStderr("Not signed into iCloud. Vault backup requires iCloud to sync your encryption key and backup file across devices.")
            writeStderr("Sign into iCloud in System Settings > Apple ID, then try again.")
            throw ExitCode(1)
        }
        if !iCloudStatus.isICloudDriveAvailable {
            writeStderr("iCloud Drive is not available. Enable iCloud Drive in System Settings > Apple ID > iCloud.")
            throw ExitCode(1)
        }

        let manager = VaultManager()
        let vaultFile = try store.loadVaultFile()

        // Check for existing synced key
        let existingSyncedKey = try KeychainSync.readSyncedBackupKey()
        let iCloudDrive = iCloudDriveManager()
        let backupFileExists = iCloudDrive.backupExists()

        let syncedKey: Data
        let passphrase: String
        let isFirstBackup: Bool

        if let existing = existingSyncedKey {
            // Subsequent backup — prompt for existing passphrase
            syncedKey = existing
            isFirstBackup = false

            // Show metadata comparison + rotation notice if a backup already exists
            if let existingBlob = try? iCloudDrive.readBackup() {
                let localSecrets = (try? store.allSecretNames()) ?? []
                let localCount = localSecrets.count
                let localPolicies = Array(Set(localSecrets.map { $0.policy.rawValue })).sorted()

                writeStderrRaw("Current backup: \(existingBlob.secretCount) secret\(existingBlob.secretCount == 1 ? "" : "s") in [\(existingBlob.vaultNames.joined(separator: ", "))] from \(existingBlob.createdAt)")
                writeStderrRaw("Local vault:    \(localCount) secret\(localCount == 1 ? "" : "s") in [\(localPolicies.joined(separator: ", "))]")
                writeStderrRaw("")
                writeStderrRaw("This will replace your current backup. The old backup moves to the \"previous\" slot")
                writeStderrRaw("and can be recovered with: vault restore --previous")
                writeStderrRaw("")
            }

            writeStderrRaw("Tip: If you used a generated passphrase, enter all 4 words separated by spaces.")
            guard let input = readSecretFromTerminal(prompt: "Enter your backup passphrase: ") else {
                writeStderr("failed to read passphrase")
                throw ExitCode(1)
            }
            passphrase = input.trimmingCharacters(in: .whitespacesAndNewlines)

        } else if backupFileExists {
            // Synced key missing but backup exists — warn about data loss
            writeStderrRaw("WARNING: Your iCloud Keychain backup encryption key is missing.")
            writeStderrRaw("Creating a new backup will make your previous backup permanently unrecoverable.")
            writeStderrRaw("Continue? [y/N]: ")

            guard let answer = readLine(strippingNewline: true),
                  answer.lowercased() == "y" else {
                writeStderr("aborted")
                throw ExitCode(1)
            }

            // Generate new synced key and passphrase
            let result = try generateNewKeyAndPassphrase()
            syncedKey = result.syncedKey
            passphrase = result.passphrase
            isFirstBackup = false  // File exists, so rotation still applies

        } else {
            // First backup — generate everything new
            let result = try generateNewKeyAndPassphrase()
            syncedKey = result.syncedKey
            passphrase = result.passphrase
            isFirstBackup = true
        }

        // Decrypt all vault secrets
        let payload = try decryptAllSecrets(vaultFile: vaultFile, manager: manager)

        // Derive backup key and encrypt
        let keys = try BackupCrypto.deriveBackupKey(syncedKey: syncedKey, passphrase: passphrase)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payloadData = try encoder.encode(payload)

        let (nonce, ciphertext, authTag) = try BackupCrypto.encrypt(plaintext: payloadData, key: keys.backupKey)

        // Count secrets
        let secretCount = payload.vaults.reduce(0) { $0 + $1.secrets.count }
        let vaultNames = payload.vaults.map(\.name)

        let formatter = ISO8601DateFormatter()
        let blob = BackupBlob(
            version: 1,
            createdAt: formatter.string(from: Date()),
            deviceName: Host.current().localizedName ?? "unknown",
            argon2Salt: keys.argon2Salt.base64EncodedString(),
            hkdfSalt: keys.hkdfSalt.base64EncodedString(),
            nonce: nonce.base64EncodedString(),
            ciphertext: ciphertext.base64EncodedString(),
            authTag: authTag.base64EncodedString(),
            secretCount: secretCount,
            vaultNames: vaultNames
        )

        // Write to iCloud Drive
        try iCloudDrive.writeBackup(blob, isFirstBackup: isFirstBackup)

        // Reset backup state
        let stateManager = BackupStateManager(configDir: store.configDir)
        try stateManager.resetAfterBackup()

        // Output
        let output = VaultBackupOutput(
            backedUp: true,
            secretCount: secretCount,
            vaultNames: vaultNames,
            createdAt: blob.createdAt,
            deviceName: blob.deviceName
        )

        switch globals.format {
        case .json:
            try outputJSON(output)
        case .raw, .pretty:
            writeStdout("Vault backed up: \(secretCount) secrets from \(vaultNames.joined(separator: ", "))\n")
        }
    }

    // MARK: - Private

    private func generateNewKeyAndPassphrase() throws -> (syncedKey: Data, passphrase: String) {
        // Generate and store synced key
        let syncedKey = try BackupCrypto.secureRandom(count: 32)
        try KeychainSync.storeSyncedBackupKey(syncedKey)

        // Offer passphrase choice
        writeStderrRaw("Choose a passphrase option:")
        writeStderrRaw("  [1] Generate a secure 4-word passphrase (recommended)")
        writeStderrRaw("  [2] Enter your own passphrase")
        writeStderrRaw("Choice [1/2]: ")

        let choice = readLine(strippingNewline: true) ?? "1"

        let passphrase: String

        if choice == "2" {
            // Custom passphrase with retry loop
            while true {
                guard let input = readSecretFromTerminal(prompt: "Enter your passphrase: ") else {
                    writeStderr("failed to read passphrase")
                    throw ExitCode(1)
                }
                let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

                // Show strength indicator
                let strength = PassphraseStrengthEvaluator.evaluate(trimmed)
                writeStderrRaw(PassphraseStrengthEvaluator.formatBar(strength))

                if strength.level == .weak || strength.level == .fair {
                    let warning = strength.level == .weak ? "weak" : "fair"
                    writeStderrRaw("WARNING: This passphrase is \(warning). A stronger passphrase is recommended.")
                    writeStderrRaw("  [1] Continue with this passphrase")
                    writeStderrRaw("  [2] Try a different passphrase")
                    writeStderrRaw("Choice [1/2]: ")
                    let confirm = readLine(strippingNewline: true) ?? "2"
                    if confirm == "2" { continue }
                }

                // Verify by re-entering
                guard let verify = readSecretFromTerminal(prompt: "Re-enter your passphrase: ") else {
                    writeStderr("failed to read passphrase")
                    throw ExitCode(1)
                }
                guard verify.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else {
                    writeStderrRaw("Passphrases do not match. Try again.")
                    continue
                }

                passphrase = trimmed
                break
            }
        } else {
            // Generated passphrase
            let words = PassphraseGenerator.generatePassphrase()
            writeStderrRaw("\nYour backup passphrase:\n")
            writeStderrRaw("┌────────────────────────────────────────┐")
            writeStderrRaw("│  \(words.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "  "))  │")
            writeStderrRaw("└────────────────────────────────────────┘")
            writeStderrRaw("")

            // Confirm 2 random words
            let indices = PassphraseGenerator.confirmationIndices(wordCount: words.count, confirmCount: 2)
            for idx in indices {
                writeStderrRaw("Enter word #\(idx + 1): ")
                guard let input = readLine(strippingNewline: true),
                      input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == words[idx] else {
                    writeStderr("incorrect word — backup aborted")
                    throw ExitCode(1)
                }
            }

            passphrase = words.joined(separator: " ")
        }

        // Display passphrase confirmation and warning
        writeStderrRaw("")
        writeStderrRaw("╔══════════════════════════════════════════════════════════╗")
        writeStderrRaw("║  IMPORTANT: Save your passphrase. If you lose it,       ║")
        writeStderrRaw("║  your backup will be permanently inaccessible.          ║")
        writeStderrRaw("║                                                         ║")
        writeStderrRaw("║  Your passphrase: \(passphrase.padding(toLength: 39, withPad: " ", startingAt: 0))║")
        writeStderrRaw("║                                                         ║")
        writeStderrRaw("║  Back it up at: https://www.keypo.io/app                ║")
        writeStderrRaw("║  Or write it down and store it in a safe place.         ║")
        writeStderrRaw("║                                                         ║")
        writeStderrRaw("║  This passphrase will NOT be shown again.               ║")
        writeStderrRaw("╚══════════════════════════════════════════════════════════╝")
        writeStderrRaw("")

        return (syncedKey: syncedKey, passphrase: passphrase)
    }

    private func decryptAllSecrets(vaultFile: VaultFile, manager: VaultManager) throws -> BackupPayload {
        let formatter = ISO8601DateFormatter()
        var backupVaults: [BackupVault] = []

        for policyName in ["open", "passcode", "biometric"] {
            guard let entry = vaultFile.vaults[policyName] else { continue }
            guard !entry.secrets.isEmpty else { continue }

            guard let dataRep = Data(base64Encoded: entry.dataRepresentation) else {
                writeStderr("corrupt vault key reference for \(policyName)")
                throw ExitCode(1)
            }

            // Pre-authenticate for passcode/biometric
            var authContext: LAContext? = nil
            if policyName == "biometric" || policyName == "passcode" {
                do {
                    authContext = try SecureEnclaveManager.preAuthenticate(
                        reason: "keypo-vault: decrypt \(policyName) secrets for backup",
                        keyPolicy: KeyPolicy(rawValue: policyName) ?? .open
                    )
                } catch VaultError.authenticationCancelled {
                    writeStderr("authentication cancelled")
                    throw ExitCode(4)
                }
            }

            // Verify HMAC
            let integrityKey = try SignatureFormatter.parseHex(entry.integrityEphemeralPublicKey)
            guard let expectedHMAC = Data(base64Encoded: entry.integrityHmac) else {
                writeStderr("corrupt HMAC for \(policyName) vault")
                throw ExitCode(1)
            }
            let secretDataMap = try buildSecretDataMap(from: entry.secrets)
            let valid = try manager.verifyHMAC(
                secrets: secretDataMap,
                seKeyDataRepresentation: dataRep,
                integrityEphemeralPublicKey: integrityKey,
                expectedHMAC: expectedHMAC,
                authContext: authContext
            )
            guard valid else {
                writeStderr("vault integrity check failed for \(policyName)")
                throw ExitCode(1)
            }

            // Decrypt each secret
            var backupSecrets: [BackupSecret] = []
            for (name, secret) in entry.secrets.sorted(by: { $0.key < $1.key }) {
                let encData = try secret.toEncryptedSecretData()
                let plaintext = try manager.decrypt(
                    encryptedData: encData,
                    secretName: name,
                    seKeyDataRepresentation: dataRep,
                    authContext: authContext
                )
                guard let value = String(data: plaintext, encoding: .utf8) else {
                    writeStderr("decrypted value for '\(name)' is not valid UTF-8")
                    throw ExitCode(1)
                }
                backupSecrets.append(BackupSecret(
                    name: name,
                    value: value,
                    policy: policyName,
                    createdAt: formatter.string(from: secret.createdAt),
                    updatedAt: formatter.string(from: secret.updatedAt)
                ))
            }

            backupVaults.append(BackupVault(name: policyName, secrets: backupSecrets))
        }

        return BackupPayload(vaults: backupVaults)
    }
}

// MARK: - Output

struct VaultBackupOutput: Codable {
    let backedUp: Bool
    let secretCount: Int
    let vaultNames: [String]
    let createdAt: String
    let deviceName: String
}
