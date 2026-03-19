import Foundation

/// Check iCloud availability for backup features.
public enum iCloudStatus {

    /// Check if iCloud Drive appears to be available.
    /// This checks for the existence of the Mobile Documents directory.
    public static var isICloudDriveAvailable: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let iCloudDrivePath = home.appendingPathComponent(
            "Library/Mobile Documents/com~apple~CloudDocs"
        )
        return FileManager.default.fileExists(atPath: iCloudDrivePath.path)
    }

    /// Check if the user appears to be signed into iCloud.
    /// Uses FileManager.default.ubiquityIdentityToken as a proxy.
    public static var isSignedIntoICloud: Bool {
        return FileManager.default.ubiquityIdentityToken != nil
    }
}
