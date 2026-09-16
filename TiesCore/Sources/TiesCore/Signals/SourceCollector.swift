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
///
/// A collection run brackets its people with `beginSession()` / `endSession()`, so a collector
/// backed by a multi-gigabyte store copies it once for the whole run instead of once per person.
/// Both have do-nothing defaults: a collector with nothing to set up conforms by implementing
/// `status()` and `collect(for:since:)` alone, and `collect` works on its own either way.
public protocol SourceCollector: Sendable {
    var id: String { get }
    var displayName: String { get }
    func status() -> SourceStatus
    func collect(for input: ProbeInput, since: Date?) async throws -> LocalSignals
    /// Opens whatever the whole run shares. Throws the same `SourceError` `collect` would.
    func beginSession() async throws
    /// Releases it. Always called once a run ends, including a cancelled one.
    func endSession() async
}

extension SourceCollector {
    public func beginSession() async throws {}
    public func endSession() async {}
}

extension SourceStatus {
    /// The status of a source that lives in one file, decided by opening it rather than by
    /// `fileExists`: without Full Disk Access macOS denies `stat` too, so a protected store looks
    /// exactly like a missing one until the error from a real open is read.
    static func ofFile(at url: URL) -> SourceStatus {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            try? handle.close()
            return .ready
        } catch {
            if SourceSnapshot.isPermissionError(error) { return .needsAccess }
            return FileManager.default.fileExists(atPath: url.path) ? .needsAccess : .unavailable
        }
    }
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
        do {
            let queue = try DatabaseQueue(path: dir.appendingPathComponent(url.lastPathComponent).path, configuration: config)
            return SourceSnapshot(reader: queue, directory: dir)
        } catch {
            // A torn or corrupt copy must not leave its temp directory behind.
            try? fm.removeItem(at: dir)
            throw SourceError.malformed("\(error)")
        }
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

/// The one `SourceSnapshot` a file-backed collector keeps open for a whole collection run.
///
/// A collector is a `Sendable` value type shared across the people of a run, so the snapshot it
/// holds lives in this reference box behind a lock rather than in the collector itself.
final class SnapshotSession: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: SourceSnapshot?
    private var opened = 0

    /// The snapshot `beginSession()` opened, or `nil` when `collect` is being used on its own.
    var current: SourceSnapshot? { lock.withLock { snapshot } }

    /// How many snapshots this collector has opened: one for a whole run that begins a session,
    /// otherwise one per `collect`. Read by the tests that hold the "copy the store once" rule.
    var snapshotsOpened: Int { lock.withLock { opened } }

    /// Opens the run's snapshot, closing any earlier one it replaces.
    func begin(_ url: URL) throws {
        let fresh = try SourceSnapshot.open(url)
        let previous: SourceSnapshot? = lock.withLock {
            let previous = snapshot
            snapshot = fresh
            opened += 1
            return previous
        }
        previous?.close()
    }

    /// A snapshot for one `collect` outside a session. The caller closes it.
    func single(_ url: URL) throws -> SourceSnapshot {
        let fresh = try SourceSnapshot.open(url)
        lock.withLock { opened += 1 }
        return fresh
    }

    func end() {
        let previous: SourceSnapshot? = lock.withLock {
            let previous = snapshot
            snapshot = nil
            return previous
        }
        previous?.close()
    }
}
