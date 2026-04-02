import ArgumentParser
import Foundation
import KeypoCore
import CryptoKit
import LocalAuthentication

struct VaultUpdateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update an existing secret's value",
        discussion: """
        Examples:
          echo -n "new_value" | keypo-signer vault update API_KEY --stdin
          keypo-signer vault update API_KEY
        """
    )

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Secret name")
    var name: String

    @Flag(name: .customLong("stdin"), help: "Read new secret value from stdin")
    var fromStdin: Bool = false

    mutating func run() throws {
        let store = makeVaultStore(globals)

        guard store.vaultExists() else {
            writeStderr("vault not initialized")
            throw ExitCode(1)
        }

        // Find secret
        let found: (policy: KeyPolicy, secret: EncryptedSecret)
        do {
            guard let result = try store.findSecret(name: name) else {
                writeStderr("secret '\(name)' not found (use 'vault set' to create)")
                throw ExitCode(2)
            }
            found = result
        } catch let e as VaultError {
            writeStderr("\(e)")
            throw ExitCode(1)
        }

        var vaultFile: VaultFile
        do {
            vaultFile = try store.loadVaultFile()
        } catch {
            writeStderr("failed to load vault: \(error)")
            throw ExitCode(1)
        }

        let policyName = found.policy.rawValue
        guard var entry = vaultFile.vaults[policyName] else {
            writeStderr("vault '\(policyName)' not found")
            throw ExitCode(1)
        }

        let manager = VaultManager()

        guard let dataRep = Data(base64Encoded: entry.dataRepresentation) else {
            writeStderr("corrupt vault key reference")
            throw ExitCode(3)
        }

        // Share a single LAContext so the user only authenticates once
        let authContext = LAContext()

        // Verify HMAC
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
            throw ExitCode(4)
        } catch let e as VaultError {
            writeStderr("\(e)")
            throw ExitCode(6)
        }

        // Read new value
        let value: String
        if fromStdin {
            guard let v = readSecretFromStdin(), !v.isEmpty else {
                writeStderr("empty secret value")
                throw ExitCode(5)
            }
            value = v
        } else {
            guard let v = readSecretFromTerminal(prompt: "Enter new secret value: "), !v.isEmpty else {
                writeStderr("empty secret value")
                throw ExitCode(5)
            }
            value = v
        }

        // Encrypt new value
        let plaintext = Data(value.utf8)
        let publicKey: P256.KeyAgreement.PublicKey
        do {
            let pubKeyData = try SignatureFormatter.parseHex(entry.publicKey)
            publicKey = try P256.KeyAgreement.PublicKey(x963Representation: pubKeyData)
        } catch {
            writeStderr("corrupt vault public key: \(error)")
            throw ExitCode(3)
        }

        var encrypted: EncryptedSecretData
        do {
            encrypted = try manager.encrypt(plaintext: plaintext, secretName: name, sePublicKey: publicKey)
        } catch {
            writeStderr("encryption failed: \(error)")
            throw ExitCode(3)
        }

        // Preserve original createdAt
        encrypted.createdAt = found.secret.createdAt

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
            throw ExitCode(3)
        }

        vaultFile.vaults[policyName] = entry
        do {
            try store.saveVaultFile(vaultFile)
        } catch {
            writeStderr("failed to write vault: \(error)")
            throw ExitCode(3)
        }

        // Output
        let output = VaultUpdateOutput(name: name, vault: policyName, updatedAt: encrypted.updatedAt)
        switch globals.format {
        case .json:
            try outputJSON(output)
        case .raw:
            writeStdout(name)
        case .pretty:
            writeStdout("Secret '\(name)' updated in \(policyName) vault\n")
        }
    }
}
