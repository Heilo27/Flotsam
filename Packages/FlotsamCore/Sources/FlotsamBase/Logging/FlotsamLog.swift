import Foundation
import os

/// One category per module (FRD-000 section on logging).
public enum LogCategory: String, CaseIterable, Sendable {
    case core, capture, screenshots, library, organize, triggers, shelf, storage, settings
}

/// Keys allowed in an error or log context. Free text is not a key.
public enum LogKey: String, Sendable {
    case itemId, count, byteSize, durationMs, bundleId, kind, step, limitBytes
}

/// Values allowed in an error or log context. There is deliberately no free-text case:
/// clip text, paths, URLs and keystrokes can never be logged (TRUTHS anti-truth A4).
public enum LogSafeValue: Sendable, Equatable {
    case int(Int)
    case bool(Bool)
    case id(UUID)
    case bundleId(String)
    case bytes(Int)
    case milliseconds(Int)

    var rendered: String {
        switch self {
        case .int(let value): String(value)
        case .bool(let value): String(value)
        case .id(let value): value.uuidString
        case .bundleId(let value): value
        case .bytes(let value): "\(value)B"
        case .milliseconds(let value): "\(value)ms"
        }
    }
}

public enum FlotsamLog {
    public static let fallbackSubsystem = "io.github.heilo27.Flotsam"

    public static func logger(_ category: LogCategory) -> Logger {
        Logger(subsystem: Bundle.main.bundleIdentifier ?? fallbackSubsystem, category: category.rawValue)
    }

    /// Logs an error's code, static message and safe context only.
    public static func log(_ error: FlotsamError, category: LogCategory) {
        let logger = logger(category)
        let context = error.context
            .map { "\($0.key.rawValue)=\($0.value.rendered)" }
            .sorted()
            .joined(separator: " ")
        let message = "\(error.internalMessage)"
        switch error.severity {
        case .fatal: logger.critical("\(error.code.rawValue, privacy: .public) \(message, privacy: .public) \(context, privacy: .public)")
        case .error: logger.error("\(error.code.rawValue, privacy: .public) \(message, privacy: .public) \(context, privacy: .public)")
        case .warning: logger.notice("\(error.code.rawValue, privacy: .public) \(message, privacy: .public) \(context, privacy: .public)")
        case .info: logger.info("\(error.code.rawValue, privacy: .public) \(message, privacy: .public) \(context, privacy: .public)")
        }
    }
}
