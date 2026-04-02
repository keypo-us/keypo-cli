import Foundation
import CryptoKit
import LocalAuthentication

/// Orchestrates session lifecycle: creation, validation, decryption, cleanup.
public class SessionManager {
    public let keychainStore: SessionKeychainStore
    public let auditLog: SessionAuditLog
    public let vaultManager: VaultManager

    public init(
        keychainStore: SessionKeychainStore = SessionKeychainStore(),
        auditLog: SessionAuditLog = SessionAuditLog(),
        vaultManager: VaultManager = VaultManager()
    ) {
        self.keychainStore = keychainStore
        self.auditLog = auditLog
        self.vaultManager = vaultManager
    }

    // MARK: - Session Name Generation

    /// Generate a BIP39 two-word session name (e.g., "orbital-canvas").
    /// Retries on collision up to 5 times.
    public func generateSessionName() throws -> String {
        for _ in 0..<5 {
            let words = PassphraseGenerator.generatePassphrase(wordCount: 2)
            let name = words.joined(separator: "-").lowercased()
            if keychainStore.loadSession(name: name) == nil {
                return name
            }
        }
        throw SessionError.validationError("failed to generate unique session name after 5 attempts")
    }

    // MARK: - Duplicate Detection

    /// Check if an active session with the exact same sorted set of secrets exists.
    public func isDuplicateSession(secrets: [String]) throws -> (isDuplicate: Bool, existingName: String?) {
        let sortedSecrets = secrets.sorted()
        let sessions = try keychainStore.listSessions()
        for (metadata, _) in sessions {
            guard isActive(metadata) else { continue }
            if metadata.secrets == sortedSecrets {
                return (true, metadata.name)
            }
        }
        return (false, nil)
    }

    // MARK: - SE Key Management

    /// Create a temp SE KeyAgreement key with open policy for session use.
    public func createTempSEKey() throws -> (dataRepresentation: Data, publicKey: Data) {
        try vaultManager.createKeyAgreementKey(policy: .open)
    }

    // MARK: - Session ECIES

    /// Encrypt a secret value for session storage.
    /// Returns EncryptedSecret (serializable form) ready for Keychain storage.
    public func encryptSecretForSession(plaintext: Data, secretName: String, sessionName: String,
                                         sePublicKey: P256.KeyAgreement.PublicKey) throws -> EncryptedSecret {
        let encryptedData = try vaultManager.encryptForSession(
            plaintext: plaintext, secretName: secretName,
            sessionName: sessionName, sePublicKey: sePublicKey
        )
        return EncryptedSecret(from: encryptedData)
    }

    /// Decrypt a session-stored secret value.
    public func decryptSecretFromSession(encrypted: EncryptedSecret, secretName: String,
                                          sessionName: String, seKeyDataRepresentation: Data) throws -> Data {
        let encryptedData = try encrypted.toEncryptedSecretData()
        return try vaultManager.decryptFromSession(
            encryptedData: encryptedData, secretName: secretName,
            sessionName: sessionName, seKeyDataRepresentation: seKeyDataRepresentation
        )
    }

    /// Decrypt all secrets for a session. Returns [secretName: plaintext string].
    public func decryptSessionSecrets(session: SessionMetadata) throws -> [String: String] {
        guard let loaded = keychainStore.loadSession(name: session.name) else {
            throw SessionError.sessionNotFound(session.name)
        }
        let allSecrets = keychainStore.loadAllSessionSecrets(sessionName: session.name)
        var result: [String: String] = [:]

        for secretName in session.secrets {
            guard let encrypted = allSecrets[secretName] else {
                throw SessionError.keychainError("session secret '\(secretName)' not found in Keychain")
            }
            let plaintext = try decryptSecretFromSession(
                encrypted: encrypted, secretName: secretName,
                sessionName: session.name, seKeyDataRepresentation: loaded.tempKeyDataRep
            )
            guard let value = String(data: plaintext, encoding: .utf8) else {
                throw SessionError.keychainError("session secret '\(secretName)' is not valid UTF-8")
            }
            result[secretName] = value
        }
        return result
    }

    // MARK: - Usage Tracking

    /// Decrement usesRemaining by 1. No-op if usesRemaining is nil (unlimited).
    /// Returns updated metadata.
    public func decrementUsage(session: SessionMetadata) throws -> SessionMetadata {
        guard session.usesRemaining != nil else {
            return session // unlimited — no-op
        }
        var updated = session
        updated.usesRemaining = (updated.usesRemaining ?? 0) - 1
        try keychainStore.updateSessionMetadata(updated)
        return updated
    }

