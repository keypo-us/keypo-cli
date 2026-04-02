import ArgumentParser
import Foundation
import KeypoCore
import CryptoKit
import LocalAuthentication

struct SessionStartCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Create a scoped, time-limited session"
    )

    @OptionGroup var globals: GlobalOptions

    @Option(name: .long, help: "Comma-separated secret names (required)")
    var secrets: String

    @Option(name: .long, help: "Session duration, e.g. 30m, 2h, 1d (default: 30m)")
    var ttl: String = "30m"

    @Option(name: .long, help: "Maximum number of exec uses")
    var maxUses: Int?

    @Option(name: [.customLong("reason"), .customLong("bio-reason")], help: "Custom Touch ID prompt message")
    var reason: String?

    mutating func run() throws {
        // Parse and validate secrets
        let secretNames = secrets.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !secretNames.isEmpty else {
            writeStderr("--secrets must list at least one secret name")
            throw ExitCode(126)
        }
        if secretNames.contains("*") {
            writeStderr("wildcard not permitted for sessions; list secrets explicitly")
            throw ExitCode(126)
        }

        // Parse TTL
        guard let ttlInterval = TTLParser.parse(ttl) else {
            writeStderr("TTL must be a positive duration")
            throw ExitCode(126)
        }
        if ttlInterval > 86400 {
            writeStderrWarning("sessions longer than 24h are not recommended")
        }

        // Validate max-uses
        if let mu = maxUses, mu < 1 {
            writeStderr("max-uses must be at least 1")
            throw ExitCode(126)
        }

        let store = makeVaultStore(globals)
        guard store.vaultExists() else {
            writeStderr("vault not initialized")
            throw ExitCode(126)
        }

        // Load vault to resolve secrets to tiers
        let vaultFile: VaultFile
        do {
            vaultFile = try store.loadVaultFile()
        } catch {
            writeStderr("failed to load vault: \(error)")
            throw ExitCode(126)
        }

        // Resolve each secret to its tier
        var secretTiers: [String: String] = [:]  // name -> policy
        for name in secretNames {
            var found = false
            for policyName in ["biometric", "passcode", "open"] {
                if let entry = vaultFile.vaults[policyName], entry.secrets[name] != nil {
                    secretTiers[name] = policyName
                    found = true
                    break
                }
            }
            if !found {
                writeStderr("secret '\(name)' not found in any vault")
                throw ExitCode(126)
            }
        }

        let sessionManager = SessionManager()

        // Check for duplicate sessions
        let dupCheck = try sessionManager.isDuplicateSession(secrets: secretNames)
        if dupCheck.isDuplicate {
            writeStderr("a session with identical secrets already exists: '\(dupCheck.existingName ?? "unknown")'")
            throw ExitCode(126)
        }

        // Authenticate per tier
        let manager = VaultManager()
        var authContexts: [String: LAContext] = [:]

        for policyName in ["open", "passcode", "biometric"] {
            let secretsInTier = secretNames.filter { secretTiers[$0] == policyName }
            guard !secretsInTier.isEmpty else { continue }

            if policyName == "biometric" || policyName == "passcode" {
                let secretList = secretsInTier.sorted().joined(separator: ", ")
                let authReason = reason ?? "Create session for \(secretList) (TTL: \(ttl))"
                do {
                    let context = try SecureEnclaveManager.preAuthenticate(
                        reason: String(authReason.prefix(150)),
                        keyPolicy: KeyPolicy(rawValue: policyName) ?? .open
                    )
                    authContexts[policyName] = context
                } catch VaultError.authenticationCancelled {
                    writeStderr("authentication cancelled")
                    throw ExitCode(1)
                } catch {
                    writeStderr("authentication failed: \(error)")
                    throw ExitCode(1)
                }
            }
        }

        // Generate session name
        let sessionName: String
        do {
            sessionName = try sessionManager.generateSessionName()
        } catch {
            writeStderr("failed to generate session name: \(error)")
            throw ExitCode(126)
        }

        // Create temp SE key
        let tempKey: (dataRepresentation: Data, publicKey: Data)
        do {
            tempKey = try sessionManager.createTempSEKey()
        } catch {
            writeStderr("failed to create session key: \(error)")
            throw ExitCode(126)
        }

        let sePublicKey: P256.KeyAgreement.PublicKey
        do {
            sePublicKey = try P256.KeyAgreement.PublicKey(x963Representation: tempKey.publicKey)
        } catch {
            writeStderr("failed to reconstruct session public key: \(error)")
            throw ExitCode(126)
        }

        // Decrypt and re-encrypt each secret under the session key
        // Wrap in do/catch for rollback on partial failure
        do {
            let now = Date()
            let expiresAt = now.addingTimeInterval(ttlInterval)

            let metadata = SessionMetadata(
                name: sessionName,
                secrets: secretNames,
                originalTiers: secretTiers,
                createdAt: now,
                expiresAt: expiresAt,
                maxUses: maxUses,
                usesRemaining: maxUses,
                tempKeyPublicKey: SignatureFormatter.formatHex(tempKey.publicKey)
            )

            try sessionManager.keychainStore.saveSession(metadata, tempKeyDataRep: tempKey.dataRepresentation)

            for name in secretNames {
                guard let policyName = secretTiers[name],
                      let vaultEntry = vaultFile.vaults[policyName],
                      let encryptedSecret = vaultEntry.secrets[name] else {
                    throw SessionError.keychainError("secret '\(name)' not found in vault")
                }

                guard let dataRep = Data(base64Encoded: vaultEntry.dataRepresentation) else {
                    throw SessionError.keychainError("corrupt vault key reference for \(policyName)")
                }

                // Decrypt from vault
                let encData = try encryptedSecret.toEncryptedSecretData()
                let plaintext = try manager.decrypt(
                    encryptedData: encData,
                    secretName: name,
                    seKeyDataRepresentation: dataRep,
                    authContext: authContexts[policyName]
                )

                // Re-encrypt for session
                let sessionEncrypted = try sessionManager.encryptSecretForSession(
                    plaintext: plaintext, secretName: name,
                    sessionName: sessionName, sePublicKey: sePublicKey
                )

                try sessionManager.keychainStore.saveSessionSecret(
                    sessionName: sessionName, secretName: name, encrypted: sessionEncrypted
                )
            }

            // Log audit entry
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            sessionManager.auditLog.log(AuditEntry(
                event: "session.start",
                session: sessionName,
                details: .start(SessionStartDetails(
                    secrets: metadata.secrets,
                    tiers: secretTiers,
                    ttl: ttl,
                    maxUses: maxUses,
                    expiresAt: formatter.string(from: expiresAt)
                ))
            ))

            // Garbage collect expired sessions
            _ = try? sessionManager.garbageCollect()

            // Output
            let output = SessionStartOutput(
                session: sessionName,
                secrets: metadata.secrets,
                expiresAt: formatter.string(from: expiresAt),
                maxUses: maxUses,
                ttl: ttl
            )

            switch globals.format {
            case .json, .raw:
                try outputJSON(output)
            case .pretty:
                writeStdout("Session created: \(sessionName)\n")
                writeStdout("  Secrets: \(metadata.secrets.joined(separator: ", "))\n")
                writeStdout("  Expires: \(formatter.string(from: expiresAt))\n")
                if let mu = maxUses {
                    writeStdout("  Max uses: \(mu)\n")
                }
            }
        } catch {
            // Rollback: clean up partially created session
            sessionManager.keychainStore.deleteSession(name: sessionName)
            manager.deleteKeyAgreementKey(dataRepresentation: tempKey.dataRepresentation)

            if let sessionErr = error as? SessionError {
                writeStderr("\(sessionErr)")
            } else if let vaultErr = error as? VaultError {
                if vaultErr.description.contains("cancelled") {
                    writeStderr("authentication cancelled")
                    throw ExitCode(1)
                }
                writeStderr("\(vaultErr)")
            } else {
                writeStderr("session creation failed: \(error)")
            }
            throw ExitCode(126)
        }
    }
}
