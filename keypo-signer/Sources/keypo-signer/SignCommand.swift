import ArgumentParser
import Foundation
import KeypoCore
import LocalAuthentication

struct SignCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sign",
        abstract: "Sign data with a Secure Enclave key"
    )

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Hex-encoded data to sign")
    var data: String?

    @Option(name: .long, help: "Key to sign with")
    var key: String?

    @Option(name: .customLong("bio-reason"), help: "Custom biometric prompt message")
    var bioReason: String?

    @Flag(name: .long, help: "Read hex data from stdin")
    var stdin: Bool = false

    mutating func run() throws {
        // Validate input source
        if data != nil && self.stdin {
            writeStderr("cannot specify both data argument and --stdin")
            throw ExitCode(3)
        }

        let hexInput: String
        if self.stdin {
            guard let line = readLine() else {
                writeStderr("no data on stdin")
                throw ExitCode(3)
            }
            hexInput = line.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        } else if let data = data {
            hexInput = data
        } else {
            writeStderr("provide data as argument or use --stdin")
            throw ExitCode(3)
        }

        let store = makeStore(globals)
        let manager = SecureEnclaveManager()

        // Resolve key
        let keys: [KeyMetadata]
        do {
            keys = try store.loadKeys()
        } catch let error as KeypoError {
            writeStderr(error.description)
            throw ExitCode(1)
        }

        let targetKey: KeyMetadata
        if let keyId = key {
            guard let found = keys.first(where: { $0.keyId == keyId }) else {
                writeStderr("key '\(keyId)' not found")
                throw ExitCode(1)
            }
            targetKey = found
        } else if keys.count == 1 {
            targetKey = keys[0]
        } else if keys.isEmpty {
            writeStderr("no keys found")
            throw ExitCode(1)
        } else {
            let keyNames = keys.map { $0.keyId }
            writeStderr("multiple keys exist, specify --key: \(keyNames.joined(separator: ", "))")
            throw ExitCode(5)
        }

        // Parse hex input
        let inputBytes: Data
        do {
            inputBytes = try SignatureFormatter.parseHex(hexInput)
        } catch {
            writeStderr("invalid hex input: \(error)")
            throw ExitCode(3)
        }

        // Load key data representation
        guard let dataRep = Data(base64Encoded: targetKey.dataRepresentation) else {
            writeStderr("corrupt key data representation")
            throw ExitCode(2)
        }

        // Pre-authenticate if key has biometric/passcode policy
        var authContext: LAContext? = nil
        if targetKey.policy == .biometric || targetKey.policy == .passcode {
            let reason = bioReason ?? "Keypo: sign data"
            do {
                authContext = try SecureEnclaveManager.preAuthenticate(reason: reason)
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
        }

        // Sign
        let derSignature: Data
        do {
            derSignature = try manager.signData(inputBytes, dataRepresentation: dataRep, authContext: authContext)
        } catch let error as KeypoError {
            if case .keyMissing = error {
                writeStderr(error.description)
                throw ExitCode(2)
            }
            writeStderr(error.description)
            throw ExitCode(4)
        } catch {
            writeStderr("signing failed: \(error)")
            throw ExitCode(4)
        }

        // Parse DER and apply low-S normalization
        let (r, rawS) = try SignatureFormatter.parseDERSignature(derSignature)
        let s = SignatureFormatter.applyLowS(s: rawS)
        let normalizedDER = SignatureFormatter.reconstructDER(r: r, s: s)

        // Atomically increment signing counter
        do {
            try store.incrementSignCount(keyId: targetKey.keyId)
        } catch {
            if !globals.quiet {
                writeStderrWarning("failed to update signing counter: \(error)")
            }
        }

        // Output
        let output = SignOutput(
            signature: SignatureFormatter.formatHex(normalizedDER),
            r: SignatureFormatter.formatHex(r),
            s: SignatureFormatter.formatHex(s),
            publicKey: targetKey.publicKey,
            keyId: targetKey.keyId
        )

        switch globals.format {
        case .json:
            try outputJSON(output)
        case .raw:
            writeStdout(SignatureFormatter.formatHex(normalizedDER))
        case .pretty:
            writeStdout("Key ID:     \(output.keyId)\n")
            writeStdout("Signature:  \(output.signature)\n")
            writeStdout("r:          \(output.r)\n")
            writeStdout("s:          \(output.s)\n")
            writeStdout("Algorithm:  ES256\n")
        }
    }
}
