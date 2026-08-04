import Foundation

struct StageDLimits: Equatable, Sendable {
    let maximumCommandBytes: Int
    let maximumArgumentCount: Int
    let maximumArgumentBytes: Int
    let maximumCWDBytes: Int
    let maximumStdoutBytes: Int
    let maximumStderrBytes: Int
    let maximumDurableEvidenceBytes: Int
    let maximumApprovalSeconds: TimeInterval
    let commandTimeoutSeconds: TimeInterval
    let maximumCloneSeconds: TimeInterval
    let maximumCloneEntries: Int
    let maximumCloneBytes: UInt64
    let maximumWorkspaceBytes: UInt64

    // Injectable Stage D defaults for the current implementation, not permanent product limits.
    static let production = StageDLimits(
        maximumCommandBytes: 2 * 1_024,
        maximumArgumentCount: 16,
        maximumArgumentBytes: 1_024,
        maximumCWDBytes: 1_024,
        maximumStdoutBytes: 64 * 1_024,
        maximumStderrBytes: 64 * 1_024,
        maximumDurableEvidenceBytes: 2 * 1_024 * 1_024,
        maximumApprovalSeconds: 300,
        commandTimeoutSeconds: 120,
        maximumCloneSeconds: 300,
        maximumCloneEntries: 20_000,
        maximumCloneBytes: 512 * 1_024 * 1_024,
        maximumWorkspaceBytes: 2 * 1_024 * 1_024 * 1_024
    )

    init(
        maximumCommandBytes: Int,
        maximumArgumentCount: Int,
        maximumArgumentBytes: Int,
        maximumCWDBytes: Int,
        maximumStdoutBytes: Int,
        maximumStderrBytes: Int,
        maximumDurableEvidenceBytes: Int,
        maximumApprovalSeconds: TimeInterval,
        commandTimeoutSeconds: TimeInterval,
        maximumCloneSeconds: TimeInterval,
        maximumCloneEntries: Int,
        maximumCloneBytes: UInt64,
        maximumWorkspaceBytes: UInt64
    ) {
        precondition([
            maximumCommandBytes, maximumArgumentCount, maximumArgumentBytes,
            maximumCWDBytes, maximumStdoutBytes, maximumStderrBytes,
            maximumDurableEvidenceBytes, maximumCloneEntries
        ].allSatisfy { $0 > 0 })
        precondition(maximumApprovalSeconds > 0 && commandTimeoutSeconds > 0)
        precondition(maximumCloneSeconds > 0 && maximumCloneBytes > 0 && maximumWorkspaceBytes > 0)
        precondition(maximumArgumentCount <= 16)
        precondition(maximumArgumentBytes <= 1_024)
        precondition(maximumCWDBytes <= 1_024)
        precondition(maximumStdoutBytes <= 64 * 1_024 && maximumStderrBytes <= 64 * 1_024)
        self.maximumCommandBytes = maximumCommandBytes
        self.maximumArgumentCount = maximumArgumentCount
        self.maximumArgumentBytes = maximumArgumentBytes
        self.maximumCWDBytes = maximumCWDBytes
        self.maximumStdoutBytes = maximumStdoutBytes
        self.maximumStderrBytes = maximumStderrBytes
        self.maximumDurableEvidenceBytes = maximumDurableEvidenceBytes
        self.maximumApprovalSeconds = maximumApprovalSeconds
        self.commandTimeoutSeconds = commandTimeoutSeconds
        self.maximumCloneSeconds = maximumCloneSeconds
        self.maximumCloneEntries = maximumCloneEntries
        self.maximumCloneBytes = maximumCloneBytes
        self.maximumWorkspaceBytes = maximumWorkspaceBytes
    }
}

enum StageDCommandRisk: String, Codable, Equatable, Hashable, Sendable {
    case safeReadOnly = "safe_read_only"
    case workspaceWrite = "workspace_write"
    case network
    case installation
    case delete
    case overwrite
    case boundaryCrossing = "boundary_crossing"
    case unavailable
    case unsupported

    var requiresApproval: Bool {
        switch self {
        case .workspaceWrite, .network, .installation, .delete, .overwrite, .boundaryCrossing:
            return true
        case .safeReadOnly, .unavailable, .unsupported:
            return false
        }
    }
}

enum StageDExecutionRoot: String, Codable, Equatable, Sendable {
    case workspace
    case cloneRoot = "clone_root"
    case rootfs
}

