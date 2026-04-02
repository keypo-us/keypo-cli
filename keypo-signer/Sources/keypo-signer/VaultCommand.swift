import ArgumentParser
import Foundation
import KeypoCore

struct VaultCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vault",
        abstract: "Manage encrypted secrets with Secure Enclave protection",
        discussion: """
        Examples:
          keypo-signer vault init
          keypo-signer vault set API_KEY --vault open
          keypo-signer vault exec --allow API_KEY -- npm start
          keypo-signer vault exec --session my-session -- npm start
        """,
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
            VaultBackupCommand.self,
            VaultRestoreCommand.self,
            VaultBackupResetCommand.self,
            VaultBackupInfoCommand.self,
            SessionCommand.self,
        ]
    )
}

func makeVaultStore(_ globals: GlobalOptions) -> any VaultStoring {
    if let configPath = globals.config {
        return VaultStore(configPath: configPath)
    }
    let keychainStore = KeychainVaultStore()
    let fileStore = VaultStore()
    do {
        let migrated = try VaultMigrator.migrateIfNeeded(from: fileStore, to: keychainStore)
        if migrated > 0, !globals.quiet {
            writeStderrRaw("Migrated \(migrated) vault tier(s) from vault.json to Keychain")
        }
    } catch {
        writeStderrWarning("vault migration failed: \(error). Using file store as fallback.")
        return fileStore
    }
    return keychainStore
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

// buildSecretDataMap is now in KeypoCore.VaultStore (public free function)
