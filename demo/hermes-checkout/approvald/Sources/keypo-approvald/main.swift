import ArgumentParser
import Foundation

struct KeypoApprovald: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "keypo-approvald",
        abstract: "Approval daemon for Keypo checkout requests"
    )

    @Option(name: .long, help: "Unix socket path")
    var socket: String = "/tmp/keypo-approvald.sock"

    @Option(name: .long, help: "Path to checkout script")
    var checkoutScript: String

    @Option(name: .long, help: "User to run vault exec as (enables sudo mode)")
    var vaultUser: String?

    mutating func run() throws {
        // Validate checkout script exists
        guard FileManager.default.fileExists(atPath: checkoutScript) else {
            FileHandle.standardError.write(Data("error: checkout script not found: \(checkoutScript)\n".utf8))
            throw ExitCode(1)
        }

        let handler = RequestHandler(
            checkoutScript: checkoutScript,
            vaultUser: vaultUser
        )

        let server = DaemonServer(
            socketPath: socket,
            handler: handler
        )

        try server.start()
    }
}

KeypoApprovald.main()