enum StageDCommandError: String, Error, Codable, Equatable, Sendable {
    case emptyCommand = "empty_command"
    case commandLimit = "command_limit"
    case controlCharacter = "control_character"
    case shellMetacharacter = "shell_metacharacter"
    case ambiguousWhitespace = "ambiguous_whitespace"
    case ambiguousQuoting = "ambiguous_quoting"
    case argumentLimit = "argument_limit"
    case unsupportedExecutable = "unsupported_executable"
    case unsupportedArguments = "unsupported_arguments"
    case unavailableTool = "unavailable_tool"
    case invalidCWD = "invalid_cwd"
    case boundaryCrossing = "boundary_crossing"
    case invalidClone = "invalid_clone"
    case invalidInstall = "invalid_install"
    case writeNotBound = "write_not_bound"
    case destructiveRejected = "destructive_rejected"
    case approvalRequired = "approval_required"
    case approvalRejected = "approval_rejected"
    case approvalExpired = "approval_expired"
    case approvalCancelled = "approval_cancelled"
    case approvalTampered = "approval_tampered"
    case approvalReplayed = "approval_replayed"
    case workspaceBusy = "workspace_busy"
    case evidenceFailure = "evidence_failure"
    case executorFailure = "executor_failure"
    case verificationFailure = "verification_failure"
    case reconciliationRequired = "reconciliation_required"
    case providerFailure = "provider_failure"
    case providerPolicy = "provider_policy"
    case completionRejected = "completion_rejected"
}

struct StageDParsedCommand: Codable, Equatable, Sendable {
    let original: String
    let executable: String
    let arguments: [String]
    let cwd: String

    var bindingSHA256: String {
        ProviderDigest.sha256Hex(
            ([original, executable, cwd] + arguments).joined(separator: "\u{0}")
        )
    }
}

struct StageDBoundedWrite: Codable, Equatable, Sendable {
    let relativePath: String
    let expectedBeforeLine: String
    let replacementLine: String
    let expectedBeforeSHA256: String
    let expectedAfterSHA256: String

    var sedExpression: String {
        "s/\(expectedBeforeLine)/\(replacementLine)/"
    }
}

struct StageDAuthorizedCommand: Codable, Equatable, Sendable {
    let parsed: StageDParsedCommand
    let risk: StageDCommandRisk
    let executionRoot: StageDExecutionRoot
    let workspaceIdentitySHA256: String
    let write: StageDBoundedWrite?
    let cloneTarget: String?

    var bindingSHA256: String {
        ProviderDigest.sha256Hex([
            parsed.bindingSHA256, risk.rawValue, executionRoot.rawValue,
            workspaceIdentitySHA256, write.map { ProviderDigest.sha256Hex(
                [$0.relativePath, $0.expectedBeforeLine, $0.replacementLine,
                 $0.expectedBeforeSHA256, $0.expectedAfterSHA256].joined(separator: "\u{0}"))
            } ?? "", cloneTarget ?? ""
        ].joined(separator: "\u{0}"))
    }
}

enum StageDProcessTreeState: String, Codable, Equatable, Sendable {
    case notObserved = "not_observed"
    case quiescent
    case descendantsRemain = "descendants_remain"
}

struct StageDProcessFacts: Codable, Equatable, Sendable {
    let rootExitObserved: Bool
    let finalStateKind: String
    let finalStateValue: Int32
    let stdoutEOFObserved: Bool
    let stderrEOFObserved: Bool
    let stdoutByteCount: Int
    let stderrByteCount: Int
    let stdoutSHA256: String
    let stderrSHA256: String
    let truncated: Bool
    let cancellationRequested: Bool
    let processTreeState: StageDProcessTreeState
    let activeDescendantCount: Int

    var terminalBarrierSatisfied: Bool {
        rootExitObserved && stdoutEOFObserved && stderrEOFObserved
    }

    var verifiedSuccessBarrier: Bool {
        terminalBarrierSatisfied
            && finalStateKind == "exited"
            && finalStateValue == 0
            && !truncated
            && !cancellationRequested
            && processTreeState == .quiescent
            && activeDescendantCount == 0
    }
}

struct StageDCommandResult: Codable, Equatable, Sendable {
    let commandBindingSHA256: String
    let facts: [StageDProcessFacts]
    let stdout: String
    let stderr: String
    let outputProjectionTruncated: Bool
    let verification: String
    let verificationSHA256: String
    let cloneRemote: String?
    let cloneHEAD: String?
    let cloneEntryCount: Int?
    let cloneByteCount: UInt64?
    let toolVersions: [String: String]

