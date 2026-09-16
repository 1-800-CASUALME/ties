import Foundation
import GRDB

/// Whether a local source can be read right now.
public enum SourceStatus: Sendable, Equatable {
    case unavailable, needsAccess, ready, error(String)
}

public enum SourceError: Error, Sendable {
    case unavailable, needsAccess, malformed(String)
}

/// One local source of signals about a person (Messages, WhatsApp, Mail, Contacts).
public protocol SourceCollector: Sendable {
    var id: String { get }
    var displayName: String { get }
    func status() -> SourceStatus
    func collect(for input: ProbeInput, since: Date?) async throws -> LocalSignals
}

/// A read-only, temporary copy of a SQLite store (with its -wal/-shm), so the owning app is
/// never locked and nothing is ever written back.
public struct SourceSnapshot: Sendable {
    public let reader: DatabaseQueue
    public let directory: URL

    public static func open(_ url: URL) throws -> SourceSnapshot {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { throw SourceError.unavailable }
        let dir = fm.temporaryDirectory.appendingPathComponent("ties-snapshot-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: url.path + suffix)
            guard fm.fileExists(atPath: src.path) else { continue }
            do {
                try fm.copyItem(at: src, to: dir.appendingPathComponent(url.lastPathComponent + suffix))
            } catch {
                try? fm.removeItem(at: dir)
                if SourceSnapshot.isPermissionError(error) { throw SourceError.needsAccess }
                throw error
            }
        }
        var config = Configuration()
        config.readonly = true
        let queue = try DatabaseQueue(path: dir.appendingPathComponent(url.lastPathComponent).path, configuration: config)
        return SourceSnapshot(reader: queue, directory: dir)
    }

    public func close() {
        try? FileManager.default.removeItem(at: directory)
    }

    static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == CocoaError.fileReadNoPermission.rawValue { return true }
        if ns.domain == NSPOSIXErrorDomain, ns.code == 1 || ns.code == 13 { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError { return isPermissionError(underlying) }
        return false
    }
}
