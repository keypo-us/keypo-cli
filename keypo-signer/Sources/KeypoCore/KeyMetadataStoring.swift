import Foundation

/// Protocol for key metadata persistence. Both file-based and Keychain-based stores conform.
public protocol KeyMetadataStoring {
    /// The config directory (e.g. ~/.keypo). Both stores provide this.
    var configDir: URL { get }

    func loadKeys() throws -> [KeyMetadata]

    /// Throws storeError if keyId already exists.
    func addKey(_ key: KeyMetadata) throws

    /// No-op if keyId does not exist.
    func removeKey(keyId: String) throws

    /// Updates metadata fields for an existing key.
    /// - Important: `key.dataRepresentation` MUST match the stored value.
    ///   To change the SE token (key rotation), use `replaceKey`.
    /// - Throws: storeError if key not found or dataRepresentation differs.
    func updateKey(_ key: KeyMetadata) throws

    /// Atomically replace a key's metadata including dataRepresentation.
    /// Used exclusively for key rotation.
    func replaceKey(_ key: KeyMetadata) throws

    func incrementSignCount(keyId: String) throws

    /// Returns nil if keyId does not exist.
    func findKey(keyId: String) throws -> KeyMetadata?
}