    var verified: Bool {
        !facts.isEmpty
            && facts.allSatisfy(\.verifiedSuccessBarrier)
            && !outputProjectionTruncated
            && ProviderDigest.sha256Hex(verification) == verificationSHA256
    }
}

enum StageDExecutorOutcome: Equatable, Sendable {
    case succeeded(StageDCommandResult)
    case failed(StageDCommandResult?)
    case unknown(StageDCommandResult?)
}

protocol StageDCommandExecuting: Sendable {
    func execute(_ command: StageDAuthorizedCommand) async -> StageDExecutorOutcome
}

struct StageDApprovalRequest: Codable, Equatable, Sendable {
    let requestID: UUID
    let taskID: UUID
    let operationID: UUID
    let attemptID: UUID
    let workspaceIdentitySHA256: String
    let commandBindingSHA256: String
    let command: String
    let argumentsSHA256: String
    let cwd: String
    let risk: StageDCommandRisk
    let executionRoot: StageDExecutionRoot
    let nonce: UUID
    let createdAt: Date
    let expiresAt: Date

    var bindingSHA256: String {
        ProviderDigest.sha256Hex([
            requestID.uuidString.lowercased(), taskID.uuidString.lowercased(),
            operationID.uuidString.lowercased(), attemptID.uuidString.lowercased(),
            workspaceIdentitySHA256, commandBindingSHA256, ProviderDigest.sha256Hex(command),
            argumentsSHA256, cwd, risk.rawValue, executionRoot.rawValue,
            nonce.uuidString.lowercased(),
            String(Int64((createdAt.timeIntervalSince1970 * 1_000).rounded())),
            String(Int64((expiresAt.timeIntervalSince1970 * 1_000).rounded()))
        ].joined(separator: "\u{0}"))
    }
}

struct StageDApprovalGrant: Codable, Equatable, Sendable {
    let requestID: UUID
    let requestBindingSHA256: String
    let nonce: UUID
    let approvedAt: Date
}

enum StageDApprovalState: String, Codable, Equatable, Sendable {
    case pending
    case approved
    case rejected
    case cancelled
    case expired
    case consumed
}

struct StageDApprovalEvidence: Codable, Equatable, Sendable {
    let request: StageDApprovalRequest
    let state: StageDApprovalState
    let recordedAt: Date
    let grant: StageDApprovalGrant?
}

enum StageDApprovalDecision: Equatable, Sendable {
    case approved(StageDApprovalGrant)
    case rejected
    case cancelled
    case expired
}

protocol StageDApprovalAuthorizing: Sendable {
    func requestApproval(_ request: StageDApprovalRequest) async -> StageDApprovalDecision
}

struct StageDApprovalProjection: Equatable, Sendable {
    let state: StageDApprovalState?
    let request: StageDApprovalRequest?
}

actor StageDApprovalBroker: StageDApprovalAuthorizing {
    static let shared = StageDApprovalBroker()
    private var pending: StageDApprovalRequest?
    private var continuation: CheckedContinuation<StageDApprovalDecision, Never>?
    private var listeners: [UUID: AsyncStream<StageDApprovalProjection>.Continuation] = [:]

    func requestApproval(_ request: StageDApprovalRequest) async -> StageDApprovalDecision {
        guard pending == nil && continuation == nil else { return .rejected }
        pending = request
        emit(.init(state: .pending, request: request))
        return await withCheckedContinuation { continuation = $0 }
    }

    func approve(requestID: UUID, nonce: UUID, at: Date = Date()) {
        guard let request = pending,
              request.requestID == requestID,
              request.nonce == nonce else {
            return resolve(.rejected, state: .rejected)
        }
        guard at <= request.expiresAt else { return resolve(.expired, state: .expired) }
        resolve(.approved(.init(
            requestID: requestID,
            requestBindingSHA256: request.bindingSHA256,
            nonce: nonce,
            approvedAt: at
        )), state: .approved)
    }

    func reject(requestID: UUID, nonce: UUID) {
        guard pending?.requestID == requestID && pending?.nonce == nonce else { return }
        resolve(.rejected, state: .rejected)
    }

    func cancel(requestID: UUID, nonce: UUID) {
        guard pending?.requestID == requestID && pending?.nonce == nonce else { return }
        resolve(.cancelled, state: .cancelled)
    }

    func snapshot() -> StageDApprovalProjection {
        .init(state: pending == nil ? nil : .pending, request: pending)
    }

    func projections() -> AsyncStream<StageDApprovalProjection> {
        let id = UUID()
        return AsyncStream { continuation in
            listeners[id] = continuation
            continuation.yield(.init(state: pending == nil ? nil : .pending, request: pending))
            continuation.onTermination = { [weak self] _ in Task { await self?.remove(id) } }
        }
    }

    private func resolve(_ decision: StageDApprovalDecision, state: StageDApprovalState) {
        let request = pending
        pending = nil
        let saved = continuation
        continuation = nil
        emit(.init(state: state, request: request))
        saved?.resume(returning: decision)
    }

    private func emit(_ projection: StageDApprovalProjection) {
        listeners.values.forEach { $0.yield(projection) }
    }

    private func remove(_ id: UUID) { listeners.removeValue(forKey: id) }
}

