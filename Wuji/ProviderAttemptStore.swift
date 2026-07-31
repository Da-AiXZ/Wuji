import Foundation

enum ProviderAttemptPhase: String, Codable, Sendable {
    case intentRecorded = "intent_recorded"
    case succeeded
    case failed
    case reconciliationRequired = "reconciliation_required"
}

enum ProviderAttemptResultCategory: String, Codable, Sendable {
    case none
    case response
    case invalidInput = "invalid_input"
    case credentialUnavailable = "credential_unavailable"
    case evidenceWriteFailed = "evidence_write_failed"
    case httpError = "http_error"
    case malformedResponse = "malformed_response"
    case emptyResponse = "empty_response"
    case toolCallsRejected = "tool_calls_rejected"
    case responseTooLarge = "response_too_large"
    case transportUnknown = "transport_unknown"
}

struct ProviderAttemptEvidence: Codable, Equatable, Sendable {
    let requestID: UUID
    let attemptID: UUID
    let providerID: String
    let modelSHA256: String
    let recordedAt: Date
    let phase: ProviderAttemptPhase
    let resultCategory: ProviderAttemptResultCategory
    let responseByteCount: Int?
    let responseSHA256: String?
}

protocol ProviderAttemptRecording: Sendable {
    func record(_ evidence: ProviderAttemptEvidence) async throws
}

enum ProviderAttemptStoreError: Error {
    case invalidEvidence
    case persistenceFailed
}

actor FileProviderAttemptStore: ProviderAttemptRecording {
    private let fileURL: URL
    private let encoder: JSONEncoder

    init(directoryURL: URL) throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        fileURL = directoryURL.appendingPathComponent("provider-attempts.jsonl")
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    func record(_ evidence: ProviderAttemptEvidence) async throws {
        guard evidence.providerID.utf8.count <= 32,
              evidence.modelSHA256.count == 64,
              evidence.responseByteCount.map({ $0 >= 0 && $0 <= ProviderLimits.maximumOutputBytes }) ?? true,
              evidence.responseSHA256.map({ $0.count == 64 }) ?? true else {
            throw ProviderAttemptStoreError.invalidEvidence
        }

        do {
            var line = try encoder.encode(evidence)
            line.append(0x0A)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
                    throw ProviderAttemptStoreError.persistenceFailed
                }
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.synchronize()
        } catch let error as ProviderAttemptStoreError {
            throw error
        } catch {
            throw ProviderAttemptStoreError.persistenceFailed
        }
    }
}
