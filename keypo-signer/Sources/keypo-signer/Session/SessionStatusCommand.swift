import ArgumentParser
import Foundation
import KeypoCore

struct SessionStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show detailed status of a session",
        discussion: """
        Examples:
          keypo-signer vault session status orbital-canvas
        """
    )

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Session name")
    var name: String

    mutating func run() throws {
        let sessionManager = SessionManager()

        guard let loaded = sessionManager.keychainStore.loadSession(name: name) else {
            writeStderr("session '\(name)' not found")
            throw ExitCode(126)
        }

        let metadata = loaded.metadata
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let status: String
        if sessionManager.isExpired(metadata) {
            status = "expired"
        } else if sessionManager.isExhausted(metadata) {
            status = "exhausted"
        } else {
            status = "active"
        }

        let output = SessionStatusOutput(
            name: metadata.name,
            secrets: metadata.secrets,
            originalTiers: metadata.originalTiers,
            createdAt: formatter.string(from: metadata.createdAt),
            expiresAt: formatter.string(from: metadata.expiresAt),
            maxUses: metadata.maxUses,
            usesRemaining: metadata.usesRemaining,
            status: status
        )

        switch globals.format {
        case .json, .raw:
            try outputJSON(output)
        case .pretty:
            writeStdout("Session: \(metadata.name) (\(status))\n")
            writeStdout("  Secrets: \(metadata.secrets.joined(separator: ", "))\n")
            for (name, tier) in metadata.originalTiers.sorted(by: { $0.key < $1.key }) {
                writeStdout("    \(name): \(tier)\n")
            }
            writeStdout("  Created: \(formatter.string(from: metadata.createdAt))\n")
            writeStdout("  Expires: \(formatter.string(from: metadata.expiresAt))\n")
            if let mu = metadata.maxUses {
                writeStdout("  Max uses: \(mu)\n")
            }
            if let remaining = metadata.usesRemaining {
                writeStdout("  Uses remaining: \(remaining)\n")
            }
        }
    }
}
