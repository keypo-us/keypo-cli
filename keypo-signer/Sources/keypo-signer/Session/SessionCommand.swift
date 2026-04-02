import ArgumentParser
import Foundation
import KeypoCore

struct SessionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "session",
        abstract: "Manage scoped, time-limited vault sessions",
        subcommands: [
            SessionStartCommand.self,
            SessionEndCommand.self,
            SessionListCommand.self,
            SessionStatusCommand.self,
            SessionRefreshCommand.self,
        ]
    )
}
