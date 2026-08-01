import Foundation

enum S4ExternalIOKind: String, Codable, Hashable, Sendable {
    case workspacePrepare = "workspace_prepare"
    case provider
    case readExecutor = "read_executor"
    case writeExecutor = "write_executor"
    case verifyExecutor = "verify_executor"
    case reconciliation
    case completionCheck = "completion_check"
}

enum S4AttemptPhase: String, Codable, Sendable {
    case intentRecorded = "intent_recorded"
    case succeeded
    case failed
    case reconciliationRequired = "reconciliation_required"
    case reconciledNotApplied = "reconciled_not_applied"
    case reconciledApplied = "reconciled_applied"
    case manualReconciliation = "manual_reconciliation"
}

enum S4AttemptResultCategory: String, Codable, Sendable {
    case none
    case providerDecision = "provider_decision"
    case providerFailure = "provider_failure"
    case providerUnknown = "provider_unknown"
    case observation
    case writeApplied = "write_applied"
    case verifyPassed = "verify_passed"
    case executorFailure = "executor_failure"
    case executorUnknown = "executor_unknown"
    case workspaceBefore = "workspace_before"
    case workspaceAfter = "workspace_after"
    case workspaceOther = "workspace_other"
    case completionEstablished = "completion_established"
}

struct S4AttemptEvidence: Codable, Equatable, Sendable {
    let taskID: UUID
    let operationID: UUID
    let attemptID: UUID
    let ioKind: S4ExternalIOKind
    let providerID: String?
    let toolName: String?
    let toolCallIDHash: String?
    let approvalNonceHash: String?
    let inputSHA256: String
    let recordedAt: Date
    let phase: S4AttemptPhase
    let resultCategory: S4AttemptResultCategory
    let resultByteCount: Int?
    let resultSHA256: String?
    let rootExitObserved: Bool?
    let stdoutEOFObserved: Bool?
    let stderrEOFObserved: Bool?
    let finalStateKind: String?
    let finalStateValue: Int32?
    let truncated: Bool?
}

enum S4ApprovalEvidencePhase: String, Codable, Sendable {
    case pending
    case granted
    case rejected
    case expired
}

struct S4ApprovalEvidence: Codable, Equatable, Sendable {
    let request: S4ApprovalRequest
    let phase: S4ApprovalEvidencePhase
    let recordedAt: Date
    let grant: S4ApprovalGrant?
    let rejection: S4ApprovalRejection?
}

struct S4DurableSnapshot: Equatable, Sendable {
    let attempts: [S4AttemptEvidence]
    let approvals: [S4ApprovalEvidence]
}

protocol S4DurableRecording: Sendable {
    func recordAttempt(_ evidence: S4AttemptEvidence) async throws
    func recordApproval(_ evidence: S4ApprovalEvidence) async throws
    func snapshot(taskID: UUID) async throws -> S4DurableSnapshot
}

enum S4DurableStoreError: Error, Equatable {
    case invalidEvidence
    case persistenceFailed
}

actor FileS4DurableStore: S4DurableRecording {
    private let attemptsURL: URL
    private let approvalsURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(directoryURL: URL) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        attemptsURL = directoryURL.appendingPathComponent("s4-attempts.jsonl")
        approvalsURL = directoryURL.appendingPathComponent("s4-approvals.jsonl")
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func recordAttempt(_ evidence: S4AttemptEvidence) async throws {
        guard Self.valid(evidence) else { throw S4DurableStoreError.invalidEvidence }
        try append(evidence, to: attemptsURL)
    }

    func recordApproval(_ evidence: S4ApprovalEvidence) async throws {
        guard Self.valid(evidence) else { throw S4DurableStoreError.invalidEvidence }
        try append(evidence, to: approvalsURL)
    }

    func snapshot(taskID: UUID) async throws -> S4DurableSnapshot {
        S4DurableSnapshot(
            attempts: try read(S4AttemptEvidence.self, from: attemptsURL).filter { $0.taskID == taskID },
            approvals: try read(S4ApprovalEvidence.self, from: approvalsURL).filter { $0.request.taskID == taskID }
        )
    }

    private func append<T: Encodable>(_ value: T, to url: URL) throws {
        do {
            var line = try encoder.encode(value)
            line.append(0x0A)
            let existing = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard existing <= S4Limits.maximumDurableFileBytes - line.count else {
                throw S4DurableStoreError.persistenceFailed
            }
            if !FileManager.default.fileExists(atPath: url.path) {
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                    throw S4DurableStoreError.persistenceFailed
                }
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.synchronize()
        } catch let error as S4DurableStoreError {
            throw error
        } catch {
            throw S4DurableStoreError.persistenceFailed
        }
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> [T] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= S4Limits.maximumDurableFileBytes else {
                throw S4DurableStoreError.persistenceFailed
            }
            return try data.split(separator: 0x0A).filter { !$0.isEmpty }.map {
                try decoder.decode(type, from: Data($0))
            }
        } catch let error as S4DurableStoreError {
            throw error
        } catch {
            throw S4DurableStoreError.persistenceFailed
        }
    }

    private static func valid(_ evidence: S4AttemptEvidence) -> Bool {
        validHash(evidence.inputSHA256)
            && (evidence.providerID.map { !$0.isEmpty && $0.utf8.count <= 32 } ?? true)
            && (evidence.toolName.map { !$0.isEmpty && $0.utf8.count <= 64 } ?? true)
            && (evidence.toolCallIDHash.map(validHash) ?? true)
            && (evidence.approvalNonceHash.map(validHash) ?? true)
            && (evidence.resultByteCount.map { $0 >= 0 && $0 <= ProviderLimits.maximumResponseBodyBytes } ?? true)
            && (evidence.resultSHA256.map(validHash) ?? true)
            && (evidence.finalStateKind.map { $0 == "exited" || $0 == "signaled" } ?? true)
            && ((evidence.finalStateKind == nil) == (evidence.finalStateValue == nil))
    }

    private static func valid(_ evidence: S4ApprovalEvidence) -> Bool {
        let request = evidence.request
        return validHash(request.workspaceID)
            && validHash(request.workspaceSnapshotSHA256)
            && validHash(request.beforeSHA256)
            && validHash(request.afterSHA256)
            && validHash(request.changeSummarySHA256)
            && validHash(request.bindingSHA256)
            && request.relativePath == S4TaskContract.authorizedPath
            && request.verificationProfile == S4TaskContract.verificationProfile
            && ((evidence.phase == .granted) == (evidence.grant != nil))
            && ((evidence.phase == .rejected || evidence.phase == .expired) == (evidence.rejection != nil))
    }

    private static func validHash(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdef").contains($0)
        }
    }
}
