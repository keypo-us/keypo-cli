import ArgumentParser
import Foundation
import KeypoCore

struct VaultBackupInfoCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "backup-info",
        abstract: "Show backup status without decrypting",
        discussion: """
        Examples:
          keypo-signer vault backup-info
        """
    )

    @OptionGroup var globals: GlobalOptions

    mutating func run() throws {
        let store = makeVaultStore(globals)

        let iCloudDrive = iCloudDriveManager()
        let backupExists = iCloudDrive.backupExists()
        let previousExists = iCloudDrive.backupExists(previous: true)

        var createdAt: String?
        var deviceName: String?
        var secretCount: Int?
        var vaultNames: [String]?

        if backupExists, let blob = try iCloudDrive.readBackup() {
            createdAt = blob.createdAt
            deviceName = blob.deviceName
            secretCount = blob.secretCount
            vaultNames = blob.vaultNames
        }

        let syncedKeyAvailable = (try? KeychainSync.syncedBackupKeyExists()) ?? false

        let stateManager = BackupStateManager(configDir: store.configDir)
        let state = stateManager.read()

        let output = VaultBackupInfoOutput(
            backupExists: backupExists,
            createdAt: createdAt,
            deviceName: deviceName,
            secretCount: secretCount,
            vaultNames: vaultNames,
            previousBackupExists: previousExists,
            syncedKeyAvailable: syncedKeyAvailable,
            localSecretsNotBackedUp: state.secretsSinceBackup
        )

        switch globals.format {
        case .json:
            try outputJSON(output)
        case .raw, .pretty:
            if backupExists {
                writeStdout("Backup exists: \(secretCount ?? 0) secrets, created \(createdAt ?? "unknown")\n")
                writeStdout("Previous backup: \(previousExists ? "yes" : "no")\n")
                writeStdout("Synced key available: \(syncedKeyAvailable ? "yes" : "no")\n")
                writeStdout("Secrets not backed up: \(state.secretsSinceBackup)\n")
            } else {
                writeStdout("No backup found.\n")
            }
        }
    }
}

public struct VaultBackupInfoOutput: Codable {
    public let backupExists: Bool
    public let createdAt: String?
    public let deviceName: String?
    public let secretCount: Int?
    public let vaultNames: [String]?
    public let previousBackupExists: Bool
    public let syncedKeyAvailable: Bool
    public let localSecretsNotBackedUp: Int

    public init(backupExists: Bool, createdAt: String?, deviceName: String?,
                secretCount: Int?, vaultNames: [String]?,
                previousBackupExists: Bool, syncedKeyAvailable: Bool,
                localSecretsNotBackedUp: Int) {
        self.backupExists = backupExists
        self.createdAt = createdAt
        self.deviceName = deviceName
        self.secretCount = secretCount
        self.vaultNames = vaultNames
        self.previousBackupExists = previousBackupExists
        self.syncedKeyAvailable = syncedKeyAvailable
        self.localSecretsNotBackedUp = localSecretsNotBackedUp
    }
}
