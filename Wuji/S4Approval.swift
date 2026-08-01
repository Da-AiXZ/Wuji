import Foundation

enum S4ApprovalRejection: String, Codable, Equatable, Sendable {
    case rejected
    case expired
    case tampered
    case replayed
    case busy
    case unavailable
}

struct S4ApprovalRequest: Codable, Equatable, Sendable {
    let requestID: UUID
    let taskID: UUID
    let workspaceID: String
    let workspaceSnapshotSHA256: String
    let toolCallID: String
    let relativePath: String
    let beforeSHA256: String
    let afterSHA256: String
    let changeSummarySHA256: String
    let verificationProfile: S4VerificationProfile
    let nonce: UUID
    let createdAt: Date
    let expiresAt: Date

    var bindingSHA256: String {
        ProviderDigest.sha256Hex([
            requestID.uuidString.lowercased(),
            taskID.uuidString.lowercased(),
            workspaceID,
            workspaceSnapshotSHA256,
            toolCallID,
            relativePath,
            beforeSHA256,
            afterSHA256,
            changeSummarySHA256,
            verificationProfile.rawValue,
            nonce.uuidString.lowercased(),
            String(createdAt.timeIntervalSince1970),
            String(expiresAt.timeIntervalSince1970)
        ].joined(separator: "\u{0}"))
    }

    func valid(for workspace: S4ApprovedWorkspace, now: Date) -> Bool {
        requestID != nonce
            && taskID == workspace.taskID
            && workspaceID == workspace.workspaceID
            && workspaceSnapshotSHA256 == workspace.seedSnapshotSHA256
            && !toolCallID.isEmpty
            && toolCallID.utf8.count <= ProviderLimits.maximumToolCallIDBytes
            && relativePath == S4TaskContract.authorizedPath
            && beforeSHA256 == S4TaskContract.beforeHash
            && afterSHA256 == S4TaskContract.afterHash
            && changeSummarySHA256 == S4TaskContract.changeSummaryHash
            && verificationProfile == S4TaskContract.verificationProfile
            && expiresAt > createdAt
            && expiresAt.timeIntervalSince(createdAt) <= S4Limits.maximumApprovalSeconds
            && now <= expiresAt
    }
}

struct S4ApprovalGrant: Codable, Equatable, Sendable {
    let requestID: UUID
    let requestBindingSHA256: String
    let nonce: UUID
    let approvedAt: Date
}

enum S4ApprovalDecision: Equatable, Sendable {
    case approved(S4ApprovalGrant)
    case rejected(S4ApprovalRejection)
}

protocol S4ApprovalAuthorizing: Sendable {
    func requestApproval(_ request: S4ApprovalRequest) async -> S4ApprovalDecision
}

enum S4ApprovalProjectionState: String, Equatable, Sendable {
    case idle
    case pendingApproval = "pending_approval"
    case approved
    case rejected
}

struct S4ApprovalProjection: Equatable, Sendable {
    let state: S4ApprovalProjectionState
    let request: S4ApprovalRequest?
}

enum S4ExecutionProjectionState: String, Equatable, Sendable {
    case running
    case reconciliationRequired = "reconciliation_required"
    case completed
    case failed
}

protocol S4ExecutionProjecting: Sendable {
    func report(_ state: S4ExecutionProjectionState) async
}

actor S4ExecutionProjectionBroker: S4ExecutionProjecting {
    static let shared = S4ExecutionProjectionBroker()

    private var state: S4ExecutionProjectionState?
    private var listeners: [UUID: AsyncStream<S4ExecutionProjectionState>.Continuation] = [:]

    func report(_ state: S4ExecutionProjectionState) async {
        self.state = state
        for listener in listeners.values { listener.yield(state) }
    }

    func snapshot() -> S4ExecutionProjectionState? { state }

    func projections() -> AsyncStream<S4ExecutionProjectionState> {
        let id = UUID()
        return AsyncStream { continuation in
            listeners[id] = continuation
            if let state { continuation.yield(state) }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeListener(id) }
            }
        }
    }

    private func removeListener(_ id: UUID) {
        listeners.removeValue(forKey: id)
    }
}

actor S4ApprovalBroker: S4ApprovalAuthorizing {
    static let shared = S4ApprovalBroker()

    private var pending: S4ApprovalRequest?
    private var continuation: CheckedContinuation<S4ApprovalDecision, Never>?
    private var listeners: [UUID: AsyncStream<S4ApprovalProjection>.Continuation] = [:]

    func requestApproval(_ request: S4ApprovalRequest) async -> S4ApprovalDecision {
        guard pending == nil, continuation == nil else { return .rejected(.busy) }
        pending = request
        emit(S4ApprovalProjection(state: .pendingApproval, request: request))
        return await withCheckedContinuation { continuation = $0 }
    }

    func approve(requestID: UUID, nonce: UUID, at date: Date = Date()) {
        guard let request = pending,
              request.requestID == requestID,
              request.nonce == nonce else {
            resolve(.rejected(.tampered), projection: .rejected)
            return
        }
        guard date <= request.expiresAt else {
            resolve(.rejected(.expired), projection: .rejected)
            return
        }
        resolve(.approved(S4ApprovalGrant(
            requestID: request.requestID,
            requestBindingSHA256: request.bindingSHA256,
            nonce: request.nonce,
            approvedAt: date
        )), projection: .approved)
    }

    func reject(requestID: UUID, nonce: UUID) {
        guard let request = pending,
              request.requestID == requestID,
              request.nonce == nonce else {
            resolve(.rejected(.tampered), projection: .rejected)
            return
        }
        resolve(.rejected(.rejected), projection: .rejected)
    }

    func snapshot() -> S4ApprovalProjection {
        S4ApprovalProjection(
            state: pending == nil ? .idle : .pendingApproval,
            request: pending
        )
    }

    func projections() -> AsyncStream<S4ApprovalProjection> {
        let id = UUID()
        return AsyncStream { continuation in
            listeners[id] = continuation
            continuation.yield(S4ApprovalProjection(
                state: pending == nil ? .idle : .pendingApproval,
                request: pending
            ))
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeListener(id) }
            }
        }
    }

    private func resolve(
        _ decision: S4ApprovalDecision,
        projection: S4ApprovalProjectionState
    ) {
        let request = pending
        pending = nil
        let saved = continuation
        continuation = nil
        emit(S4ApprovalProjection(state: projection, request: request))
        saved?.resume(returning: decision)
    }

    private func emit(_ projection: S4ApprovalProjection) {
        for listener in listeners.values { listener.yield(projection) }
    }

    private func removeListener(_ id: UUID) {
        listeners.removeValue(forKey: id)
    }
}

struct S4ValidationApprovalAuthorizer: S4ApprovalAuthorizing, Sendable {
    let probeMode: Bool
    let taskPackageID: String
    let workspace: S4ApprovedWorkspace
    let now: @Sendable () -> Date

    func requestApproval(_ request: S4ApprovalRequest) async -> S4ApprovalDecision {
        let date = now()
        guard probeMode,
              taskPackageID == S4TaskContract.packageID,
              request.valid(for: workspace, now: date) else {
            return .rejected(.unavailable)
        }
        return .approved(S4ApprovalGrant(
            requestID: request.requestID,
            requestBindingSHA256: request.bindingSHA256,
            nonce: request.nonce,
            approvedAt: date
        ))
    }
}
