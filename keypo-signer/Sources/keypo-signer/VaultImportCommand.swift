import ArgumentParser
import Foundation
import KeypoCore
import CryptoKit
import LocalAuthentication

struct VaultImportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Bulk-import secrets from a .env file",
        discussion: """
        Examples:
          keypo-signer vault import .env --vault open
          keypo-signer vault import .env.production --vault biometric --dry-run
        """
    )

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Path to .env file")
    var file: String

    @Option(name: .long, help: "Target vault: biometric, passcode, or open (default: highest available)")
    var vault: KeyPolicy?

    @Flag(name: .customLong("dry-run"), help: "Preview without importing")
    var dryRun: Bool = false

    mutating func run() throws {
        let store = makeVaultStore(globals)

        guard store.vaultExists() else {
            writeStderr("vault not initialized")
            throw ExitCode(1)
        }

        // Parse .env file
        let entries: [EnvFileParser.Entry]
        do {
            entries = try EnvFileParser.parseEntries(from: file)
        } catch {
            writeStderr("failed to parse .env file: \(error)")
            throw ExitCode(2)
        }

        // Validate all secret names
        for entry in entries {
            guard validateSecretName(entry.key) else {
                writeStderr("invalid secret name: '\(entry.key)'")
                throw ExitCode(4)
            }
        }

        // Dry run: just show what would be imported
        if dryRun {
            var imported: [VaultImportOutput.VaultImportEntry] = []
            var skipped: [VaultImportOutput.VaultImportSkip] = []

            for entry in entries {
                do {
                    if try store.isNameGloballyUnique(entry.key) {
                        imported.append(VaultImportOutput.VaultImportEntry(name: entry.key, action: "created"))
                    } else {
                        skipped.append(VaultImportOutput.VaultImportSkip(name: entry.key, reason: "already exists"))
                    }
                } catch {
                    skipped.append(VaultImportOutput.VaultImportSkip(name: entry.key, reason: "lookup error"))
                }
            }

            let output = VaultImportOutput(vault: (vault ?? .open).rawValue, imported: imported, skipped: skipped)
            switch globals.format {
            case .json:
                try outputJSON(output)
            case .raw, .pretty:
                writeStdout("Dry run: would import \(imported.count), skip \(skipped.count)\n")
                for e in imported { writeStdout("  + \(e.name)\n") }
                for s in skipped { writeStdout("  ~ \(s.name) (\(s.reason))\n") }
            }
            return
        }

        // Load vault file
        var vaultFile: VaultFile
        do {
            vaultFile = try store.loadVaultFile()
        } catch {
            writeStderr("failed to load vault: \(error)")
            throw ExitCode(1)
        }

        guard let resolvedPolicy = vault ?? vaultFile.highestAvailableTier() else {
            writeStderr("vault has no tiers available. Run: keypo-signer vault init")
            throw ExitCode(1)
        }
        let policyName = resolvedPolicy.rawValue
        guard var vaultEntry = vaultFile.vaults[policyName] else {
            let available = vaultFile.vaults.keys.sorted().joined(separator: ", ")
            writeStderr("vault '\(policyName)' is not available. Available: \(available)")
            throw ExitCode(1)
        }

        let manager = VaultManager()

        guard let dataRep = Data(base64Encoded: vaultEntry.dataRepresentation) else {
            writeStderr("corrupt vault key reference")
            throw ExitCode(6)
        }

        // Share a single LAContext so the user only authenticates once
        let authContext = LAContext()

        // Verify HMAC (triggers access control)
        do {
            let integrityKey = try SignatureFormatter.parseHex(vaultEntry.integrityEphemeralPublicKey)
            guard let expectedHMAC = Data(base64Encoded: vaultEntry.integrityHmac) else {
                writeStderr("corrupt HMAC")
                throw ExitCode(6)
            }
            let secretDataMap = try buildSecretDataMap(from: vaultEntry.secrets)
            let valid = try manager.verifyHMAC(
                secrets: secretDataMap,
                seKeyDataRepresentation: dataRep,
                integrityEphemeralPublicKey: integrityKey,
                expectedHMAC: expectedHMAC,
                authContext: authContext
            )
            guard valid else {
                writeStderr("vault integrity check failed")
                throw ExitCode(6)
            }
        } catch VaultError.authenticationCancelled {
            writeStderr("authentication cancelled")
            throw ExitCode(5)
        } catch let e as VaultError {
            writeStderr("\(e)")
            throw ExitCode(6)
        }

        // Get SE public key for encryption
        let publicKey: P256.KeyAgreement.PublicKey
        do {
            let pubKeyData = try SignatureFormatter.parseHex(vaultEntry.publicKey)
            publicKey = try P256.KeyAgreement.PublicKey(x963Representation: pubKeyData)
        } catch {
            writeStderr("corrupt vault public key: \(error)")
            throw ExitCode(6)
        }

        // Import each entry
        var imported: [VaultImportOutput.VaultImportEntry] = []
        var skipped: [VaultImportOutput.VaultImportSkip] = []

        for entry in entries {
            // Check global uniqueness across ALL vaults
            var isUnique = true
            for (_, v) in vaultFile.vaults {
                if v.secrets[entry.key] != nil {
                    isUnique = false
                    break
                }
            }
            // Also check secrets we've already added in this import
            if vaultEntry.secrets[entry.key] != nil {
                isUnique = false
            }

            if !isUnique {
                skipped.append(VaultImportOutput.VaultImportSkip(name: entry.key, reason: "already exists"))
                continue
            }

            if entry.value.isEmpty {
                skipped.append(VaultImportOutput.VaultImportSkip(name: entry.key, reason: "empty value"))
                continue
            }

            let plaintext = Data(entry.value.utf8)
            do {
                let encrypted = try manager.encrypt(plaintext: plaintext, secretName: entry.key, sePublicKey: publicKey)
                vaultEntry.secrets[entry.key] = EncryptedSecret(from: encrypted)
                imported.append(VaultImportOutput.VaultImportEntry(name: entry.key, action: "created"))
            } catch {
                writeStderr("failed to encrypt '\(entry.key)': \(error)")
                throw ExitCode(6)
            }
        }

        // Recompute HMAC
        do {
            let integrityKey = try SignatureFormatter.parseHex(vaultEntry.integrityEphemeralPublicKey)
            let secretDataMap = try buildSecretDataMap(from: vaultEntry.secrets)
            let newHMAC = try manager.computeHMAC(
                secrets: secretDataMap,
                seKeyDataRepresentation: dataRep,
                integrityEphemeralPublicKey: integrityKey,
                authContext: authContext
            )
            vaultEntry.integrityHmac = newHMAC.base64EncodedString()
        } catch {
            writeStderr("HMAC recomputation failed: \(error)")
            throw ExitCode(6)
        }

        vaultFile.vaults[policyName] = vaultEntry
        do {
            try store.saveVaultFile(vaultFile)
        } catch {
            writeStderr("failed to write vault: \(error)")
            throw ExitCode(6)
        }

        // Backup nudge
        if !imported.isEmpty {
            let stateManager = BackupStateManager(configDir: store.configDir)
            try? stateManager.incrementAndNudge(count: imported.count)
        }

        // Output
        let output = VaultImportOutput(vault: policyName, imported: imported, skipped: skipped)
        switch globals.format {
        case .json:
            try outputJSON(output)
        case .raw, .pretty:
            writeStdout("Imported \(imported.count) secret(s), skipped \(skipped.count)\n")
            for e in imported { writeStdout("  + \(e.name)\n") }
            for s in skipped { writeStdout("  ~ \(s.name) (\(s.reason))\n") }
            writeStderrRaw("Reminder: delete or move the original .env file. Secrets are now in the vault.")
        }
    }
}
