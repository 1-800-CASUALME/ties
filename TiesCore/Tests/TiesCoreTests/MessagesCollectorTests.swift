import Foundation
import GRDB
import Testing
@testable import TiesCore

/// Nothing here is shared between tests — the visit counter is per collector — so the suite
/// runs in parallel with the rest.
struct MessagesCollectorTests {
    @Test func collectsHonorificLinkAndCounts() async throws {
        let db = try ChatDBFixture.make(at: tmp())
        let c = MessagesCollector(chatDB: db, userNames: ["Asim"])
        let s = try await c.collect(for: input(name: ("Sara", "Ahmed"), phones: [ChatDBFixture.personHandle]), since: nil)

        #expect(s.honorifics == ["dr"])
        #expect(s.links == ["https://linkedin.com/in/sara-ahmed"])
        // Her own group message plus both lines of the one-to-one chat — not the three messages
        // the group's other participant wrote about her.
        #expect(s.interactions == ChatDBFixture.expectedInteractions)
        #expect(s.sources == ["messages"])
        let last = try #require(s.lastContact)
        let expected = Date.now.addingTimeInterval(-ChatDBFixture.lastContactDaysAgo * 86_400)
        #expect(abs(last.timeIntervalSince(expected)) < 60)
        // The group chat's name is company-ish, and the person's own name never becomes an alias.
        #expect(s.companies == [ChatDBFixture.groupName])
        #expect(s.aliases.isEmpty)
        #expect(!s.isEmpty)
    }

    @Test func capsAtFiveHundredMessages() async throws {
        let db = try ChatDBFixture.make(at: tmp())
        let c = MessagesCollector(chatDB: db, userNames: [])
        let s = try await c.collect(for: input(name: ("Sara", "Ahmed"), phones: [ChatDBFixture.personHandle]), since: nil)

        #expect(ChatDBFixture.fillerCount + ChatDBFixture.recentCount > MessagesCollector.messageCap)
        #expect(c.lastVisited == MessagesCollector.messageCap)
        // The cap keeps the newest messages, so the recent ones still produce their signals.
        #expect(s.honorifics == ["dr"])
    }

    @Test func sinceSkipsOlderMessages() async throws {
        let db = try ChatDBFixture.make(at: tmp())
        let c = MessagesCollector(chatDB: db, userNames: [])
        let s = try await c.collect(
            for: input(name: ("Sara", "Ahmed"), phones: [ChatDBFixture.personHandle]),
            since: Date.now.addingTimeInterval(-43.5 * 86_400)
        )

        // Only her own last group message and the one-to-one chat are newer than the cutoff.
        #expect(s.interactions == 3)
        #expect(s.honorifics.isEmpty)
        #expect(s.links == ["https://linkedin.com/in/sara-ahmed"])
    }

    @Test func groupTrafficIsNotContactWithThePerson() async throws {
        let db = try ChatDBFixture.make(at: tmp())
        let c = MessagesCollector(chatDB: db, userNames: [])
        // The other participant's handle sees the same group, but only their own messages and
        // no one-to-one chat: the three lines they wrote, and nothing of hers.
        let s = try await c.collect(for: input(name: ("Omar", "K"), phones: [ChatDBFixture.otherHandle]), since: nil)

        #expect(s.interactions == 3)
        // The group is still theirs, so its company-ish name still counts.
        #expect(s.companies == [ChatDBFixture.groupName])
    }

    @Test func aSessionCopiesTheStoreOnce() async throws {
        let db = try ChatDBFixture.make(at: tmp())
        let probe = input(name: ("Sara", "Ahmed"), phones: [ChatDBFixture.personHandle])

        let session = MessagesCollector(chatDB: db, userNames: [])
        try await session.beginSession()
        let first = try await session.collect(for: probe, since: nil)
        let second = try await session.collect(for: probe, since: nil)
        #expect(session.snapshotsOpened == 1)
        // The reused copy answers exactly as the first read did (`collectedAt` is the only field
        // that moves between two runs).
        #expect(first.honorifics == second.honorifics)
        #expect(first.links == second.links)
        #expect(first.interactions == second.interactions)
        await session.endSession()

        // Used without a session, every collection copies the store for itself.
        let loose = MessagesCollector(chatDB: db, userNames: [])
        _ = try await loose.collect(for: probe, since: nil)
        _ = try await loose.collect(for: probe, since: nil)
        #expect(loose.snapshotsOpened == 2)
    }

    @Test func beginningASessionOnAMissingStoreThrows() async {
        let missing = MessagesCollector(chatDB: URL(fileURLWithPath: "/nonexistent/chat.db"), userNames: [])
        await #expect(throws: SourceError.self) { try await missing.beginSession() }
    }

    @Test func returnsEmptySignalsWithoutHandles() async throws {
        let db = try ChatDBFixture.make(at: tmp())
        let c = MessagesCollector(chatDB: db, userNames: [])
        let s = try await c.collect(for: input(name: ("Sara", "Ahmed")), since: nil)
        #expect(s.isEmpty)
        #expect(s.sources.isEmpty)
        #expect(s.interactions == 0)

        // A handle nobody in this database uses reads the same way.
        let unknown = try await c.collect(for: input(name: ("Sara", "Ahmed"), phones: ["+15550100100"]), since: nil)
        #expect(unknown.isEmpty)
        #expect(unknown.sources.isEmpty)
    }

