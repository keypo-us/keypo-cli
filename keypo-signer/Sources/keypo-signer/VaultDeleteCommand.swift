import ArgumentParser
import Foundation
import KeypoCore
import LocalAuthentication

struct VaultDeleteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Remove an encrypted secret from its vault"
    )

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Secret name")
    var name: String

    @Flag(name: .long, help: "Confirm deletion (required)")
    var confirm: Bool = false

    mutating func run() throws {
        guard confirm else {
            writeStderr("--confirm flag is required for deletion")
            throw ExitCode(3)
        }

        let store = makeVaultStore(globals)

        guard store.vaultExists() else {
            writeStderr("vault not initialized")
            throw ExitCode(1)
        }

        // Find secret
        let found: (policy: KeyPolicy, secret: EncryptedSecret)
        do {
            guard let result = try store.findSecret(name: name) else {
                writeStderr("secret '\(name)' not found in any vault")
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
            throw ExitCode(5)
        }

        // Share a single LAContext so the user only authenticates once
        let authContext = LAContext()

        // Verify HMAC
        do {
            let integrityKey = try SignatureFormatter.parseHex(entry.integrityEphemeralPublicKey)
            guard let expectedHMAC = Data(base64Encoded: entry.integrityHmac) else {
                writeStderr("corrupt HMAC")
                throw ExitCode(5)
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
                throw ExitCode(5)
            }
        } catch VaultError.authenticationCancelled {
            writeStderr("authentication cancelled")
            throw ExitCode(4)
        } catch let e as VaultError {
            writeStderr("\(e)")
            throw ExitCode(5)
        }

        // Remove secret
        entry.secrets.removeValue(forKey: name)

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
            throw ExitCode(5)
        }

        vaultFile.vaults[policyName] = entry
        do {
            try store.saveVaultFile(vaultFile)
        } catch {
            writeStderr("failed to write vault: \(error)")
            throw ExitCode(5)
        }

        // Output
        let output = VaultDeleteOutput(name: name, vault: policyName, deletedAt: Date())
        switch globals.format {
        case .json:
            try outputJSON(output)
        case .raw:
            writeStdout(name)
        case .pretty:
            writeStdout("Secret '\(name)' deleted from \(policyName) vault\n")
        }
    }
}
