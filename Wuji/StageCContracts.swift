import Foundation

struct StageCLimits: Equatable, Sendable {
    let maximumProviderTurns: Int
    let maximumReadExecutions: Int
    let maximumReadCallsPerBatch: Int
    let maximumEditProposals: Int
    let maximumMutations: Int
    let maximumGoalBytes: Int
    let maximumPathBytes: Int
    let maximumEditableFileBytes: Int
    let maximumDiffBytes: Int
    let maximumProposalRecordBytes: Int
    let maximumApprovalSeconds: TimeInterval
    let maximumExecutorStreamBytes: Int
    let maximumDurableEvidenceBytes: Int
    let maximumDiagnosticBytes: Int
    let maximumWorkspaceEntries: Int
    let maximumWorkspaceBytes: UInt64

    // Injectable Stage C implementation defaults for the current 8 GB target.
    static let production = StageCLimits(
        maximumProviderTurns: 12,
        maximumReadExecutions: 24,
        maximumReadCallsPerBatch: 8,
        maximumEditProposals: 4,
        maximumMutations: 1,
        maximumGoalBytes: 4 * 1_024,
        maximumPathBytes: 1_024,
        maximumEditableFileBytes: 1 * 1_024 * 1_024,
        maximumDiffBytes: 16 * 1_024,
        maximumProposalRecordBytes: 128 * 1_024,
        maximumApprovalSeconds: 300,
        maximumExecutorStreamBytes: 32 * 1_024,
        maximumDurableEvidenceBytes: 2 * 1_024 * 1_024,
        maximumDiagnosticBytes: 64 * 1_024,
        maximumWorkspaceEntries: 50_000,
        maximumWorkspaceBytes: 2 * 1_024 * 1_024 * 1_024
    )

    init(
        maximumProviderTurns: Int,
        maximumReadExecutions: Int,
        maximumReadCallsPerBatch: Int,
        maximumEditProposals: Int,
        maximumMutations: Int,
        maximumGoalBytes: Int,
        maximumPathBytes: Int,
        maximumEditableFileBytes: Int,
        maximumDiffBytes: Int,
        maximumProposalRecordBytes: Int,
        maximumApprovalSeconds: TimeInterval,
        maximumExecutorStreamBytes: Int,
        maximumDurableEvidenceBytes: Int,
        maximumDiagnosticBytes: Int,
        maximumWorkspaceEntries: Int,
        maximumWorkspaceBytes: UInt64
    ) {
        let positive = [
            maximumProviderTurns, maximumReadExecutions, maximumReadCallsPerBatch,
            maximumEditProposals, maximumMutations, maximumGoalBytes, maximumPathBytes,
            maximumEditableFileBytes, maximumDiffBytes, maximumProposalRecordBytes,
            maximumExecutorStreamBytes, maximumDurableEvidenceBytes, maximumDiagnosticBytes,
            maximumWorkspaceEntries
        ]
        precondition(positive.allSatisfy { $0 > 0 })
        precondition(maximumApprovalSeconds > 0)
        precondition(maximumWorkspaceBytes > 0)
        precondition(maximumReadCallsPerBatch <= maximumReadExecutions)
        precondition(maximumGoalBytes <= ProviderLimits.maximumTurnMessageBytes)
        precondition(maximumPathBytes <= 1_024)
        precondition(maximumExecutorStreamBytes <= 32 * 1_024)
        precondition(maximumDiffBytes * 6 + 32 * 1_024 <= maximumProposalRecordBytes)
        self.maximumProviderTurns = maximumProviderTurns
        self.maximumReadExecutions = maximumReadExecutions
        self.maximumReadCallsPerBatch = maximumReadCallsPerBatch
        self.maximumEditProposals = maximumEditProposals
        self.maximumMutations = maximumMutations
        self.maximumGoalBytes = maximumGoalBytes
        self.maximumPathBytes = maximumPathBytes
        self.maximumEditableFileBytes = maximumEditableFileBytes
        self.maximumDiffBytes = maximumDiffBytes
        self.maximumProposalRecordBytes = maximumProposalRecordBytes
        self.maximumApprovalSeconds = maximumApprovalSeconds
        self.maximumExecutorStreamBytes = maximumExecutorStreamBytes
        self.maximumDurableEvidenceBytes = maximumDurableEvidenceBytes
        self.maximumDiagnosticBytes = maximumDiagnosticBytes
        self.maximumWorkspaceEntries = maximumWorkspaceEntries
        self.maximumWorkspaceBytes = maximumWorkspaceBytes
    }
}

