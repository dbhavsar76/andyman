import Foundation

/// Exit codes are part of the CLI's contract with agents and scripts. Don't renumber them.
public enum ExitStatus: Int32, Sendable, Codable {
    case success = 0
    case failure = 1
    case usage = 2
    case notFound = 3
    case licenseRequired = 4
    case missingPrerequisite = 5
    case timeout = 6
}

/// An error reported to the user (or agent) with a stable machine-readable code.
public struct CLIError: Error, Sendable, Equatable, Encodable {
    /// Stable snake_case identifier, e.g. `sdk_not_found`.
    public var code: String
    public var message: String
    public var hint: String?
    public var exitStatus: ExitStatus

    public init(code: String, message: String, hint: String? = nil, exitStatus: ExitStatus = .failure) {
        self.code = code
        self.message = message
        self.hint = hint
        self.exitStatus = exitStatus
    }

    private enum CodingKeys: String, CodingKey {
        case code, message, hint, exitStatus = "exitCode"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(message, forKey: .message)
        try container.encodeIfPresent(hint, forKey: .hint)
        try container.encode(exitStatus.rawValue, forKey: .exitStatus)
    }
}

extension CLIError {
    static func sdkNotFound(_ message: String, hint: String?) -> CLIError {
        CLIError(code: "sdk_not_found", message: message, hint: hint, exitStatus: .missingPrerequisite)
    }

    static func usage(_ message: String) -> CLIError {
        CLIError(code: "usage", message: message, exitStatus: .usage)
    }
}
