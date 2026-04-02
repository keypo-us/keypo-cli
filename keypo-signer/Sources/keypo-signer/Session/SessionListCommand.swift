import ArgumentParser
import Foundation
import KeypoCore

struct SessionListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List active sessions",
        discussion: """
        Examples:
          keypo-signer vault session list
          keypo-signer vault session list --format pretty
        """
    )

    @OptionGroup var globals: GlobalOptions

    mutating func run() throws {
        let sessionManager = SessionManager()

        // Garbage collect expired/exhausted sessions
        let cleaned = (try? sessionManager.garbageCollect()) ?? 0

        // List remaining active sessions
        let sessions: [(metadata: SessionMetadata, tempKeyDataRep: Data)]
        do {
            sessions = try sessionManager.keychainStore.listSessions()
        } catch {
            writeStderr("keychain error: \(error)")
            throw ExitCode(126)
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let entries = sessions.compactMap { (metadata, _) -> SessionListEntry? in
            guard sessionManager.isActive(metadata) else { return nil }
            return SessionListEntry(
                name: metadata.name,
                secrets: metadata.secrets,
                expiresAt: formatter.string(from: metadata.expiresAt),
                usesRemaining: metadata.usesRemaining,
                status: "active"
            )
        }

        let output = SessionListOutput(sessions: entries, cleaned: cleaned)

        switch globals.format {
        case .json, .raw:
            try outputJSON(output)
        case .pretty:
            if entries.isEmpty {
                writeStdout("No active sessions\n")
            } else {
                for entry in entries {
                    writeStdout("\(entry.name)\n")
                    writeStdout("  Secrets: \(entry.secrets.joined(separator: ", "))\n")
                    writeStdout("  Expires: \(entry.expiresAt)\n")
                    if let remaining = entry.usesRemaining {
                        writeStdout("  Uses remaining: \(remaining)\n")
                    }
                }
            }
            if cleaned > 0 {
                writeStdout("Cleaned \(cleaned) expired session(s)\n")
            }
        }
    }
}
