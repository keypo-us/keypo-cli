import ArgumentParser
import Foundation
import KeypoCore
import CryptoKit
import LocalAuthentication

struct VaultRestoreCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore",
        abstract: "Restore vault secrets from an iCloud Drive backup",
        discussion: """
        Examples:
          keypo-signer vault restore
          keypo-signer vault restore --previous
        """
    )

    @OptionGroup var globals: GlobalOptions

    @Flag(name: .long, help: "Restore from the previous backup instead of the current one")
    var previous: Bool = false

    mutating func run() throws {
        let store = makeVaultStore(globals)

        // 1. iCloud pre-flight
        if !iCloudStatus.isSignedIntoICloud {
            writeStderr("Not signed into iCloud. Vault restore requires iCloud to access your encryption key and backup file.")
            writeStderr("Sign into iCloud in System Settings > Apple ID, then try again.")
            throw ExitCode(1)
        }
        if !iCloudStatus.isICloudDriveAvailable {
            writeStderr("iCloud Drive is not available. Enable iCloud Drive in System Settings > Apple ID > iCloud.")
            throw ExitCode(1)
        }

        // 2. Read synced key from iCloud Keychain
        guard let syncedKey = try KeychainSync.readSyncedBackupKey() else {
            writeStderr("Backup encryption key not found in iCloud Keychain.")
            writeStderr("Ensure iCloud Keychain sync is enabled and this device is signed into the same Apple ID.")
            throw ExitCode(1)
        }

        // 3. Read backup blob from iCloud Drive (single read — serves both decryption and diff)
        let iCloudDrive = iCloudDriveManager()
        guard let blob = try iCloudDrive.readBackup(previous: previous) else {
            writeStderr("Backup file not found in iCloud Drive.")
            writeStderr("Ensure iCloud Drive sync is enabled and the backup has finished syncing.")
            throw ExitCode(1)
        }

        // 4. If local vault exists, show notice before passphrase prompt
        let hasLocalVault = store.vaultExists()
        if hasLocalVault {
            writeStderrRaw("")
            writeStderrRaw("Note: existing local vault detected. After decryption, you'll see a detailed comparison.")
        }

        // 5. Prompt for passphrase, derive key, decrypt, parse
        writeStderrRaw("Tip: If you used a generated passphrase, enter all 4 words as a single string separated by spaces (e.g., \"word1 word2 word3 word4\").")
        guard let input = readSecretFromTerminal(prompt: "Enter your backup passphrase: ") else {
            writeStderr("failed to read passphrase")
            throw ExitCode(1)
        }
        let passphrase = input.trimmingCharacters(in: .whitespacesAndNewlines)

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

        guard let nonce = Data(base64Encoded: blob.nonce),
              let ciphertext = Data(base64Encoded: blob.ciphertext),
              let authTag = Data(base64Encoded: blob.authTag) else {
            writeStderr("corrupt encrypted data in backup")
            throw ExitCode(1)
        }

        writeStderrRaw("Decrypting backup...")

        let payloadData: Data
        do {
            payloadData = try BackupCrypto.decrypt(
                ciphertext: ciphertext, nonce: nonce, authTag: authTag, key: backupKey
            )
        } catch {
            writeStderr("Decryption failed. Check your passphrase and try again.")
            throw ExitCode(1)
        }

        let payload: BackupPayload
        do {
            payload = try JSONDecoder().decode(BackupPayload.self, from: payloadData)
        } catch {
            writeStderr("failed to parse backup payload: \(error)")
            throw ExitCode(1)
        }

        writeStderrRaw("Decryption successful.")

        // Mention --previous if a previous backup exists and we're restoring from current
        if !previous && iCloudDrive.backupExists(previous: true) {
            writeStderrRaw("Tip: A previous backup is also available via: vault restore --previous")
        }

        // 6. If local vault exists: compute diff, display, prompt
        if hasLocalVault {
            let localVault = try store.loadVaultFile()
            let localSecrets = try store.allSecretNames()
            let diff = computeRestoreDiff(localSecrets: localSecrets, backupPayload: payload)

            // JSON mode (non-interactive): output conflict and exit.
            // Only take this path when --format json AND not running in a terminal.
            // When stdin is a TTY, always show the interactive diff/prompt flow,
            // even if the default format is json.
            if globals.format == .json && isatty(STDIN_FILENO) == 0 {
                let output = VaultRestoreConflictOutput(
                    status: "conflict",
                    message: "Local vault exists. Re-run with --format pretty for interactive merge.",
                    localOnly: diff.localOnly,
                    backupOnly: diff.backupOnly,
                    inBoth: diff.inBoth
                )
                try outputJSON(output)
                throw ExitCode(2)
            }

            // Interactive mode: display diff and prompt
            displayDiff(diff, backupPayload: payload)

            let backupOnlyCount = diff.backupOnly.count
            let hasNonOpenBackupOnly = diff.backupOnly.contains { $0.policy != "open" }

            // Build choice menu
            writeStderrRaw("")
            let backupSecretCount = payload.vaults.reduce(0) { $0 + $1.secrets.count }
            writeStderrRaw("  [1] Cancel — keep local vault unchanged")
            writeStderrRaw("  [2] Replace — destroy local vault, restore all \(backupSecretCount) secrets from backup")

            if backupOnlyCount > 0 {
                let authHint = hasNonOpenBackupOnly ? " (may require authentication)" : ""
                writeStderrRaw("  [3] Merge — keep all local secrets, add \(backupOnlyCount) backup-only secret\(backupOnlyCount == 1 ? "" : "s")\(authHint)")
                writeStderrRaw("  [4] Back up first — save current vault before deciding")
                writeStderrRaw("")
                writeStderrRaw("Choice [1/2/3/4]: ")
            } else {
                writeStderrRaw("  [3] Back up first — save current vault before deciding")
                writeStderrRaw("")
                writeStderrRaw("Backup contains no secrets that aren't already in your local vault.")
                writeStderrRaw("Choice [1/2/3]: ")
            }

            let choice = readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespaces) ?? "1"

            if backupOnlyCount > 0 {
                // 4-choice menu: 1=cancel, 2=replace, 3=merge, 4=backup-first
                switch choice {
                case "2":
                    try performReplace(store: store, localVault: localVault)
                    // Fall through to full restore below
                case "3":
                    try performMerge(
                        store: store, localVault: localVault, diff: diff,
                        payload: payload
                    )
                    return
                case "4":
                    writeStderrRaw("Run 'keypo-signer vault backup' to save your current vault, then try restoring again.\n")
                    throw ExitCode.success
                default:
                    writeStderrRaw("Restore cancelled. Local vault unchanged.\n")
                    throw ExitCode.success
                }
            } else {
                // 3-choice menu: 1=cancel, 2=replace, 3=backup-first
                switch choice {
                case "2":
                    try performReplace(store: store, localVault: localVault)
                    // Fall through to full restore below
                case "3":
                    writeStderrRaw("Run 'keypo-signer vault backup' to save your current vault, then try restoring again.\n")
                    throw ExitCode.success
                default:
                    writeStderrRaw("Restore cancelled. Local vault unchanged.\n")
                    throw ExitCode.success
                }
            }
        }

        // 7. Full restore: create 3 SE keys, re-encrypt, save
        try performFullRestore(store: store, payload: payload)
    }

    // MARK: - Diff Display

    private func displayDiff(_ diff: RestoreDiff, backupPayload: BackupPayload) {
        writeStderrRaw("")
        writeStderrRaw("Comparing local vault with backup:")

        if !diff.localOnly.isEmpty {
            writeStderrRaw("")
            writeStderrRaw("  Only in local (will be lost if you replace):")
            displaySecretsByPolicy(diff.localOnly)
        }

        if !diff.backupOnly.isEmpty {
            writeStderrRaw("")
            writeStderrRaw("  Only in backup (not in local vault):")
            displaySecretsByPolicy(diff.backupOnly)
        }

        if !diff.inBoth.isEmpty {
            writeStderrRaw("")
            writeStderrRaw("  In both (local version kept):")
            displaySecretsByPolicy(diff.inBoth)
        }
    }

    private func displaySecretsByPolicy(_ refs: [SecretRef]) {
        let grouped = Dictionary(grouping: refs, by: { $0.policy })
        for policy in ["open", "passcode", "biometric"] {
            guard let entries = grouped[policy], !entries.isEmpty else { continue }
            let names = entries.map(\.name).joined(separator: ", ")
            writeStderrRaw("    \(policy): \(names)")
        }
    }

    // MARK: - Replace

    private func performReplace(store: any VaultStoring, localVault: VaultFile) throws {
        let manager = VaultManager()
        for (_, entry) in localVault.vaults {
            if let dataRep = Data(base64Encoded: entry.dataRepresentation) {
                manager.deleteKeyAgreementKey(dataRepresentation: dataRep)
            }
        }
        try store.deleteVaultFile()
        writeStderrRaw("Local vault destroyed. Continuing with restore...\n")
    }

    // MARK: - Full Restore

    private func performFullRestore(store: any VaultStoring, payload: BackupPayload) throws {
        let manager = VaultManager()
        let now = Date()
        var vaults: [String: VaultEntry] = [:]
        var createdKeys: [(policy: String, dataRep: Data)] = []

        let allPolicies: [(name: String, policy: KeyPolicy)] = [
            ("open", .open),
            ("passcode", .passcode),
            ("biometric", .biometric),
        ]

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
            for created in createdKeys {
                manager.deleteKeyAgreementKey(dataRepresentation: created.dataRep)
            }
            writeStderr("restore failed: \(error)")
            throw ExitCode(1)
        }

        let vaultFile = VaultFile(version: 2, vaults: vaults)
        do {
            try store.saveVaultFile(vaultFile)
        } catch {
            for created in createdKeys {
                manager.deleteKeyAgreementKey(dataRepresentation: created.dataRep)
            }
            writeStderr("failed to save vault: \(error)")
            throw ExitCode(1)
        }

        let stateManager = BackupStateManager(configDir: store.configDir)
        try stateManager.resetAfterBackup()

        let secretCount = payload.vaults.reduce(0) { $0 + $1.secrets.count }
        let vaultNames = payload.vaults.map(\.name)

        let output = VaultRestoreOutput(
            restored: true,
            secretCount: secretCount,
            vaultNames: vaultNames,
            restoredAt: ISO8601DateFormatter().string(from: now),
            fromPrevious: previous,
            action: "restore",
            mergedCount: nil
        )

        switch globals.format {
        case .json:
            try outputJSON(output)
        case .raw:
            writeStdout("Vault restored: \(secretCount) secrets from \(vaultNames.joined(separator: ", "))\n")
        case .pretty:
            writeStdout("Vault restored: \(secretCount) secrets from \(vaultNames.joined(separator: ", "))\n")
        }
    }

    // MARK: - Merge

    private func performMerge(
        store: any VaultStoring, localVault: VaultFile, diff: RestoreDiff,
        payload: BackupPayload
    ) throws {
        let manager = VaultManager()
        var vaultFile = localVault

        // Build lookup: backup secret name → (BackupSecret, policy name)
        var backupSecretLookup: [String: (secret: BackupSecret, policyName: String)] = [:]
        for vault in payload.vaults {
            for secret in vault.secrets {
                backupSecretLookup[secret.name] = (secret: secret, policyName: vault.name)
            }
        }

        // Group backup-only secrets by policy
        var backupOnlyByPolicy: [String: [BackupSecret]] = [:]
        for ref in diff.backupOnly {
            guard let lookup = backupSecretLookup[ref.name] else { continue }
            backupOnlyByPolicy[lookup.policyName, default: []].append(lookup.secret)
        }

        // Phase A — Verify HMACs for each policy that has backup-only secrets (may trigger auth)
        struct VerifiedPolicy {
            var entry: VaultEntry
            let dataRep: Data
            let publicKey: P256.KeyAgreement.PublicKey
            let authContext: LAContext
            let backupSecrets: [BackupSecret]
        }

        var verifiedPolicies: [String: VerifiedPolicy] = [:]

        for (policyName, backupSecrets) in backupOnlyByPolicy {
            guard let entry = vaultFile.vaults[policyName] else {
                writeStderrWarning("vault entry for '\(policyName)' is missing — skipping \(backupSecrets.count) secret(s). This may indicate vault corruption.")
                continue
            }

            guard let dataRep = Data(base64Encoded: entry.dataRepresentation) else {
                writeStderr("corrupt vault key reference for \(policyName)")
                throw ExitCode(1)
            }

            let secretDataMap = try buildSecretDataMap(from: entry.secrets)
            let integrityKey = try SignatureFormatter.parseHex(entry.integrityEphemeralPublicKey)
            guard let expectedHMAC = Data(base64Encoded: entry.integrityHmac) else {
                writeStderr("corrupt HMAC for \(policyName) vault")
                throw ExitCode(1)
            }

            // One LAContext per policy — different policies require independent authentication.
            // This deviates from architecture rule 9's "one per command" guidance. Necessary because
            // different policies (open/passcode/biometric) have different access control requirements
            // and a single LAContext cannot satisfy multiple policy types.
            let authContext = LAContext()

            let valid = try manager.verifyHMAC(
                secrets: secretDataMap,
                seKeyDataRepresentation: dataRep,
                integrityEphemeralPublicKey: integrityKey,
                expectedHMAC: expectedHMAC,
                authContext: authContext
            )
            guard valid else {
                writeStderr("vault integrity check failed for \(policyName). Merge aborted, vault unchanged.")
                throw ExitCode(1)
            }

            let publicKey = try P256.KeyAgreement.PublicKey(
                x963Representation: SignatureFormatter.parseHex(entry.publicKey)
            )

            verifiedPolicies[policyName] = VerifiedPolicy(
                entry: entry, dataRep: dataRep, publicKey: publicKey,
                authContext: authContext, backupSecrets: backupSecrets
            )
        }

        // Phase B — Mutate (LAContexts already authenticated, no further auth prompts)
        var addedSecrets: [SecretRef] = []

        do {
            for (policyName, verified) in verifiedPolicies {
                var entry = verified.entry

                for secret in verified.backupSecrets {
                    // encrypt() is public-key-only ECIES — no SE key load, no auth prompt
                    let plaintext = Data(secret.value.utf8)
                    let encrypted = try manager.encrypt(
                        plaintext: plaintext,
                        secretName: secret.name,
                        sePublicKey: verified.publicKey
                    )
                    entry.secrets[secret.name] = EncryptedSecret(from: encrypted)
                    addedSecrets.append(SecretRef(name: secret.name, policy: policyName))
                }

                // Recompute HMAC over the COMPLETE entry.secrets dict (all existing + newly added).
                // Critical: computing HMAC over only the new secrets would corrupt the integrity envelope.
                let fullSecretDataMap = try buildSecretDataMap(from: entry.secrets)
                let integrityKey = try SignatureFormatter.parseHex(entry.integrityEphemeralPublicKey)
                let hmac = try manager.computeHMAC(
                    secrets: fullSecretDataMap,
                    seKeyDataRepresentation: verified.dataRep,
                    integrityEphemeralPublicKey: integrityKey,
                    authContext: verified.authContext
                )
                entry.integrityHmac = hmac.base64EncodedString()

                vaultFile.vaults[policyName] = entry
            }

            try store.saveVaultFile(vaultFile)

            // Increment backup nudge counter
            let stateManager = BackupStateManager(configDir: store.configDir)
            try stateManager.incrementAndNudge(count: addedSecrets.count)
        } catch VaultError.authenticationCancelled {
            writeStderr("Authentication expired during merge. Your vault is unchanged. Please try again.")
            throw ExitCode(1)
        } catch {
            writeStderr("Merge failed: \(error). Your vault is unchanged.")
            throw ExitCode(1)
        }

        // Output
        let totalSecrets = vaultFile.vaults.values.reduce(0) { $0 + $1.secrets.count }
        let addedNames = addedSecrets.map { ref in
            "\(ref.policy): \(ref.name)"
        }.joined(separator: ", ")

        let output = VaultRestoreOutput(
            restored: true,
            secretCount: totalSecrets,
            vaultNames: Array(vaultFile.vaults.keys.sorted()),
            restoredAt: ISO8601DateFormatter().string(from: Date()),
            fromPrevious: previous,
            action: "merge",
            mergedCount: addedSecrets.count
        )

        switch globals.format {
        case .json:
            try outputJSON(output)
        case .raw:
            writeStdout("Merge complete: added \(addedSecrets.count) secret\(addedSecrets.count == 1 ? "" : "s") from backup (\(addedNames)).\n")
            writeStdout("Local vault now has \(totalSecrets) secrets.\n")
        case .pretty:
            writeStdout("Merge complete: added \(addedSecrets.count) secret\(addedSecrets.count == 1 ? "" : "s") from backup (\(addedNames)).\n")
            writeStdout("Local vault now has \(totalSecrets) secrets.\n")
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
    let action: String       // "restore", "replace", or "merge"
    let mergedCount: Int?    // only set for "merge" action
}

struct VaultRestoreConflictOutput: Codable {
    let status: String          // "conflict"
    let message: String
    let localOnly: [SecretRef]
    let backupOnly: [SecretRef]
    let inBoth: [SecretRef]
}