enum StageCError: String, Error, Codable, Equatable, Sendable {
    case invalidBinding = "invalid_binding"
    case invalidArguments = "invalid_arguments"
    case unknownTool = "unknown_tool"
    case mixedBatch = "mixed_batch"
    case editBatchCount = "edit_batch_count"
    case toolCallID = "tool_call_id"
    case pathRejected = "path_rejected"
    case protectedPath = "protected_path"
    case workspaceEscape = "workspace_escape"
    case symlinkRejected = "symlink_rejected"
    case unsupportedFile = "unsupported_file"
    case fileLimit = "file_limit"
    case workspaceLimit = "workspace_limit"
    case beforeMismatch = "before_mismatch"
    case ambiguousReplacement = "ambiguous_replacement"
    case overwriteRejected = "overwrite_rejected"
    case diffLimit = "diff_limit"
    case contextLimit = "context_limit"
    case proposalLimit = "proposal_limit"
    case approvalRequired = "approval_required"
    case approvalRejected = "approval_rejected"
    case approvalExpired = "approval_expired"
    case approvalCancelled = "approval_cancelled"
    case approvalTampered = "approval_tampered"
    case approvalReplayed = "approval_replayed"
    case writerBusy = "writer_busy"
    case evidenceFailure = "evidence_failure"
    case executorFailure = "executor_failure"
    case verificationFailed = "verification_failed"
    case reconciliationRequired = "reconciliation_required"
    case completionRejected = "completion_rejected"
}

enum StageCTaskPhase: String, Codable, Equatable, Sendable {
    case ready
    case running
    case pendingApproval = "pending_approval"
    case approved
    case mutating
    case verifying
    case completed
    case failed
    case reconciliationRequired = "reconciliation_required"
}

enum StageCToolName: String, Codable, CaseIterable, Sendable {
    case list
    case search
    case read
    case edit
}

struct StageCEditProposal: Codable, Equatable, Sendable {
    let taskID: UUID
    let toolCallID: String
    let relativePath: String
    let expectedOld: String
    let replacement: String
    let beforeSHA256: String
    let afterSHA256: String
    let beforeTreeSHA256: String
    let expectedAfterTreeSHA256: String
    let diff: String
    let diffSHA256: String
    let createdAt: Date
    let proposalSHA256: String

    static func bindingMaterial(
        taskID: UUID,
        toolCallID: String,
        relativePath: String,
        expectedOld: String,
        replacement: String,
        beforeSHA256: String,
        afterSHA256: String,
        beforeTreeSHA256: String,
        expectedAfterTreeSHA256: String,
        diffSHA256: String,
        createdAt: Date
    ) -> String {
        [
            taskID.uuidString.lowercased(), toolCallID, relativePath,
            ProviderDigest.sha256Hex(expectedOld), ProviderDigest.sha256Hex(replacement),
            beforeSHA256, afterSHA256, beforeTreeSHA256, expectedAfterTreeSHA256,
            diffSHA256,
            String(Int64((createdAt.timeIntervalSince1970 * 1_000).rounded()))
        ].joined(separator: "\u{0}")
    }
}

enum StageCApprovalState: String, Codable, Equatable, Sendable {
    case idle
    case pending
    case approved
    case rejected
    case cancelled
    case expired
    case consumed
}

struct StageCApprovalRequest: Codable, Equatable, Sendable {
    let requestID: UUID
    let taskID: UUID
    let sessionID: UUID
    let importID: UUID
    let workspaceID: UUID
    let workspaceIdentitySHA256: String
    let workspaceRootSHA256: String
    let markerSHA256: String
    let goalBindingSHA256: String
    let ruleSetBindingSHA256: String
    let proposalSHA256: String
    let toolCallID: String
    let relativePath: String
    let beforeSHA256: String
    let afterSHA256: String
    let diffSHA256: String
    let nonce: UUID
    let createdAt: Date
    let expiresAt: Date

    var bindingSHA256: String {
        ProviderDigest.sha256Hex([
            requestID.uuidString.lowercased(), taskID.uuidString.lowercased(),
            sessionID.uuidString.lowercased(), importID.uuidString.lowercased(),
            workspaceID.uuidString.lowercased(), workspaceIdentitySHA256,
            workspaceRootSHA256, markerSHA256, goalBindingSHA256,
            ruleSetBindingSHA256, proposalSHA256, toolCallID, relativePath,
            beforeSHA256, afterSHA256, diffSHA256, nonce.uuidString.lowercased(),
            String(Int64((createdAt.timeIntervalSince1970 * 1_000).rounded())),
            String(Int64((expiresAt.timeIntervalSince1970 * 1_000).rounded()))
        ].joined(separator: "\u{0}"))
    }
}

struct StageCApprovalGrant: Codable, Equatable, Sendable {
    let requestID: UUID
    let requestBindingSHA256: String
    let nonce: UUID
    let approvedAt: Date
}

struct StageCApprovalEvidence: Codable, Equatable, Sendable {
    let request: StageCApprovalRequest
    let state: StageCApprovalState
    let recordedAt: Date
    let grant: StageCApprovalGrant?
}

enum StageCApprovalDecision: Equatable, Sendable {
    case approved(StageCApprovalGrant)
    case rejected
    case cancelled
    case expired
}

protocol StageCApprovalAuthorizing: Sendable {
    func requestApproval(_ request: StageCApprovalRequest) async -> StageCApprovalDecision
}

struct StageCApprovalProjection: Equatable, Sendable {
    let state: StageCApprovalState
    let request: StageCApprovalRequest?
}

