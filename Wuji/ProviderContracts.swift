import CryptoKit
import Foundation

enum ProviderLimits {
    static let maximumPromptBytes = 4_096
    static let maximumRequestBodyBytes = 64 * 1_024
    static let maximumModelBytes = 256
    static let maximumCredentialBytes = 1_024
    static let maximumResponseBodyBytes = 256 * 1_024
    static let maximumOutputBytes = 8_192
    static let maximumChoices = 8
    static let maximumTurnMessages = 24
    static let maximumTurnMessageBytes = 8_192
    static let maximumToolDefinitions = 3
    static let maximumToolCalls = 3
    static let maximumToolNameBytes = 64
    static let maximumToolArgumentsBytes = 1_024
    static let maximumToolCallIDBytes = 128
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
    case invalidToolExchange
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
        case .invalidToolExchange:
            return "provider tool exchange rejected"
        case .responseTooLarge:
            return "provider response exceeded limit"
        }
    }
}

enum ProviderToolExchangeRejectionReason: String, Codable, Equatable, Sendable {
    case noToolCallsWithInvalidFinishOrContent = "no_tool_calls_with_invalid_finish_or_content"
    case toolCallCount = "tool_call_count"
    case envelopeType = "envelope_type"
    case idMissingOrInvalid = "id_missing_or_invalid"
    case idDuplicate = "id_duplicate"
    case toolNameMissingOrInvalid = "tool_name_missing_or_invalid"
    case toolNameNotAllowed = "tool_name_not_allowed"
    case argumentsMissing = "arguments_missing"
    case argumentsTooLarge = "arguments_too_large"
    case assistantContentTooLarge = "assistant_content_too_large"
}

struct ProviderToolExchangeDiagnostic: Codable, Equatable, Sendable {
    let reason: ProviderToolExchangeRejectionReason
    let toolCallCount: Int
    let finishReasonPresent: Bool
    let finishReasonByteCount: Int
    let assistantContentPresent: Bool
    let assistantContentByteCount: Int
    let envelopeTypeIsFunction: Bool
    let toolCallIDPresent: Bool
    let toolCallIDByteCount: Int
    let toolNamePresent: Bool
    let toolNameByteCount: Int
    let argumentsPresent: Bool
    let argumentsByteCount: Int
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

enum ProviderTurnRole: String, Codable, Sendable {
    case system
    case user
    case assistant
    case tool
}

struct ProviderTurnToolCall: Codable, Equatable, Sendable, CustomStringConvertible {
    let id: String
    let name: String
    let arguments: String

    var description: String {
        "ProviderTurnToolCall(id: \(id), name: \(name), argumentBytes: \(arguments.utf8.count))"
    }
}

struct ProviderTurnMessage: Codable, Equatable, Sendable, CustomStringConvertible {
    let role: ProviderTurnRole
    let content: String?
    let toolCalls: [ProviderTurnToolCall]
    let toolCallID: String?

    init(
        role: ProviderTurnRole,
        content: String? = nil,
        toolCalls: [ProviderTurnToolCall] = [],
        toolCallID: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }

    var description: String {
        "ProviderTurnMessage(role: \(role.rawValue), contentBytes: \(content?.utf8.count ?? 0), toolCalls: \(toolCalls.count), hasToolCallID: \(toolCallID != nil))"
    }
}

struct ProviderToolProperty: Codable, Equatable, Sendable {
    let type: String
    let description: String
}

struct ProviderToolParameters: Codable, Equatable, Sendable {
    let type: String
    let properties: [String: ProviderToolProperty]
    let required: [String]
    let additionalProperties: Bool
}

struct ProviderToolDefinition: Codable, Equatable, Sendable, CustomStringConvertible {
    let name: String
    let descriptionText: String
    let parameters: ProviderToolParameters

    enum CodingKeys: String, CodingKey {
        case name
        case descriptionText = "description"
        case parameters
    }

    var description: String {
        "ProviderToolDefinition(name: \(name), properties: \(parameters.properties.count))"
    }
}

struct ProviderInferenceRequest: Equatable, Sendable, CustomStringConvertible {
    let messages: [ProviderTurnMessage]
    let tools: [ProviderToolDefinition]
    let requireTool: Bool

    var description: String {
        "ProviderInferenceRequest(messages: \(messages.count), tools: \(tools.map(\.name)), requireTool: \(requireTool))"
    }
}

enum ProviderInferenceDecision: Equatable, Sendable, CustomStringConvertible {
    case toolCalls(ProviderTurnMessage, [ProviderTurnToolCall])
    case finish(ProviderTurnMessage)

    var description: String {
        switch self {
        case let .toolCalls(_, calls):
            return "provider selected \(calls.count) typed tool calls"
        case let .finish(message):
            return "provider finished with \(message.content?.utf8.count ?? 0) content bytes"
        }
    }
}

enum ProviderInferenceOutcome: Equatable, Sendable, CustomStringConvertible {
    case decision(ProviderInferenceDecision)
    case failure(ProviderFailure)
    case unknown(ProviderUnknown)

    var description: String {
        switch self {
        case let .decision(decision):
            return decision.description
        case let .failure(failure):
            return failure.description
        case let .unknown(unknown):
            return unknown.description
        }
    }
}

protocol AgentInferenceProvider: Sendable {
    var providerID: String { get }
    func infer(request: ProviderInferenceRequest, requestID: UUID) async -> ProviderInferenceOutcome
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