    // MARK: - Session Lifecycle

    /// End a session. Idempotent — no-op if session does not exist.
    public func endSession(name: String, trigger: String) {
        guard let loaded = keychainStore.loadSession(name: name) else {
            return // Silent no-op for non-existent sessions
        }

        let metadata = loaded.metadata
        let usesConsumed: Int
        if let maxUses = metadata.maxUses, let remaining = metadata.usesRemaining {
            usesConsumed = maxUses - remaining
        } else {
            usesConsumed = 0
        }

        // Delete temp SE key
        vaultManager.deleteKeyAgreementKey(dataRepresentation: loaded.tempKeyDataRep)

        // Delete Keychain items
        keychainStore.deleteSession(name: name)

        // Log audit entry
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        auditLog.log(AuditEntry(
            event: "session.end",
            session: name,
            details: .end(SessionEndDetails(trigger: trigger, usesConsumed: usesConsumed))
        ))
    }

    /// End all active sessions.
    public func endAllSessions() throws {
        let sessions = try keychainStore.listSessions()
        for (metadata, _) in sessions {
            endSession(name: metadata.name, trigger: "explicit")
        }
    }

    /// Garbage-collect expired and exhausted sessions. Returns count cleaned.
    public func garbageCollect() throws -> Int {
        let sessions = try keychainStore.listSessions()
        var cleaned = 0
        for (metadata, _) in sessions {
            if isExpired(metadata) {
                endSession(name: metadata.name, trigger: "expired")
                cleaned += 1
            } else if isExhausted(metadata) {
                endSession(name: metadata.name, trigger: "exhausted")
                cleaned += 1
            }
        }
        return cleaned
    }

    // MARK: - Status Checks

    public func isExpired(_ session: SessionMetadata) -> Bool {
        Date() >= session.expiresAt
    }

    public func isExhausted(_ session: SessionMetadata) -> Bool {
        guard let remaining = session.usesRemaining else { return false }
        return remaining <= 0
    }

    public func isActive(_ session: SessionMetadata) -> Bool {
        !isExpired(session) && !isExhausted(session)
    }

    // MARK: - Validation

    /// Validate a session exists and is active. Throws SessionError on failure.
    public func validateSession(name: String) throws -> SessionMetadata {
        guard let loaded = keychainStore.loadSession(name: name) else {
            throw SessionError.sessionNotFound(name)
        }
        let metadata = loaded.metadata
        if isExpired(metadata) {
            // Clean up expired session
            endSession(name: name, trigger: "expired")
            throw SessionError.sessionExpired(name)
        }
        if isExhausted(metadata) {
            endSession(name: name, trigger: "exhausted")
            throw SessionError.sessionExhausted(name)
        }
        return metadata
    }

    // MARK: - Authentication for Refresh

    /// Authenticate for session refresh using evaluatePolicy directly.
    /// Does NOT use preAuthenticate — that returns an unevaluated LAContext for biometric.
    public func authenticateForRefresh(originalTiers: [String: String], reason: String) throws {
        let tiers = Set(originalTiers.values)

        // Determine highest tier present
        if tiers.contains("biometric") {
            let context = LAContext()
            var error: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
                throw VaultError.biometryUnavailable
            }
            let semaphore = DispatchSemaphore(value: 0)
            var authError: Error?
            context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, err in
                if !success { authError = err }
                semaphore.signal()
            }
            semaphore.wait()
            if let err = authError {
                let nsErr = err as NSError
                if nsErr.code == -2 || nsErr.code == -128 {
                    throw VaultError.authenticationCancelled
                }
                throw VaultError.authenticationFailed
            }
        } else if tiers.contains("passcode") {
            let context = LAContext()
            var error: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
                throw VaultError.authenticationFailed
            }
            let semaphore = DispatchSemaphore(value: 0)
            var authError: Error?
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, err in
                if !success { authError = err }
                semaphore.signal()
            }
            semaphore.wait()
            if let err = authError {
                let nsErr = err as NSError
                if nsErr.code == -2 || nsErr.code == -128 {
                    throw VaultError.authenticationCancelled
                }
                throw VaultError.authenticationFailed
            }
        }
        // open-only: no authentication needed
    }
}
