import ArgumentParser
import Foundation
import KeypoCore
import LocalAuthentication

struct VaultGetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Decrypt and output a secret",
        discussion: """
        Examples:
          keypo-signer vault get API_KEY
          keypo-signer vault get API_KEY --format raw
        """
    )

    @OptionGroup var globals: GlobalOptions

    @Option(name: .customLong("bio-reason"), help: "Custom biometric prompt message")
    var bioReason: String?

    @Argument(help: "Secret name")
    var name: String

    mutating func run() throws {
        let store = makeVaultStore(globals)

        guard store.vaultExists() else {
            writeStderr("vault not initialized")
            throw ExitCode(1)
        }

        // Find secret across all vaults
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

        let vaultFile: VaultFile
        do {
            vaultFile = try store.loadVaultFile()
        } catch {
            writeStderr("failed to load vault: \(error)")
            throw ExitCode(1)
        }

        let policyName = found.policy.rawValue
        guard let entry = vaultFile.vaults[policyName] else {
            writeStderr("vault '\(policyName)' not found")
            throw ExitCode(1)
        }

        let manager = VaultManager()

        guard let dataRep = Data(base64Encoded: entry.dataRepresentation) else {
            writeStderr("corrupt vault key reference")
            throw ExitCode(3)
        }

        // Pre-authenticate if vault requires biometric/passcode
        let authContext: LAContext
        if found.policy == .biometric || found.policy == .passcode {
            let reason = bioReason ?? "Keypo Vault Access"
            do {
                authContext = try SecureEnclaveManager.preAuthenticate(reason: reason, keyPolicy: found.policy)
            } catch VaultError.authenticationCancelled {
                writeStderr("biometric authentication cancelled")
                throw ExitCode(4)
            } catch VaultError.biometryUnavailable {
                writeStderr("biometric authentication not available on this device")
                throw ExitCode(4)
            } catch VaultError.authenticationFailed {
                writeStderr("biometric authentication failed")
                throw ExitCode(4)
            }
        } else {
            authContext = LAContext()
        }

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

        // Decrypt
        let plaintext: Data
        do {
            let encData = try found.secret.toEncryptedSecretData()
            plaintext = try manager.decrypt(
                encryptedData: encData,
                secretName: name,
                seKeyDataRepresentation: dataRep,
                authContext: authContext
            )
        } catch VaultError.authenticationCancelled {
            writeStderr("authentication cancelled")
            throw ExitCode(4)
        } catch {
            writeStderr("decryption failed: \(error)")
            throw ExitCode(3)
        }

        guard let value = String(data: plaintext, encoding: .utf8) else {
            writeStderr("decrypted value is not valid UTF-8")
            throw ExitCode(3)
        }

        // Output
        switch globals.format {
        case .json:
            let output = VaultGetOutput(name: name, vault: policyName, value: value)
            try outputJSON(output)
        case .raw:
            // Raw: value only, no trailing newline
            writeStdout(value)
        case .pretty:
            writeStdout("\(name)=\(value)\n")
        }
    }
}
