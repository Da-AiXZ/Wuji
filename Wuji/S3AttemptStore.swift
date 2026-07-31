import Foundation

enum S3ExternalIOKind: String, Codable, Sendable {
    case provider
    case executor
}

enum S3AttemptPhase: String, Codable, Sendable {
    case intentRecorded = "intent_recorded"
    case succeeded
    case failed
    case reconciliationRequired = "reconciliation_required"
}

enum S3AttemptResultCategory: String, Codable, Sendable {
    case none
    case providerDecision = "provider_decision"
    case providerFailure = "provider_failure"
    case providerUnknown = "provider_unknown"
    case observation
    case executorFailure = "executor_failure"
    case executorUnknown = "executor_unknown"
}

struct S3AttemptEvidence: Codable, Equatable, Sendable {
    let taskID: UUID
    let operationID: UUID
    let attemptID: UUID
    let ioKind: S3ExternalIOKind
    let providerID: String?
    let toolName: String?
    let inputSHA256: String
    let recordedAt: Date
    let phase: S3AttemptPhase
    let resultCategory: S3AttemptResultCategory
    let resultByteCount: Int?
    let resultSHA256: String?
}

protocol S3AttemptRecording: Sendable {
    func record(_ evidence: S3AttemptEvidence) async throws
    func records(taskID: UUID) async throws -> [S3AttemptEvidence]
}

enum S3AttemptStoreError: Error, Equatable {
    case invalidEvidence
    case persistenceFailed
}

actor FileS3AttemptStore: S3AttemptRecording {
    private static let maximumFileBytes = 256 * 1_024
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(directoryURL: URL) throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        fileURL = directoryURL.appendingPathComponent("s3-attempts.jsonl")
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func record(_ evidence: S3AttemptEvidence) async throws {
        guard Self.valid(evidence) else {
            throw S3AttemptStoreError.invalidEvidence
        }
        do {
            var line = try encoder.encode(evidence)
            line.append(0x0A)
            let existingBytes = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard existingBytes <= Self.maximumFileBytes - line.count else {
                throw S3AttemptStoreError.persistenceFailed
            }
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
                    throw S3AttemptStoreError.persistenceFailed
                }
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.synchronize()
        } catch let error as S3AttemptStoreError {
            throw error
        } catch {
            throw S3AttemptStoreError.persistenceFailed
        }
    }

    func records(taskID: UUID) async throws -> [S3AttemptEvidence] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            guard data.count <= Self.maximumFileBytes else {
                throw S3AttemptStoreError.persistenceFailed
            }
            var records: [S3AttemptEvidence] = []
            for line in data.split(separator: 0x0A) where !line.isEmpty {
                let record = try decoder.decode(S3AttemptEvidence.self, from: Data(line))
                guard Self.valid(record) else {
                    throw S3AttemptStoreError.invalidEvidence
                }
                if record.taskID == taskID {
                    records.append(record)
                }
            }
            return records
        } catch let error as S3AttemptStoreError {
            throw error
        } catch {
            throw S3AttemptStoreError.persistenceFailed
        }
    }

    private static func valid(_ evidence: S3AttemptEvidence) -> Bool {
        let validHash = { (value: String) in
            value.count == 64 && value.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "0123456789abcdef").contains($0)
            }
        }
        return validHash(evidence.inputSHA256)
            && (evidence.providerID.map { !$0.isEmpty && $0.utf8.count <= 32 } ?? true)
            && (evidence.toolName.map { !$0.isEmpty && $0.utf8.count <= 64 } ?? true)
            && (evidence.resultByteCount.map {
                $0 >= 0 && $0 <= ProviderLimits.maximumResponseBodyBytes
            } ?? true)
            && (evidence.resultSHA256.map(validHash) ?? true)
    }
}
