import ArgumentParser
import Foundation
import KeypoCore

struct SessionEndCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "end",
        abstract: "End one or all sessions",
        discussion: """
        Examples:
          keypo-signer vault session end orbital-canvas
          keypo-signer vault session end --all
        """
    )

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Session name to end")
    var name: String?

    @Flag(name: .long, help: "End all active sessions")
    var all: Bool = false

    mutating func run() throws {
        guard name != nil || all else {
            writeStderr("specify a session name or use --all")
            throw ExitCode(126)
        }
        guard !(name != nil && all) else {
            writeStderr("specify either a session name or --all, not both")
            throw ExitCode(126)
        }

        let sessionManager = SessionManager()
        var ended: [String] = []

        if all {
            do {
                let sessions = try sessionManager.keychainStore.listSessions()
                for (metadata, _) in sessions {
                    sessionManager.endSession(name: metadata.name, trigger: "explicit")
                    ended.append(metadata.name)
                }
            } catch {
                writeStderr("keychain error: \(error)")
                throw ExitCode(126)
            }
        } else if let sessionName = name {
            // Check if session exists before ending (for the output)
            if sessionManager.keychainStore.loadSession(name: sessionName) != nil {
                sessionManager.endSession(name: sessionName, trigger: "explicit")
                ended.append(sessionName)
            }
            // Idempotent: non-existent session is not an error
        }

        let output = SessionEndOutput(ended: ended)

        switch globals.format {
        case .json, .raw:
            try outputJSON(output)
        case .pretty:
            if ended.isEmpty {
                writeStdout("No sessions ended\n")
            } else {
                writeStdout("Ended \(ended.count) session(s): \(ended.joined(separator: ", "))\n")
            }
        }
    }
}
