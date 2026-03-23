import ArgumentParser
import Foundation
import KeypoCore
import CryptoKit
import LocalAuthentication

struct VaultSetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Store an encrypted secret in a vault"
    )

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Secret name (environment variable convention)")
    var name: String

    @Option(name: .long, help: "Target vault: biometric, passcode, or open (default: highest available)")
    var vault: KeyPolicy?

    @Flag(name: .customLong("stdin"), help: "Read secret value from stdin")
    var fromStdin: Bool = false

    mutating func run() throws {
        // Validate name
        guard validateSecretName(name) else {
            writeStderr("invalid secret name: must match [A-Za-z_][A-Za-z0-9_]{0,127}")
            throw ExitCode(2)
        }

        let store = makeVaultStore(globals)

        // Check vault initialized
        guard store.vaultExists() else {
            writeStderr("vault not initialized (run 'vault init' first)")
            throw ExitCode(1)
        }

        // Check global uniqueness
        do {
            guard try store.isNameGloballyUnique(name) else {
                writeStderr("secret '\(name)' already exists (use 'vault update' to change)")
                throw ExitCode(3)
            }
        } catch let e as VaultError {
            writeStderr("\(e)")
            throw ExitCode(1)
        }

        // Read value
        let value: String
        if fromStdin {
            guard let v = readSecretFromStdin(), !v.isEmpty else {
                writeStderr("empty secret value")
                throw ExitCode(5)
            }
            value = v
        } else {
            guard let v = readSecretFromTerminal(prompt: "Enter secret value: "), !v.isEmpty else {
                writeStderr("empty secret value")
                throw ExitCode(5)
            }
            value = v
        }

        // Load vault and perform operations
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
        guard var entry = vaultFile.vaults[policyName] else {
            let available = vaultFile.vaults.keys.sorted().joined(separator: ", ")
            writeStderr("vault '\(policyName)' is not available. Available: \(available)")
            throw ExitCode(1)
        }

        let manager = VaultManager()

        // Load SE key data
        guard let dataRep = Data(base64Encoded: entry.dataRepresentation) else {
            writeStderr("corrupt vault key reference")
            throw ExitCode(4)
        }

        // Share a single LAContext so the user only authenticates once
        let authContext = LAContext()

        // Verify HMAC first
        do {
            let integrityKey = try SignatureFormatter.parseHex(entry.integrityEphemeralPublicKey)
            guard let expectedHMAC = Data(base64Encoded: entry.integrityHmac) else {
                writeStderr("corrupt HMAC")
                throw ExitCode(6)
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
                writeStderr("vault integrity check failed")
                throw ExitCode(6)
            }
        } catch VaultError.authenticationCancelled {
            writeStderr("authentication cancelled")
            throw ExitCode(7)
        } catch let e as VaultError {
            writeStderr("\(e)")
            throw ExitCode(6)
        }

        // Encrypt
        let plaintext = Data(value.utf8)
        let publicKey: P256.KeyAgreement.PublicKey
        do {
            let pubKeyData = try SignatureFormatter.parseHex(entry.publicKey)
            publicKey = try P256.KeyAgreement.PublicKey(x963Representation: pubKeyData)
        } catch {
            writeStderr("corrupt vault public key: \(error)")
            throw ExitCode(4)
        }

        let encrypted: EncryptedSecretData
        do {
            encrypted = try manager.encrypt(plaintext: plaintext, secretName: name, sePublicKey: publicKey)
        } catch {
            writeStderr("encryption failed: \(error)")
            throw ExitCode(4)
        }

        // Store
        entry.secrets[name] = EncryptedSecret(from: encrypted)

        // Recompute HMAC
        do {
            let integrityKey = try SignatureFormatter.parseHex(entry.integrityEphemeralPublicKey)
            let secretDataMap = try buildSecretDataMap(from: entry.secrets)
            let newHMAC = try manager.computeHMAC(
                secrets: secretDataMap,
                seKeyDataRepresentation: dataRep,
                integrityEphemeralPublicKey: integrityKey,
                authContext: authContext
            )
            entry.integrityHmac = newHMAC.base64EncodedString()
        } catch {
            writeStderr("HMAC recomputation failed: \(error)")
            throw ExitCode(4)
        }

        vaultFile.vaults[policyName] = entry
        do {
            try store.saveVaultFile(vaultFile)
        } catch {
            writeStderr("failed to write vault: \(error)")
            throw ExitCode(4)
        }

        // Backup nudge
        let stateManager = BackupStateManager(configDir: store.configDir)
        try? stateManager.incrementAndNudge()

        // Output
        let output = VaultSetOutput(name: name, vault: policyName, createdAt: encrypted.createdAt)
        switch globals.format {
        case .json:
            try outputJSON(output)
        case .raw:
            writeStdout(name)
        case .pretty:
            writeStdout("Secret '\(name)' stored in \(policyName) vault\n")
        }
    }
}
