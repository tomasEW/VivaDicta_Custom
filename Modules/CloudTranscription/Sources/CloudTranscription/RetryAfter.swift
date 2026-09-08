// Copyright © 2026 Anton Novoselov. All rights reserved.

import Foundation

/// Parses the delay requested by an HTTP `Retry-After` response header.
///
/// Providers commonly send the header as a number of seconds. Keeping the
/// parser in the shared networking package lets STT and LLM clients apply the
/// same cap and avoids retrying forever when a provider sends an unusually
/// large value.
public enum RetryAfter {
    public static let maximumDelay: Duration = .seconds(10)

    public static func duration(from response: HTTPURLResponse) -> Duration? {
        guard let rawValue = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = Int64(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              seconds >= 0
        else {
            return nil
        }
        return .seconds(seconds)
    }

    public static func capped(_ duration: Duration) -> Duration {
        duration > maximumDelay ? maximumDelay : duration
    }
}