    @Test func statusReportsMissingAndUnreadable() throws {
        let missing = MessagesCollector(chatDB: URL(fileURLWithPath: "/nonexistent/chat.db"), userNames: [])
        #expect(missing.status() == .unavailable)

        let db = try ChatDBFixture.make(at: tmp())
        #expect(MessagesCollector(chatDB: db, userNames: []).status() == .ready)

        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: db.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: db.path) }
        // Full Disk Access is the real-world version of this; root would still read the file.
        if !FileManager.default.isReadableFile(atPath: db.path) {
            #expect(MessagesCollector(chatDB: db, userNames: []).status() == .needsAccess)
        }
    }

    @Test func collectingAnUnreachableStoreSaysWhy() async throws {
        let probe = input(name: ("Sara", "Ahmed"), phones: [ChatDBFixture.personHandle])
        let missing = MessagesCollector(chatDB: URL(fileURLWithPath: "/nonexistent/chat.db"), userNames: [])
        do {
            _ = try await missing.collect(for: probe, since: nil)
            Issue.record("expected SourceError.unavailable")
        } catch SourceError.unavailable {
        } catch {
            Issue.record("expected SourceError.unavailable, got \(error)")
        }

        // A store that is there but unreadable is the Full Disk Access case, and has to read
        // as such rather than as a missing file.
        let db = try ChatDBFixture.make(at: tmp())
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: db.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: db.path) }
        guard !FileManager.default.isReadableFile(atPath: db.path) else { return }  // running as root
        do {
            _ = try await MessagesCollector(chatDB: db, userNames: []).collect(for: probe, since: nil)
            Issue.record("expected SourceError.needsAccess")
        } catch SourceError.needsAccess {
        } catch {
            Issue.record("expected SourceError.needsAccess, got \(error)")
        }
    }

    @Test func typedStreamExtractsText() {
        #expect(TypedStream.text(from: TypedStreamFixture.helloWorld) == "Hello world")
        // The 0x81 + UInt16 little-endian length, used once the string passes 127 bytes.
        #expect(TypedStream.text(from: TypedStreamFixture.longText) == String(repeating: "ب", count: 200))
        #expect(TypedStream.text(from: TypedStreamFixture.withoutMarker) == nil)
        #expect(TypedStream.text(from: Data()) == nil)
        // An archive cut short reads as "no text", never off the end of the buffer.
        #expect(TypedStream.text(from: TypedStreamFixture.truncatedAfterMarker) == nil)
        #expect(TypedStream.text(from: TypedStreamFixture.truncatedBeforeLength) == nil)
        #expect(TypedStream.text(from: TypedStreamFixture.truncatedPayload) == nil)
        #expect(TypedStream.text(from: TypedStreamFixture.archive("مرحبا Sara")) == "مرحبا Sara")
    }

    @Test func snapshotCopiesWAL() throws {
        let directory = tmp()
        let url = directory.appendingPathComponent("wal.db")
        // A pool puts the database in WAL mode; the row below stays in the -wal file as long as
        // the pool is alive and unchecked, so a snapshot that copied only the .db would miss it.
        let pool = try DatabasePool(path: url.path)
        try pool.write { db in
            try db.execute(sql: "CREATE TABLE t (v TEXT)")
            try db.execute(sql: "INSERT INTO t (v) VALUES ('hello')")
        }
        #expect(FileManager.default.fileExists(atPath: url.path + "-wal"))

        let snapshot = try SourceSnapshot.open(url)
        #expect(FileManager.default.fileExists(atPath: snapshot.directory.appendingPathComponent("wal.db-wal").path))
        #expect(try snapshot.reader.read { db in try String.fetchOne(db, sql: "SELECT v FROM t") } == "hello")

        snapshot.close()
        #expect(!FileManager.default.fileExists(atPath: snapshot.directory.path))
        snapshot.close()  // idempotent
        #expect(!FileManager.default.fileExists(atPath: snapshot.directory.path))
        // The source database is untouched by all of that.
        #expect(try pool.read { db in try String.fetchOne(db, sql: "SELECT v FROM t") } == "hello")
    }

    @Test func snapshotOfAMissingFileIsUnavailable() {
        #expect(throws: SourceError.self) { _ = try SourceSnapshot.open(URL(fileURLWithPath: "/nonexistent/chat.db")) }
    }

    @Test func permissionErrorsAreRecognised() {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: 13)
        #expect(SourceSnapshot.isPermissionError(posix))
        #expect(SourceSnapshot.isPermissionError(
            NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadNoPermission.rawValue)
        ))
        // Foundation usually wraps the POSIX error rather than reporting it directly.
        #expect(SourceSnapshot.isPermissionError(
            NSError(domain: NSCocoaErrorDomain, code: 512, userInfo: [NSUnderlyingErrorKey: posix])
        ))
        #expect(!SourceSnapshot.isPermissionError(NSError(domain: NSPOSIXErrorDomain, code: 2)))
    }
}
