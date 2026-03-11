import ArgumentParser
import Foundation
import KeypoCore

struct VaultCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vault",
        abstract: "Manage encrypted secrets with Secure Enclave protection",
        subcommands: [
            VaultInitCommand.self,
            VaultSetCommand.self,
            VaultGetCommand.self,
            VaultUpdateCommand.self,
            VaultDeleteCommand.self,
            VaultListCommand.self,
            VaultExecCommand.self,
            VaultImportCommand.self,
            VaultDestroyCommand.self,
        ]
    )
}

func makeVaultStore(_ globals: GlobalOptions) -> VaultStore {
    VaultStore(configPath: globals.config)
}

/// Read a secret value from stdin (piped input)
func readSecretFromStdin() -> String? {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let value = String(data: data, encoding: .utf8) else { return nil }
    // Strip single trailing newline if present (common from echo/printf)
    if value.hasSuffix("\n") {
        return String(value.dropLast())
    }
    return value
}

/// Read a secret value from terminal with echo suppressed
func readSecretFromTerminal(prompt: String) -> String? {
    // Print prompt to stderr (not stdout)
    if let data = "\(prompt)".data(using: .utf8) {
        FileHandle.standardError.write(data)
    }

    // Disable terminal echo
    var oldTermios = termios()
    tcgetattr(STDIN_FILENO, &oldTermios)
    var newTermios = oldTermios
    newTermios.c_lflag &= ~UInt(ECHO)
    tcsetattr(STDIN_FILENO, TCSANOW, &newTermios)

    defer {
        // Restore terminal echo
        tcsetattr(STDIN_FILENO, TCSANOW, &oldTermios)
        // Print newline after hidden input
        if let nl = "\n".data(using: .utf8) {
            FileHandle.standardError.write(nl)
        }
    }

    return readLine(strippingNewline: true)
}

/// Convert EncryptedSecretData to a [String: EncryptedSecretData] dictionary for HMAC computation
func buildSecretDataMap(from secrets: [String: EncryptedSecret]) throws -> [String: EncryptedSecretData] {
    var map: [String: EncryptedSecretData] = [:]
    for (name, secret) in secrets {
        map[name] = try secret.toEncryptedSecretData()
    }
    return map
}
