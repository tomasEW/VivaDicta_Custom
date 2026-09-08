// Copyright © 2026 Anton Novoselov. All rights reserved.

import Foundation
import os

public enum NetworkRetry {
    public static let defaultTimeout: TimeInterval = 120
    public static let maxRetries = 2
    public static let initialRetryDelay: Duration = .seconds(1)

    /// A status-aware error that preserves the provider's `Retry-After` hint
    /// while the generic retry loop is deciding whether to try again.
    public struct RetryableHTTPError: Error, Sendable {
        public let statusCode: Int
        public let message: String
        public let retryAfter: Duration?

        public init(statusCode: Int, message: String, retryAfter: Duration? = nil) {
            self.statusCode = statusCode
            self.message = message
            self.retryAfter = retryAfter
        }

        fileprivate var transcriptionError: CloudTranscriptionError {
            .apiRequestFailed(statusCode: statusCode, message: message)
        }
    }

    /// Executes an async operation with retry logic for transient failures.
    /// - Parameters:
    ///   - logger: Logger for recording retry attempts.
    ///   - operation: The async throwing operation to execute.
    /// - Returns: The result of the operation.
    public static func withRetry<T>(
        logger: Logger,
        isolation: isolated (any Actor)? = #isolation,
        operation: () async throws -> T
    ) async throws -> T {
        var retries = 0
        var currentDelay = initialRetryDelay

        while true {
            do {
                try Task.checkCancellation()
                return try await operation()
            } catch let error as RetryableHTTPError {
                guard shouldRetry(statusCode: error.statusCode, retries: retries) else {
                    throw error.transcriptionError
                }
                retries += 1
                let delay = RetryAfter.capped(error.retryAfter ?? currentDelay)
                logger.warning("HTTP \(error.statusCode, privacy: .public) failed, retrying in \(delay)... (Attempt \(retries)/\(maxRetries))")
                try await Task.sleep(for: delay)
                currentDelay = RetryAfter.capped(currentDelay * 2)
            } catch let error as CloudTranscriptionError {
                guard shouldRetry(error: error, retries: retries) else {
                    throw error
                }
                retries += 1
                let delay = RetryAfter.capped(currentDelay)
                logger.warning("Request failed, retrying in \(delay)... (Attempt \(retries)/\(maxRetries))")
                try await Task.sleep(for: delay)
                currentDelay = RetryAfter.capped(currentDelay * 2)
            } catch {
                guard shouldRetryURLError(error: error, retries: retries) else {
                    throw wrapIfNetworkError(error)
                }
                retries += 1
                let delay = RetryAfter.capped(currentDelay)
                logger.warning("Network error, retrying in \(delay)... (Attempt \(retries)/\(maxRetries))")
                try await Task.sleep(for: delay)
                currentDelay = RetryAfter.capped(currentDelay * 2)
            }
        }
    }

    private static func shouldRetry(statusCode: Int, retries: Int) -> Bool {
        guard retries < maxRetries else { return false }
        return (500...599).contains(statusCode) || statusCode == 429
    }

    private static func shouldRetry(error: CloudTranscriptionError, retries: Int) -> Bool {
        guard retries < maxRetries else { return false }

        switch error {
        case .networkError:
            return true
        case .apiRequestFailed(let statusCode, _):
            // Retry on server errors (5xx) and rate limiting (429)
            return (500...599).contains(statusCode) || statusCode == 429
        default:
            return false
        }
    }

    private static func shouldRetryURLError(error: Error, retries: Int) -> Bool {
        guard retries < maxRetries else { return false }

        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }

        let retryableCodes = [
            NSURLErrorNotConnectedToInternet,
            NSURLErrorTimedOut,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorCannotConnectToHost
        ]
        return retryableCodes.contains(nsError.code)
    }

    private static func wrapIfNetworkError(_ error: Error) -> Error {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return CloudTranscriptionError.networkError(error)
        }
        return error
    }
}
