import ArgumentParser
import Foundation
import KeypoCore

extension KeyPolicy: ExpressibleByArgument {}

struct KeypoSigner: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "keypo-signer",
        abstract: "Manage P-256 signing keys in the Apple Secure Enclave",
        version: keypoVersion,
        subcommands: [
            CreateCommand.self,
            ListCommand.self,
            InfoCommand.self,
            SignCommand.self,
            DeleteCommand.self,
            RotateCommand.self,
            VerifyCommand.self,
            VaultCommand.self,
        ]
    )
}

// MARK: - Global Options

struct GlobalOptions: ParsableArguments {
    @Option(name: .long, help: "Output format: json, raw, or pretty")
    var format: OutputFormat = .json

    @Flag(name: .long, help: "Suppress informational messages")
    var quiet: Bool = false

    @Option(name: .long, help: "Path to config directory")
    var config: String?
}

enum OutputFormat: String, ExpressibleByArgument, CaseIterable {
    case json
    case raw
    case pretty
}

// MARK: - Output Helpers

func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
}

func writeStdout(_ string: String) {
    if let data = string.data(using: .utf8) {
        FileHandle.standardOutput.write(data)
    }
}

func writeStderr(_ string: String) {
    if let data = "error: \(string)\n".data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}

func writeStderrWarning(_ string: String) {
    if let data = "warning: \(string)\n".data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}

func writeStderrRaw(_ string: String) {
    if let data = "\(string)\n".data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}

func outputJSON<T: Encodable>(_ value: T) throws {
    let encoder = makeEncoder()
    let data = try encoder.encode(value)
    FileHandle.standardOutput.write(data)
    writeStdout("\n")
}

func makeStore(_ globals: GlobalOptions) -> any KeyMetadataStoring {
    if let configPath = globals.config {
        return KeyMetadataStore(configPath: configPath)
    }
    let keychainStore = KeychainMetadataStore()
    let fileStore = KeyMetadataStore()
    do {
        let migrated = try KeyMetadataMigrator.migrateIfNeeded(from: fileStore, to: keychainStore)
        if migrated > 0, !globals.quiet {
            writeStderrRaw("Migrated \(migrated) key(s) from keys.json to Keychain")
        }
    } catch {
        writeStderrWarning("key migration failed: \(error). Using file store as fallback.")
        return fileStore
    }
    return keychainStore
}

func makeISOFormatter() -> ISO8601DateFormatter {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}

KeypoSigner.main()
