import CryptoKit
import Foundation

enum ProviderLimits {
    static let maximumPromptBytes = 4_096
    static let maximumModelBytes = 256
    static let maximumCredentialBytes = 1_024
    static let maximumResponseBodyBytes = 256 * 1_024
    static let maximumOutputBytes = 8_192
    static let maximumChoices = 8
    static let requestTimeoutSeconds: TimeInterval = 60
}

struct ProviderCredential: @unchecked Sendable, CustomStringConvertible {
    private let rawValue: String

    init(_ rawValue: String) throws {
        let byteCount = rawValue.lengthOfBytes(using: .utf8)
        guard byteCount > 0, byteCount <= ProviderLimits.maximumCredentialBytes else {
            throw ProviderConfigurationError.invalidCredential
        }
        guard rawValue.unicodeScalars.allSatisfy({
            !CharacterSet.controlCharacters.contains($0)
        }) else {
            throw ProviderConfigurationError.invalidCredential
        }
        self.rawValue = rawValue
    }

    var description: String { "ProviderCredential(redacted)" }

    func withValue<T>(_ body: (String) throws -> T) rethrows -> T {
        try body(rawValue)
    }
}

protocol ProviderCredentialSource: Sendable {
    func credential() throws -> ProviderCredential
}

struct StaticProviderCredentialSource: ProviderCredentialSource, Sendable {
    private let storedCredential: ProviderCredential

    init(credential: ProviderCredential) {
        storedCredential = credential
    }

    func credential() throws -> ProviderCredential {
        storedCredential
    }
}

struct ProviderCompletion: Equatable, Sendable, CustomStringConvertible {
    let requestID: UUID
    let text: String
    let responseByteCount: Int
    let responseSHA256: String

    var description: String {
        "ProviderCompletion(requestID: \(requestID.uuidString), responseByteCount: \(responseByteCount), responseSHA256: \(responseSHA256))"
    }
}

enum ProviderFailure: Equatable, Sendable, CustomStringConvertible {
    case invalidInput
    case credentialUnavailable
    case evidenceWriteFailed
    case httpStatus(Int)
    case malformedResponse
    case emptyResponse
    case toolCallsRejected
    case responseTooLarge

    var description: String {
        switch self {
        case .invalidInput:
            return "provider input rejected"
        case .credentialUnavailable:
            return "provider credential unavailable"
        case .evidenceWriteFailed:
            return "provider evidence write failed"
        case let .httpStatus(status):
            return "provider HTTP status \(status)"
        case .malformedResponse:
            return "provider response malformed"
        case .emptyResponse:
            return "provider response empty"
        case .toolCallsRejected:
            return "provider tool calls rejected"
        case .responseTooLarge:
            return "provider response exceeded limit"
        }
    }
}

enum ProviderUnknown: Equatable, Sendable, CustomStringConvertible {
    case reconciliationRequired

    var description: String {
        "provider result unknown; reconciliation required"
    }
}

enum ProviderOutcome: Equatable, Sendable, CustomStringConvertible {
    case response(ProviderCompletion)
    case failure(ProviderFailure)
    case unknown(ProviderUnknown)

    var description: String {
        switch self {
        case let .response(completion):
            return completion.description
        case let .failure(failure):
            return failure.description
        case let .unknown(unknown):
            return unknown.description
        }
    }
}

protocol CloudProvider: Sendable {
    var providerID: String { get }
    func complete(prompt: String, requestID: UUID) async -> ProviderOutcome
}

enum ProviderConfigurationError: Error, Equatable, CustomStringConvertible {
    case invalidBaseURL
    case invalidModel
    case invalidCredential

    var description: String {
        switch self {
        case .invalidBaseURL:
            return "provider base URL rejected"
        case .invalidModel:
            return "provider model rejected"
        case .invalidCredential:
            return "provider credential rejected"
        }
    }
}

enum ProviderDigest {
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(_ value: String) -> String {
        sha256Hex(Data(value.utf8))
    }
}
