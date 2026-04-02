import ArgumentParser
import Foundation
import KeypoCore

struct SessionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "session",
        abstract: "Manage scoped, time-limited vault sessions",
        discussion: """
        Examples:
          keypo-signer vault session start --secrets API_KEY --ttl 30m
          keypo-signer vault session list
          keypo-signer vault session end orbital-canvas
        """,
        subcommands: [
            SessionStartCommand.self,
            SessionEndCommand.self,
            SessionListCommand.self,
            SessionStatusCommand.self,
            SessionRefreshCommand.self,
        ]
    )
}
