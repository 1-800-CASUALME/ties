import Foundation

/// Builds `.emlx` files the way Mail stores them — a byte-count line, that many bytes of RFC 822
/// message, then a per-message plist the parser ignores — so the Mail collector is tested without
/// ever opening a real mailbox.
enum EMLXFixture {
    static let person = "sara@acme.com"
    static let user = "asim@example.com"

    /// Mail writes one of these after every message; `EMLX.parse` must skip it.
    static let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>flags</key><integer>8623620</integer></dict></plist>
        """

    // MARK: - The three messages of the standard mailbox

    /// From the person, signature layout A, with the display name RFC 2047 encoded ("Sarita").
    static let fromPersonWithSignature = """
        From: =?UTF-8?B?U2FyaXRh?= <\(person)>
        To: Asim <\(user)>
        Subject: Re: the call
        Date: Tue, 1 Sep 2026 10:00:00 +0300
        Content-Type: text/plain; charset=utf-8

        Thanks for the call.

        Best,
        Sara Ahmed
        Senior Product Manager | Acme Corp
        +966 50 123 4567
        https://www.linkedin.com/in/sara-ahmed/
        """

    /// To the person, from the user — it counts as contact, but its signature is the *user's* and
    /// must never end up in the person's signals.
    static let toPerson = """
        From: Asim Alteeq <\(user)>
        To: Sara Ahmed <\(person)>
        Subject: The call
        Date: Mon, 31 Aug 2026 09:00:00 +0300
        Content-Type: text/plain; charset=utf-8

        Hi Sara, are we still on for tomorrow?

        --
        Asim
        Founder | Ties
        https://github.com/asim
        """

    /// From the person, but nothing except a quoted reply: no signature may be read out of it.
    static let quotedReplyOnly = """
        From: Sarita <\(person)>
        To: Asim <\(user)>
        Subject: Re: The call
        Date: Wed, 2 Sep 2026 08:00:00 +0300
        Content-Type: text/plain; charset=utf-8

        On Mon, 31 Aug 2026, Asim wrote:
        > Hi Sara, are we still on for tomorrow?
        > --
        > Asim
        > Founder | Ties
        > https://github.com/asim-imposter
        > +1 555 000 1111
        """

    // MARK: - Building

    /// A fresh empty directory under the temp directory.
    static func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ties-mail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The `.emlx` container around one RFC 822 message. `countPadding` left-pads the byte count
    /// with spaces, which Mail itself does and the parser has to tolerate.
    static func container(_ message: String, countPadding: Int = 0) -> Data {
        let body = Data(message.utf8)
        let count = String(body.count)
        let header = String(repeating: " ", count: countPadding) + count + "\n"
        var data = Data(header.utf8)
        data.append(body)
        data.append(Data("\n\(plist)\n".utf8))
        return data
    }

    @discardableResult
    static func write(_ message: String, named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try container(message).write(to: url)
        return url
    }

    /// A `~/Library/Mail`-shaped tree holding the three standard messages, newest last.
    static func mailbox() throws -> URL {
        let root = try temporaryRoot()
        let messages = root.appendingPathComponent("V10/INBOX.mbox/Messages", isDirectory: true)
        try FileManager.default.createDirectory(at: messages, withIntermediateDirectories: true)
        try write(fromPersonWithSignature, named: "1.emlx", in: messages)
        try write(toPerson, named: "2.emlx", in: messages)
        try write(quotedReplyOnly, named: "3.emlx", in: messages)
        return root
    }

    /// A mailbox of `count` plain messages from the person, one per day going back from
    /// 2026-09-10, for the 50-per-address cap.
    static func mailbox(messageCount count: Int) throws -> URL {
        let root = try temporaryRoot()
        let messages = root.appendingPathComponent("V10/INBOX.mbox/Messages", isDirectory: true)
        try FileManager.default.createDirectory(at: messages, withIntermediateDirectories: true)
        for index in 0..<count {
            let day = 10 - (index % 10)
            let month = index < 10 ? "Sep" : "Aug"
            let message = """
                From: Sarita <\(person)>
                To: Asim <\(user)>
                Subject: Note \(index)
                Date: \(day) \(month) 2026 0\(index % 8):00:00 +0300
                Content-Type: text/plain; charset=utf-8

                Note number \(index).
                """
            try write(message, named: "\(index).emlx", in: messages)
        }
        return root
    }
}
