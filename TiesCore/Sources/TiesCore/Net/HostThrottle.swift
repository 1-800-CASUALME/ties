import Foundation

/// Spaces out requests to the same host so Ties doesn't hammer external services.
/// Each host gets its own minimum interval between requests (falling back to a
/// default), and a host can be pushed further out by `backoff` (e.g. after a
/// 429/503 response) independent of the regular interval.
public actor HostThrottle {
    private let defaultInterval: TimeInterval
    private let perHost: [String: TimeInterval]
    private var lastRequest: [String: Date] = [:]
    private var notBefore: [String: Date] = [:]

    public init(
        defaultInterval: TimeInterval = 0.5,
        perHost: [String: TimeInterval] = ["api.github.com": 1.0, "api.gravatar.com": 0.2]
    ) {
        self.defaultInterval = defaultInterval
        self.perHost = perHost
    }

    /// Sleeps until the interval since the last request to `host` has elapsed, and
    /// until any pending `backoff` deadline for `host` has passed. Records the
    /// request time on return.
    public func waitTurn(host: String) async {
        let interval = perHost[host] ?? defaultInterval
        let earliestFromInterval = (lastRequest[host] ?? .distantPast).addingTimeInterval(interval)
        let earliest = max(earliestFromInterval, notBefore[host] ?? .distantPast)

        let delay = earliest.timeIntervalSince(.now)
        if delay > 0 {
            try? await Task.sleep(for: .seconds(delay))
        }

        lastRequest[host] = .now
    }

    /// Pushes the next allowed request to `host` at least `seconds` into the future.
    public func backoff(host: String, seconds: TimeInterval) {
        notBefore[host] = Date.now.addingTimeInterval(seconds)
    }
}
