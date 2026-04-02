import ArgumentParser
import Foundation
import KeypoCore

struct SessionRefreshCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "refresh",
        abstract: "Refresh a session's TTL or usage limits",
        discussion: """
        Examples:
          keypo-signer vault session refresh orbital-canvas --ttl 2h
          keypo-signer vault session refresh orbital-canvas --max-uses 100
        """
    )

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Session name")
    var name: String

    @Option(name: .long, help: "New TTL duration, e.g. 30m, 2h, 1d")
    var ttl: String?

    @Option(name: .long, help: "New maximum uses")
    var maxUses: Int?

    @Option(name: [.customLong("reason"), .customLong("bio-reason")], help: "Custom Touch ID prompt message")
    var reason: String?

    mutating func run() throws {
        let sessionManager = SessionManager()

        // Validate session exists and is active
        let metadata: SessionMetadata
        do {
            metadata = try sessionManager.validateSession(name: name)
        } catch SessionError.sessionNotFound {
            writeStderr("session '\(name)' not found")
            throw ExitCode(126)
        } catch SessionError.sessionExpired {
            writeStderr("session '\(name)' has expired")
            throw ExitCode(5)
        } catch SessionError.sessionExhausted {
            writeStderr("session '\(name)' has no remaining uses")
            throw ExitCode(5)
        }

        // Authenticate against original tiers
        let authReason = reason ?? "keypo-vault: refresh session \(name)"
        do {
            try sessionManager.authenticateForRefresh(
                originalTiers: metadata.originalTiers,
                reason: String(authReason.prefix(150))
            )
        } catch VaultError.authenticationCancelled {
            writeStderr("authentication cancelled")
            throw ExitCode(1)
        } catch {
            writeStderr("authentication failed: \(error)")
            throw ExitCode(1)
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // Record old values for audit
        let oldExpiresAt = formatter.string(from: metadata.expiresAt)
        let oldMaxUses = metadata.maxUses

        // Apply updates
        var updated = metadata
        if let ttlStr = ttl {
            guard let ttlInterval = TTLParser.parse(ttlStr) else {
                writeStderr("TTL must be a positive duration")
                throw ExitCode(126)
            }
            if ttlInterval > 86400 {
                writeStderrWarning("sessions longer than 24h are not recommended")
            }
            updated.expiresAt = Date().addingTimeInterval(ttlInterval)
        }
        if let mu = maxUses {
            guard mu >= 1 else {
                writeStderr("max-uses must be at least 1")
                throw ExitCode(126)
            }
            updated.maxUses = mu
            updated.usesRemaining = mu
        }

        do {
            try sessionManager.keychainStore.updateSessionMetadata(updated)
        } catch {
            writeStderr("keychain error: \(error)")
            throw ExitCode(126)
        }

        // Log audit entry
        sessionManager.auditLog.log(AuditEntry(
            event: "session.refresh",
            session: name,
            details: .refresh(SessionRefreshDetails(
                oldExpiresAt: oldExpiresAt,
                newExpiresAt: formatter.string(from: updated.expiresAt),
                oldMaxUses: oldMaxUses,
                newMaxUses: updated.maxUses
            ))
        ))

        let output = SessionRefreshOutput(
            session: name,
            expiresAt: formatter.string(from: updated.expiresAt),
            maxUses: updated.maxUses,
            usesRemaining: updated.usesRemaining
        )

        switch globals.format {
        case .json, .raw:
            try outputJSON(output)
        case .pretty:
            writeStdout("Session refreshed: \(name)\n")
            writeStdout("  Expires: \(formatter.string(from: updated.expiresAt))\n")
            if let mu = updated.maxUses {
                writeStdout("  Max uses: \(mu)\n")
            }
        }
    }
}
