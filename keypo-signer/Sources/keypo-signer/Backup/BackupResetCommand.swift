import ArgumentParser
import Foundation
import KeypoCore
import CryptoKit
import LocalAuthentication

struct VaultBackupResetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "backup-reset",
        abstract: "Regenerate backup encryption key and passphrase"
    )

    @OptionGroup var globals: GlobalOptions

    mutating func run() throws {
        let store = makeVaultStore(globals)

        guard store.vaultExists() else {
            writeStderr("vault not initialized — nothing to back up")
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

        // 1. Delete old synced key
        try KeychainSync.deleteSyncedBackupKey()

        // 2. Generate new synced key
        let syncedKey = try BackupCrypto.secureRandom(count: 32)
        try KeychainSync.storeSyncedBackupKey(syncedKey)

        // 3. Offer passphrase choice
        writeStderrRaw("Choose a passphrase option:")
        writeStderrRaw("  [1] Generate a secure 4-word passphrase (recommended)")
        writeStderrRaw("  [2] Enter your own passphrase")
        writeStderrRaw("Choice [1/2]: ")

        let choice = readLine(strippingNewline: true) ?? "1"
        let passphrase: String

        if choice == "2" {
            while true {
                guard let input = readSecretFromTerminal(prompt: "Enter your passphrase: ") else {
                    writeStderr("failed to read passphrase")
                    throw ExitCode(1)
                }
                let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

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
            let words = PassphraseGenerator.generatePassphrase()
            writeStderrRaw("\nYour new backup passphrase:\n")
            writeStderrRaw("┌────────────────────────────────────────┐")
            writeStderrRaw("│  \(words.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "  "))  │")
            writeStderrRaw("└────────────────────────────────────────┘")
            writeStderrRaw("")

            let indices = PassphraseGenerator.confirmationIndices(wordCount: words.count, confirmCount: 2)
            for idx in indices {
                writeStderrRaw("Enter word #\(idx + 1): ")
                guard let input = readLine(strippingNewline: true),
                      input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == words[idx] else {
                    writeStderr("incorrect word — reset aborted")
                    throw ExitCode(1)
                }
            }

            passphrase = words.joined(separator: " ")
        }

        // Display passphrase confirmation and warning
        writeStderrRaw("")
        writeStderrRaw("╔══════════════════════════════════════════════════════════╗")
        writeStderrRaw("║  IMPORTANT: Write down your passphrase and store it     ║")
        writeStderrRaw("║  in a safe place. If you lose your passphrase, your     ║")
        writeStderrRaw("║  backup will be permanently inaccessible.               ║")
        writeStderrRaw("║                                                         ║")
        writeStderrRaw("║  Your passphrase: \(passphrase.padding(toLength: 39, withPad: " ", startingAt: 0))║")
        writeStderrRaw("║                                                         ║")
        writeStderrRaw("║  This passphrase will NOT be shown again.               ║")
        writeStderrRaw("╚══════════════════════════════════════════════════════════╝")
        writeStderrRaw("")

        // 4. Decrypt all vault secrets
        let payload = try decryptAllSecrets(vaultFile: vaultFile, manager: manager)

        // 5. Encrypt with new key
        let keys = try BackupCrypto.deriveBackupKey(syncedKey: syncedKey, passphrase: passphrase)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payloadData = try encoder.encode(payload)

        let (nonce, ciphertext, authTag) = try BackupCrypto.encrypt(plaintext: payloadData, key: keys.backupKey)

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

        // 6. Write to iCloud Drive (rotate existing)
        let iCloudDrive = iCloudDriveManager()
        let isFirstBackup = !iCloudDrive.backupExists()
        try iCloudDrive.writeBackup(blob, isFirstBackup: isFirstBackup)

        // 7. Warn about old backups
        writeStderrRaw("WARNING: Your previous passphrase and encryption key have been regenerated.")
        writeStderrRaw("All older backups are now permanently unrecoverable.")

        // 8. Reset backup state
        let stateManager = BackupStateManager(configDir: store.configDir)
        try stateManager.resetAfterBackup()

        // Output
        let output = VaultBackupResetOutput(
            reset: true,
            secretCount: secretCount,
            vaultNames: vaultNames,
            createdAt: blob.createdAt
        )

        switch globals.format {
        case .json:
            try outputJSON(output)
        case .raw, .pretty:
            writeStdout("Backup reset: \(secretCount) secrets re-encrypted with new key\n")
        }
    }

    // Reuses the same pattern as BackupCommand for decrypting all secrets
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

            var authContext: LAContext? = nil
            if policyName == "biometric" || policyName == "passcode" {
                do {
                    authContext = try SecureEnclaveManager.preAuthenticate(
                        reason: "keypo-vault: decrypt \(policyName) secrets for backup reset"
                    )
                } catch VaultError.authenticationCancelled {
                    writeStderr("authentication cancelled")
                    throw ExitCode(4)
                }
            }

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

struct VaultBackupResetOutput: Codable {
    let reset: Bool
    let secretCount: Int
    let vaultNames: [String]
    let createdAt: String
}