enum StageDExternalIOKind: String, Codable, Equatable, Sendable {
    case provider
    case command
}

enum StageDAttemptPhase: String, Codable, Equatable, Sendable {
    case intentRecorded = "intent_recorded"
    case succeeded
    case failed
    case reconciliationRequired = "reconciliation_required"
}

struct StageDProviderDecision: Codable, Equatable, Sendable {
    let toolCallID: String
    let command: String
    let cwd: String
    let assistantSHA256: String
}

struct StageDAttemptEvidence: Codable, Equatable, Sendable {
    let taskID: UUID
    let operationID: UUID
    let attemptID: UUID
    let kind: StageDExternalIOKind
    let phase: StageDAttemptPhase
    let inputSHA256: String
    let recordedAt: Date
    let command: StageDAuthorizedCommand?
    let approvalBindingSHA256: String?
    let providerDecision: StageDProviderDecision?
    let result: StageDCommandResult?
    let resultSHA256: String?
}

enum StageDTaskPhase: String, Codable, Equatable, Sendable {
    case ready
    case awaitingApproval = "awaiting_approval"
    case executing
    case verifying
    case completed
    case rejected
    case failed
    case reconciliationRequired = "reconciliation_required"
}

enum StageDCompletionKind: String, Codable, Equatable, Sendable {
    case exactFile = "exact_file"
    case exactClone = "exact_clone"
    case successfulCommand = "successful_command"
}

struct StageDCompletionExpectation: Codable, Equatable, Sendable {
    let kind: StageDCompletionKind
    let relativePath: String?
    let expectedSHA256: String?
    let cloneTarget: String?
    let cloneRemote: String?
    let cloneHEAD: String?
}

struct StageDCompletion: Codable, Equatable, Sendable {
    let taskID: UUID
    let sessionID: UUID
    let workspaceIdentitySHA256: String
    let commandBindingSHA256: String
    let approvalBindingSHA256: String?
    let operationID: UUID
    let attemptID: UUID
    let resultSHA256: String
    let verificationSHA256: String
    let completedAt: Date
}

struct StageDTaskRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let sessionID: UUID
    let importID: UUID
    let workspaceID: UUID
    let workspaceIdentitySHA256: String
    let workspaceRootSHA256: String
    let goalBindingSHA256: String
    let ruleSetBindingSHA256: String
    let cloneRootSHA256: String
    let write: StageDBoundedWrite?
    let expectation: StageDCompletionExpectation
    let createdAt: Date
    var updatedAt: Date
    var phase: StageDTaskPhase
    var approvals: [StageDApprovalEvidence]
    var attempts: [StageDAttemptEvidence]
    var completion: StageDCompletion?
}

enum StageDLoopOutcome: Equatable, Sendable {
    case completed(StageDCompletion)
    case pendingApproval
    case rejected(StageDCommandError)
    case failed(StageDCommandError)
    case reconciliationRequired
}

actor StageDWorkspaceGate {
    static let shared = StageDWorkspaceGate()
    private var holders: [String: UUID] = [:]

    func acquire(_ identity: String) -> UUID? {
        guard holders[identity] == nil else { return nil }
        let token = UUID()
        holders[identity] = token
        return token
    }

    func release(_ identity: String, token: UUID) {
        guard holders[identity] == token else { return }
        holders.removeValue(forKey: identity)
    }
}