actor StageCApprovalBroker: StageCApprovalAuthorizing {
    static let shared = StageCApprovalBroker()
    private var pending: StageCApprovalRequest?
    private var continuation: CheckedContinuation<StageCApprovalDecision, Never>?
    private var listeners: [UUID: AsyncStream<StageCApprovalProjection>.Continuation] = [:]

    func requestApproval(_ request: StageCApprovalRequest) async -> StageCApprovalDecision {
        guard pending == nil, continuation == nil else { return .rejected }
        pending = request
        emit(.init(state: .pending, request: request))
        return await withCheckedContinuation { continuation = $0 }
    }

    func approve(requestID: UUID, nonce: UUID, at date: Date = Date()) {
        guard let request = pending,
              request.requestID == requestID,
              request.nonce == nonce else { return resolve(.rejected, state: .rejected) }
        guard date <= request.expiresAt else { return resolve(.expired, state: .expired) }
        resolve(.approved(.init(
            requestID: request.requestID,
            requestBindingSHA256: request.bindingSHA256,
            nonce: request.nonce,
            approvedAt: date
        )), state: .approved)
    }

    func reject(requestID: UUID, nonce: UUID) {
        guard pending?.requestID == requestID, pending?.nonce == nonce else { return }
        resolve(.rejected, state: .rejected)
    }

    func cancel(requestID: UUID, nonce: UUID) {
        guard pending?.requestID == requestID, pending?.nonce == nonce else { return }
        resolve(.cancelled, state: .cancelled)
    }

    func snapshot() -> StageCApprovalProjection {
        .init(state: pending == nil ? .idle : .pending, request: pending)
    }

    func projections() -> AsyncStream<StageCApprovalProjection> {
        let id = UUID()
        return AsyncStream { continuation in
            listeners[id] = continuation
            continuation.yield(.init(state: pending == nil ? .idle : .pending, request: pending))
            continuation.onTermination = { [weak self] _ in
                Task { await self?.remove(id) }
            }
        }
    }

    private func resolve(_ decision: StageCApprovalDecision, state: StageCApprovalState) {
        let request = pending
        pending = nil
        let saved = continuation
        continuation = nil
        emit(.init(state: state, request: request))
        saved?.resume(returning: decision)
    }

    private func emit(_ projection: StageCApprovalProjection) {
        listeners.values.forEach { $0.yield(projection) }
    }

    private func remove(_ id: UUID) { listeners.removeValue(forKey: id) }
}

struct StageCExecutorFacts: Codable, Equatable, Sendable {
    let rootExitObserved: Bool
    let stdoutEOFObserved: Bool
    let stderrEOFObserved: Bool
    let finalStateKind: String
    let finalStateValue: Int32
    let truncated: Bool

    var terminalBarrierSatisfied: Bool {
        rootExitObserved && stdoutEOFObserved && stderrEOFObserved
    }
}

enum StageCExecutorOutcome: Equatable, Sendable {
    case applied(StageCExecutorFacts)
    case failure(StageCExecutorFacts?)
    case unknown(StageCExecutorFacts?)
}

protocol StageCEditExecuting: Sendable {
    func execute(_ proposal: StageCEditProposal) async -> StageCExecutorOutcome
}

enum StageCExternalIOKind: String, Codable, Equatable, Sendable {
    case provider
    case readExecutor = "read_executor"
    case mutationExecutor = "mutation_executor"
    case verificationRead = "verification_read"
    case completionCheck = "completion_check"
}

enum StageCAttemptPhase: String, Codable, Equatable, Sendable {
    case intentRecorded = "intent_recorded"
    case succeeded
    case failed
    case reconciliationRequired = "reconciliation_required"
}

struct StageCAttemptEvidence: Codable, Equatable, Sendable {
    let taskID: UUID
    let operationID: UUID
    let attemptID: UUID
    let ioKind: StageCExternalIOKind
    let inputSHA256: String
    let toolCallID: String?
    let recordedAt: Date
    let phase: StageCAttemptPhase
    let resultSHA256: String?
    let facts: StageCExecutorFacts?
}

struct StageCCompletion: Codable, Equatable, Sendable {
    let taskID: UUID
    let sessionID: UUID
    let workspaceIdentitySHA256: String
    let goalBindingSHA256: String
    let ruleSetBindingSHA256: String
    let proposalSHA256: String
    let finalTreeSHA256: String
    let completedAt: Date
}

enum StageCLoopOutcome: Equatable, Sendable {
    case completed(StageCCompletion)
    case pendingApproval
    case rejected
    case failed(StageCError)
    case reconciliationRequired
}

actor StageCWorkspaceWriterGate {
    static let shared = StageCWorkspaceWriterGate()
    private var holders: [String: UUID] = [:]

    func acquire(workspaceIdentitySHA256: String) -> UUID? {
        guard holders[workspaceIdentitySHA256] == nil else { return nil }
        let token = UUID()
        holders[workspaceIdentitySHA256] = token
        return token
    }

    func release(workspaceIdentitySHA256: String, token: UUID) {
        guard holders[workspaceIdentitySHA256] == token else { return }
        holders.removeValue(forKey: workspaceIdentitySHA256)
    }
}
