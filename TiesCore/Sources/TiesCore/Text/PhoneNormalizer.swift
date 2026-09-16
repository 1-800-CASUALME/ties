import Foundation
import PhoneNumberKit

/// Normalizes phone numbers to E.164 (`+15550100100`) and to digits-only form.
public enum PhoneNormalizer {
    // PhoneNumberUtility is expensive to construct (it parses PhoneNumberKit's metadata
    // tables), so we build one instance and share it. It isn't `Sendable`-annotated by
    // PhoneNumberKit, but its `parse`/`format` APIs are documented as thread-safe, so a
    // `nonisolated(unsafe)` shared instance is safe under Swift 6 strict concurrency.
    nonisolated(unsafe) private static let utility = PhoneNumberUtility()

    /// Parses `raw` (optionally using `defaultRegion` when it has no country code) and formats
    /// it as E.164. Returns `nil` when `raw` cannot be parsed as a phone number.
    public static func e164(_ raw: String, defaultRegion: String) -> String? {
        guard let number = try? utility.parse(raw, withRegion: defaultRegion, ignoreType: true) else {
            return nil
        }
        return utility.format(number, toType: .e164)
    }

    /// Keeps only the numeric characters in `raw`, discarding everything else.
    public static func digits(_ raw: String) -> String {
        String(raw.filter(\.isNumber))
    }
}
