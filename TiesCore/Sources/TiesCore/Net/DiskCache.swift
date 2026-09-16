import Foundation
import CryptoKit

/// A flat-file, TTL-based disk cache. Each entry is stored as a file named by the
/// SHA-256 hex digest of its key; the file's own modification date doubles as the
/// entry's timestamp, so there's no sidecar metadata to keep in sync.
public final class DiskCache: Sendable {
    public let directory: URL
    public let ttl: TimeInterval

    public init(directory: URL, ttl: TimeInterval = 7 * 24 * 3600) {
        self.directory = directory
        self.ttl = ttl
    }

    /// `~/Library/Caches/Ties/http`
    public static var defaultDirectory: URL {
        let cachesBase = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return cachesBase
            .appendingPathComponent("Ties", isDirectory: true)
            .appendingPathComponent("http", isDirectory: true)
    }

    /// Returns the cached data for `key`, or `nil` if there's no entry or it's older than `ttl`.
    public func get(_ key: String) -> Data? {
        let fileURL = fileURL(for: key)
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
            let modificationDate = attributes[.modificationDate] as? Date
        else { return nil }

        guard Date.now.timeIntervalSince(modificationDate) < ttl else { return nil }
        return try? Data(contentsOf: fileURL)
    }

    /// Writes `data` for `key`, creating the cache directory on first use.
    public func set(_ key: String, _ data: Data) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL(for: key), options: .atomic)
    }

    /// Deletes every cached body. Used by "Delete Everything"; the directory is recreated on
    /// the next write.
    public func clear() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func fileURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hex)
    }
}
