import ArgumentParser
import Foundation
import KeypoCore
import CryptoKit
import LocalAuthentication

struct VaultExecCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "exec",
        abstract: "Decrypt secrets and inject them into a child process"
    )

    @OptionGroup var globals: GlobalOptions

    @Option(name: .long, help: "Comma-separated secret names or * for all")
    var allow: String?

    @Option(name: .long, help: "Path to .env file for key name extraction")
    var env: String?

    @Option(name: [.customLong("reason"), .customLong("bio-reason")], help: "Custom Touch ID prompt message (default: shows command name)")
    var reason: String?

    @Option(name: .long, help: "Session name for authenticated exec")
    var session: String?

    @Argument(parsing: .captureForPassthrough)
    var command: [String] = []

    mutating func run() throws {
        // Session-based exec path — must be checked before allow/env guard
        if let sessionName = session {
            try runWithSession(sessionName: sessionName)
            return
        }

        // Validate at least one source of secret names
        guard allow != nil || env != nil else {
            writeStderr("at least one of --allow or --env is required")
            throw ExitCode(126)
        }

        guard !command.isEmpty else {
            writeStderr("no command specified after --")
            throw ExitCode(126)
        }

        let store = makeVaultStore(globals)

        guard store.vaultExists() else {
            writeStderr("vault not initialized")
            throw ExitCode(126)
        }

        // Resolve secret names
        var secretNames = Set<String>()

        if let allowList = allow {
            if allowList == "*" {
                // All secrets across all vaults
                do {
                    let all = try store.allSecretNames()
                    for entry in all {
                        secretNames.insert(entry.name)
                    }
                } catch {
                    writeStderr("failed to enumerate secrets: \(error)")
                    throw ExitCode(126)
                }
            } else {
                for name in allowList.split(separator: ",") {
                    secretNames.insert(name.trimmingCharacters(in: .whitespaces))
                }
            }
        }

        if let envPath = env {
            do {
                let keys = try EnvFileParser.parseKeyNames(from: envPath)
                for key in keys {
                    secretNames.insert(key)
                }
            } catch {
                writeStderr("failed to parse .env file: \(error)")
                throw ExitCode(126)
            }
        }

        guard !secretNames.isEmpty else {
            writeStderr("no secrets to inject")
            throw ExitCode(126)
        }

        // Look up which vault each secret belongs to (JSON only, no SE key)
        var vaultFile: VaultFile
        do {
            vaultFile = try store.loadVaultFile()
        } catch {
            writeStderr("failed to load vault: \(error)")
            throw ExitCode(126)
        }

        // Group secrets by vault
        var secretsByVault: [String: [String]] = [:]  // policy name -> [secret names]
        for name in secretNames {
            var foundPolicy: String?
            for policyName in ["biometric", "passcode", "open"] {
                if let entry = vaultFile.vaults[policyName], entry.secrets[name] != nil {
                    foundPolicy = policyName
                    break
                }
            }
            guard let policy = foundPolicy else {
                writeStderr("secret '\(name)' not found in any vault")
                throw ExitCode(126)
            }
            secretsByVault[policy, default: []].append(name)
        }

        // Print summary to stderr (strip -- from display)
        let displayArgs = command.first == "--" ? Array(command.dropFirst()) : command
        let commandStr = displayArgs.joined(separator: " ")
        writeStderrRaw("keypo-vault: decrypting \(secretNames.count) secret(s) for: \(commandStr)")
        for policyName in ["open", "passcode", "biometric"] {
            guard let names = secretsByVault[policyName] else { continue }
            writeStderrRaw("  [\(policyName)] \(names.sorted().joined(separator: ", "))")
        }

        // Decrypt secrets, loading vaults in order: open, passcode, biometric
        let manager = VaultManager()
        var decryptedSecrets: [String: String] = [:]

        for policyName in ["open", "passcode", "biometric"] {
            guard let names = secretsByVault[policyName] else { continue }
            guard let entry = vaultFile.vaults[policyName] else { continue }

            guard let dataRep = Data(base64Encoded: entry.dataRepresentation) else {
                writeStderr("corrupt vault key reference for \(policyName)")
                throw ExitCode(126)
            }

            // Set up LAContext with command description for biometric/passcode
            var authContext: LAContext? = nil
            if policyName == "biometric" || policyName == "passcode" {
                var reason: String
                if let custom = self.reason, !custom.isEmpty {
                    reason = custom
                } else {
                    reason = "keypo-vault: decrypt secrets for: \(commandStr)"
                }
                if reason.count > 150 {
                    reason = String(reason.prefix(147)) + "..."
                }
                do {
                    let context = try SecureEnclaveManager.preAuthenticate(reason: reason, keyPolicy: KeyPolicy(rawValue: policyName) ?? .open)
                    authContext = context
                } catch VaultError.authenticationCancelled {
                    writeStderr("biometric authentication cancelled")
                    throw ExitCode(1)
                } catch VaultError.biometryUnavailable {
                    writeStderr("biometric authentication not available on this device")
                    throw ExitCode(1)
                } catch VaultError.authenticationFailed {
                    writeStderr("biometric authentication failed")
                    throw ExitCode(1)
                }
            }

            // Verify HMAC
            do {
                let integrityKey = try SignatureFormatter.parseHex(entry.integrityEphemeralPublicKey)
                guard let expectedHMAC = Data(base64Encoded: entry.integrityHmac) else {
                    writeStderr("corrupt HMAC for \(policyName) vault")
                    throw ExitCode(126)
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
                    throw ExitCode(126)
                }
            } catch VaultError.authenticationCancelled {
                writeStderr("authentication cancelled")
                throw ExitCode(128)
            } catch let e as VaultError {
                writeStderr("\(e)")
                throw ExitCode(126)
            }

            // Decrypt each secret in this vault
            for name in names {
                guard let secret = entry.secrets[name] else { continue }
                do {
                    let encData = try secret.toEncryptedSecretData()
                    let plaintext = try manager.decrypt(
                        encryptedData: encData,
                        secretName: name,
                        seKeyDataRepresentation: dataRep,
                        authContext: authContext
                    )
                    guard let value = String(data: plaintext, encoding: .utf8) else {
                        writeStderr("decrypted value for '\(name)' is not valid UTF-8")
                        throw ExitCode(126)
                    }
                    decryptedSecrets[name] = value
                } catch let e as VaultError where e.description.contains("cancelled") {
                    writeStderr("authentication cancelled")
                    throw ExitCode(128)
                } catch {
                    writeStderr("failed to decrypt '\(name)': \(error)")
                    throw ExitCode(126)
                }
            }
        }

        writeStderrRaw("keypo-vault: secrets injected, running command...")

        // Build child environment
        var childEnv = ProcessInfo.processInfo.environment
        for (name, value) in decryptedSecrets {
            childEnv[name] = value
        }

        // Strip -- and coalesce sh -c arguments
        let execArgs = ExecArgsHelper.prepareExecArgs(command)
        guard !execArgs.isEmpty else {
            writeStderr("no command specified after --")
            throw ExitCode(126)
        }

        // Spawn child process
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = execArgs
        process.environment = childEnv

        do {
            try process.run()
        } catch {
            writeStderr("command not found: \(command.first ?? "")")
            throw ExitCode(127)
        }

        // Swift's Process uses POSIX_SPAWN_SETPGROUP, placing the child in a
        // new (background) process group. If stdin is a TTY, child workers that
        // touch stdin receive SIGTTIN and silently suspend. Transfer foreground
        // ownership so the child's process group can read from the terminal.
        if isatty(STDIN_FILENO) != 0 {
            tcsetpgrp(STDIN_FILENO, process.processIdentifier)
        }

        process.waitUntilExit()

        // Reclaim foreground process group for the parent before exiting.
        if isatty(STDIN_FILENO) != 0 {
            tcsetpgrp(STDIN_FILENO, getpgrp())
        }

        // Zeroize decrypted values
        decryptedSecrets.removeAll()

        // Forward child's exit code
        throw ExitCode(process.terminationStatus)
    }

    // MARK: - Session-based Exec

    private func runWithSession(sessionName: String) throws {
        // Mutual exclusion: --session with --allow or --env
        if allow != nil || env != nil {
            writeStderr("--session is mutually exclusive with --allow and --env")
            throw ExitCode(126)
        }

        guard !command.isEmpty else {
            writeStderr("no command specified after --")
            throw ExitCode(126)
        }

        let execArgs = ExecArgsHelper.prepareExecArgs(command)
        guard !execArgs.isEmpty else {
            writeStderr("no command specified after --")
            throw ExitCode(126)
        }

        let sessionManager = SessionManager()

        // Validate session
        let metadata: SessionMetadata
        do {
            metadata = try sessionManager.validateSession(name: sessionName)
        } catch let error as SessionError {
            // Log session.exec_denied audit entry before throwing
            let reason: String
            switch error {
            case .sessionNotFound: reason = "not_found"
            case .sessionExpired: reason = "expired"
            case .sessionExhausted: reason = "exhausted"
            default: reason = "unknown"
            }
            sessionManager.auditLog.log(AuditEntry(
                event: "session.exec_denied",
                session: sessionName,
                details: .execDenied(SessionExecDeniedDetails(reason: reason, command: execArgs[0]))
            ))
            writeStderr("\(error)")
            throw ExitCode(5)
        }

        // Decrypt all session secrets
        var decryptedSecrets: [String: String]
        do {
            decryptedSecrets = try sessionManager.decryptSessionSecrets(session: metadata)
        } catch {
            writeStderr("failed to decrypt session secrets: \(error)")
            throw ExitCode(126)
        }

        // Decrement usage
        let updated: SessionMetadata
        do {
            updated = try sessionManager.decrementUsage(session: metadata)
        } catch {
            writeStderr("keychain error: \(error)")
            throw ExitCode(126)
        }

        // Build child environment
        var childEnv = ProcessInfo.processInfo.environment
        for (name, value) in decryptedSecrets {
            childEnv[name] = value
        }

        let displayArgs = execArgs.joined(separator: " ")
        writeStderrRaw("keypo-vault: session '\(sessionName)' — decrypting \(decryptedSecrets.count) secret(s) for: \(displayArgs)")

        // Spawn child process
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = execArgs
        process.environment = childEnv

        do {
            try process.run()
        } catch {
            writeStderr("command not found: \(execArgs.first ?? "")")
            throw ExitCode(127)
        }

        // Write audit entry after spawn (to capture childPid)
        sessionManager.auditLog.log(AuditEntry(
            event: "session.exec",
            session: sessionName,
            details: .exec(SessionExecDetails(
                command: execArgs[0],
                secretsInjected: metadata.secrets,
                usesRemaining: updated.usesRemaining,
                childPid: Int(process.processIdentifier)
            ))
        ))

        // Transfer foreground for TTY stdin forwarding
        if isatty(STDIN_FILENO) != 0 {
            tcsetpgrp(STDIN_FILENO, process.processIdentifier)
        }

        process.waitUntilExit()

        if isatty(STDIN_FILENO) != 0 {
            tcsetpgrp(STDIN_FILENO, getpgrp())
        }

        decryptedSecrets.removeAll()
        throw ExitCode(process.terminationStatus)
    }
}
