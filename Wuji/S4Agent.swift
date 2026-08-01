import Foundation

struct S4Completion: Equatable, Sendable {
    let taskID: UUID
    let authorizedPath: String
    let beforeSHA256: String
    let afterSHA256: String
    let workspaceDiffSHA256: String
    let providerRequestCount: Int
    let toolExecutionCount: Int
}

enum S4LoopFailure: String, Error, Equatable, Sendable {
    case durableEvidenceUnavailable = "durable_evidence_unavailable"
    case providerFailure = "provider_failure"
    case policyRejected = "policy_rejected"
    case approvalRejected = "approval_rejected"
    case approvalExpired = "approval_expired"
    case approvalTampered = "approval_tampered"
    case writerBusy = "writer_busy"
    case executorFailure = "executor_failure"
    case completionNotEstablished = "completion_not_established"
    case limitsExceeded = "limits_exceeded"
}

enum S4LoopOutcome: Equatable, Sendable {
    case completed(S4Completion)
    case failure(S4LoopFailure)
    case policyRejected(S4BatchPolicyError)
    case reconciliationRequired
}

protocol S4WriterSerializing: Sendable {
    func acquire(workspaceID: String) async -> UUID?
    func release(workspaceID: String, token: UUID) async
}

actor S4WorkspaceWriterGate: S4WriterSerializing {
    static let shared = S4WorkspaceWriterGate()
    private var active: [String: UUID] = [:]

    func acquire(workspaceID: String) async -> UUID? {
        guard active[workspaceID] == nil else { return nil }
        let token = UUID()
        active[workspaceID] = token
        return token
    }

    func release(workspaceID: String, token: UUID) async {
        guard active[workspaceID] == token else { return }
        active.removeValue(forKey: workspaceID)
    }
}

private enum S4StepResult<Value> {
    case success(Value)
    case failure(S4LoopFailure)
    case reconciliationRequired
}

final class S4Agent: @unchecked Sendable {
    private let provider: AgentInferenceProvider
    private let executor: S4Executing
    private let policy: S4ToolPolicy
    private let durableStore: S4DurableRecording
    private let approvalAuthorizer: S4ApprovalAuthorizing
    private let writerGate: S4WriterSerializing
    private let executionProjection: S4ExecutionProjecting
    private let workspace: S4ApprovedWorkspace
    private let now: @Sendable () -> Date
    private let makeUUID: @Sendable () -> UUID

    init(
        provider: AgentInferenceProvider,
        executor: S4Executing,
        policy: S4ToolPolicy,
        durableStore: S4DurableRecording,
        approvalAuthorizer: S4ApprovalAuthorizing,
        writerGate: S4WriterSerializing = S4WorkspaceWriterGate.shared,
        executionProjection: S4ExecutionProjecting = S4ExecutionProjectionBroker.shared,
        workspace: S4ApprovedWorkspace,
        now: @escaping @Sendable () -> Date = { Date() },
        makeUUID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.provider = provider
        self.executor = executor
        self.policy = policy
        self.durableStore = durableStore
        self.approvalAuthorizer = approvalAuthorizer
        self.writerGate = writerGate
        self.executionProjection = executionProjection
        self.workspace = workspace
        self.now = now
        self.makeUUID = makeUUID
    }

    func run(taskID: UUID) async -> S4LoopOutcome {
        guard taskID == workspace.taskID else {
            await executionProjection.report(.failed)
            return .failure(.policyRejected)
        }
        let initialSnapshot: S4DurableSnapshot
        do {
            initialSnapshot = try await durableStore.snapshot(taskID: taskID)
        } catch {
            await executionProjection.report(.failed)
            return .failure(.durableEvidenceUnavailable)
        }
        await executionProjection.report(.running)
        let outcome: S4LoopOutcome
        if initialSnapshot.approvals.isEmpty,
           initialSnapshot.attempts.allSatisfy({ $0.ioKind == .workspacePrepare }) {
            outcome = await runFresh(taskID: taskID)
        } else {
            outcome = await recover(taskID: taskID, snapshot: initialSnapshot)
        }
        switch outcome {
        case .completed: await executionProjection.report(.completed)
        case .reconciliationRequired: await executionProjection.report(.reconciliationRequired)
        case .failure, .policyRejected: await executionProjection.report(.failed)
        }
        return outcome
    }

    private func runFresh(taskID: UUID) async -> S4LoopOutcome {
        var messages = [
            ProviderTurnMessage(role: .system, content: S4TaskContract.systemPrompt),
            ProviderTurnMessage(role: .user, content: S4TaskContract.goal)
        ]
        var readObservations: [S3ToolObservation] = []
        var editObservation: S4EditObservation?
        var verifyObservation: S4VerifyObservation?
        var approvalGrant: S4ApprovalGrant?
        var approvalRequest: S4ApprovalRequest?
        var phase = S4PolicyPhase.inspecting
        var providerRequestCount = 0
        var toolExecutionCount = 0

        for _ in 0..<S4Limits.maximumProviderTurns {
            guard messages.count <= ProviderLimits.maximumTurnMessages,
                  toolExecutionCount <= S4Limits.maximumToolExecutions else {
                return .failure(.limitsExceeded)
            }
            let request = ProviderInferenceRequest(
                messages: messages,
                tools: S4ToolPolicy.toolDefinitions(for: phase),
                requireTool: phase != .verified
            )
            let operationID = makeUUID()
            let attemptID = makeUUID()
            let inputHash = inferenceInputHash(request)
            guard await recordAttempt(intent(
                taskID: taskID,
                operationID: operationID,
                attemptID: attemptID,
                ioKind: .provider,
                providerID: provider.providerID,
                toolName: nil,
                toolCallID: nil,
                approvalNonce: nil,
                inputSHA256: inputHash
            )) else {
                return .failure(.durableEvidenceUnavailable)
            }

            providerRequestCount += 1
            let outcome = await provider.infer(request: request, requestID: makeUUID())
            switch outcome {
            case let .decision(decision):
                guard await recordTerminal(
                    taskID: taskID,
                    operationID: operationID,
                    attemptID: attemptID,
                    ioKind: .provider,
                    providerID: provider.providerID,
                    toolName: nil,
                    toolCallID: nil,
                    approvalNonce: nil,
                    inputSHA256: inputHash,
                    phase: .succeeded,
                    category: .providerDecision,
                    result: Data(decision.description.utf8)
                ) else { return .reconciliationRequired }

                switch decision {
                case let .finish(assistantMessage):
                    messages.append(assistantMessage)
                    if let editObservation,
                       let verifyObservation,
                       let approvalRequest,
                       let approvalGrant {
                        return await establishCompletion(
                            taskID: taskID,
                            providerRequestCount: providerRequestCount,
                            toolExecutionCount: toolExecutionCount,
                            approvalRequest: approvalRequest,
                            approvalGrant: approvalGrant,
                            editObservation: editObservation,
                            verifyObservation: verifyObservation
                        )
                    }
                    messages.append(ProviderTurnMessage(
                        role: .user,
                        content: "Completion rejected by the Swift Harness. Required inspection, explicit approval, bounded edit, fixed verification, and final workspace checks are incomplete. Continue with allowed typed tools."
                    ))

                case let .toolCalls(assistantMessage, calls):
                    guard !calls.isEmpty,
                          toolExecutionCount + calls.count <= S4Limits.maximumToolExecutions else {
                        return .failure(.limitsExceeded)
                    }
                    let usedIDs = Set(messages.flatMap { $0.toolCalls.map(\.id) })
                    let authorized: [S4AuthorizedToolCall]
                    do {
                        authorized = try policy.authorizeBatch(
                            calls,
                            phase: phase,
                            previouslyUsedIDs: usedIDs
                        )
                    } catch let error as S4BatchPolicyError {
                        return .policyRejected(error)
                    } catch {
                        return .failure(.policyRejected)
                    }
                    messages.append(assistantMessage)

                    for call in authorized {
                        switch call.tool {
                        case let .readOnly(tool):
                            let step = await executeRead(
                                taskID: taskID,
                                toolCallID: call.toolCallID,
                                tool: tool
                            )
                            switch step {
                            case let .success(observation):
                                toolExecutionCount += 1
                                readObservations.append(observation)
                                guard let content = try? observation.modelContent() else {
                                    return .failure(.executorFailure)
                                }
                                messages.append(ProviderTurnMessage(
                                    role: .tool,
                                    content: content,
                                    toolCallID: call.toolCallID
                                ))
                            case let .failure(failure): return .failure(failure)
                            case .reconciliationRequired: return .reconciliationRequired
                            }

                        case let .edit(edit):
                            let request = makeApprovalRequest(
                                taskID: taskID,
                                toolCallID: call.toolCallID,
                                edit: edit
                            )
                            let approval = await obtainApproval(request)
                            switch approval {
                            case let .success(grant):
                                approvalRequest = request
                                approvalGrant = grant
                                let step = await executeApprovedEdit(
                                    taskID: taskID,
                                    toolCallID: call.toolCallID,
                                    edit: edit,
                                    request: request,
                                    grant: grant
                                )
                                switch step {
                                case let .success(observation):
                                    toolExecutionCount += 1
                                    editObservation = observation
                                    phase = .edited
                                    messages.append(ProviderTurnMessage(
                                        role: .tool,
                                        content: observation.modelContent(),
                                        toolCallID: call.toolCallID
                                    ))
                                case let .failure(failure): return .failure(failure)
                                case .reconciliationRequired: return .reconciliationRequired
                                }
                            case let .failure(failure): return .failure(failure)
                            case .reconciliationRequired: return .reconciliationRequired
                            }

                        case let .verify(profile):
                            guard editObservation != nil,
                                  let approvalRequest,
                                  let approvalGrant else {
                                return .policyRejected(S4BatchPolicyError(
                                    reason: .stalePhase,
                                    callIndex: nil
                                ))
                            }
                            let step = await executeVerify(
                                taskID: taskID,
                                toolCallID: call.toolCallID,
                                profile: profile,
                                approvalRequest: approvalRequest,
                                approvalGrant: approvalGrant
                            )
                            switch step {
                            case let .success(observation):
                                toolExecutionCount += 1
                                verifyObservation = observation
                                phase = .verified
                                messages.append(ProviderTurnMessage(
                                    role: .tool,
                                    content: observation.modelContent(),
                                    toolCallID: call.toolCallID
                                ))
                            case let .failure(failure): return .failure(failure)
                            case .reconciliationRequired: return .reconciliationRequired
                            }
                        }
                    }
                    if phase == .inspecting,
                       S4InspectionVerifier.verify(readObservations) {
                        phase = .inspected
                    }
                }

            case .failure:
                let recorded = await recordTerminal(
                    taskID: taskID,
                    operationID: operationID,
                    attemptID: attemptID,
                    ioKind: .provider,
                    providerID: provider.providerID,
                    toolName: nil,
                    toolCallID: nil,
                    approvalNonce: nil,
                    inputSHA256: inputHash,
                    phase: .failed,
                    category: .providerFailure,
                    result: nil
                )
                return recorded ? .failure(.providerFailure) : .reconciliationRequired

            case .unknown:
                _ = await recordTerminal(
                    taskID: taskID,
                    operationID: operationID,
                    attemptID: attemptID,
                    ioKind: .provider,
                    providerID: provider.providerID,
                    toolName: nil,
                    toolCallID: nil,
                    approvalNonce: nil,
                    inputSHA256: inputHash,
                    phase: .reconciliationRequired,
                    category: .providerUnknown,
                    result: nil
                )
                return .reconciliationRequired
            }
        }
        return .failure(.completionNotEstablished)
    }

    private func obtainApproval(_ request: S4ApprovalRequest) async -> S4StepResult<S4ApprovalGrant> {
        guard await recordApproval(S4ApprovalEvidence(
            request: request,
            phase: .pending,
            recordedAt: now(),
            grant: nil,
            rejection: nil
        )) else {
            return .failure(.durableEvidenceUnavailable)
        }
        let decision = await approvalAuthorizer.requestApproval(request)
        switch decision {
        case let .approved(grant):
            guard valid(grant: grant, for: request, at: now()) else {
                _ = await recordApproval(S4ApprovalEvidence(
                    request: request,
                    phase: .rejected,
                    recordedAt: now(),
                    grant: nil,
                    rejection: .tampered
                ))
                return .failure(.approvalTampered)
            }
            guard await recordApproval(S4ApprovalEvidence(
                request: request,
                phase: .granted,
                recordedAt: now(),
                grant: grant,
                rejection: nil
            )) else {
                return .failure(.durableEvidenceUnavailable)
            }
            return .success(grant)
        case let .rejected(reason):
            let phase: S4ApprovalEvidencePhase = reason == .expired ? .expired : .rejected
            guard await recordApproval(S4ApprovalEvidence(
                request: request,
                phase: phase,
                recordedAt: now(),
                grant: nil,
                rejection: reason
            )) else { return .failure(.durableEvidenceUnavailable) }
            return .failure(reason == .expired ? .approvalExpired : .approvalRejected)
        }
    }

    private func executeRead(
        taskID: UUID,
        toolCallID: String,
        tool: S3AuthorizedTool
    ) async -> S4StepResult<S3ToolObservation> {
        let operationID = makeUUID()
        let attemptID = makeUUID()
        guard await recordAttempt(intent(
            taskID: taskID,
            operationID: operationID,
            attemptID: attemptID,
            ioKind: .readExecutor,
            providerID: nil,
            toolName: tool.name.rawValue,
            toolCallID: toolCallID,
            approvalNonce: nil,
            inputSHA256: tool.inputSHA256
        )) else { return .failure(.durableEvidenceUnavailable) }

        switch await executor.execute(tool) {
        case let .observation(observation):
            let result = (try? observation.modelContent()).map { Data($0.utf8) }
            guard await recordTerminal(
                taskID: taskID,
                operationID: operationID,
                attemptID: attemptID,
                ioKind: .readExecutor,
                providerID: nil,
                toolName: tool.name.rawValue,
                toolCallID: toolCallID,
                approvalNonce: nil,
                inputSHA256: tool.inputSHA256,
                phase: .succeeded,
                category: .observation,
                result: result
            ) else { return .reconciliationRequired }
            return .success(observation)
        case .failure:
            let recorded = await recordTerminal(
                taskID: taskID,
                operationID: operationID,
                attemptID: attemptID,
                ioKind: .readExecutor,
                providerID: nil,
                toolName: tool.name.rawValue,
                toolCallID: toolCallID,
                approvalNonce: nil,
                inputSHA256: tool.inputSHA256,
                phase: .failed,
                category: .executorFailure,
                result: nil
            )
            return recorded ? .failure(.executorFailure) : .reconciliationRequired
        case .unknown:
            _ = await recordTerminal(
                taskID: taskID,
                operationID: operationID,
                attemptID: attemptID,
                ioKind: .readExecutor,
                providerID: nil,
                toolName: tool.name.rawValue,
                toolCallID: toolCallID,
                approvalNonce: nil,
                inputSHA256: tool.inputSHA256,
                phase: .reconciliationRequired,
                category: .executorUnknown,
                result: nil
            )
            return .reconciliationRequired
        }
    }

    private func executeApprovedEdit(
        taskID: UUID,
        toolCallID: String,
        edit: S4AuthorizedEdit,
        request: S4ApprovalRequest,
        grant: S4ApprovalGrant
    ) async -> S4StepResult<S4EditObservation> {
        guard request.valid(for: workspace, now: grant.approvedAt),
              valid(grant: grant, for: request, at: now()) else {
            return .failure(.approvalTampered)
        }
        let preflight = await reconcileWorkspace(taskID: taskID)
        guard case let .success(inspection) = preflight else {
            if case .reconciliationRequired = preflight { return .reconciliationRequired }
            return .failure(.durableEvidenceUnavailable)
        }
        guard inspection.contentState == .before,
              !inspection.temporaryFilePresent,
              inspection.exactFileSet,
              inspection.contextUnchanged else {
            return .failure(.approvalTampered)
        }
        let snapshot: S4DurableSnapshot
        do { snapshot = try await durableStore.snapshot(taskID: taskID) }
        catch { return .failure(.durableEvidenceUnavailable) }
        let nonceHash = ProviderDigest.sha256Hex(request.nonce.uuidString.lowercased())
        guard !snapshot.attempts.contains(where: {
            $0.ioKind == .writeExecutor && $0.approvalNonceHash == nonceHash
        }) else {
            return .failure(.approvalTampered)
        }
        guard let writerToken = await writerGate.acquire(workspaceID: workspace.workspaceID) else {
            return .failure(.writerBusy)
        }

        let operationID = makeUUID()
        let attemptID = makeUUID()
        guard await recordAttempt(intent(
            taskID: taskID,
            operationID: operationID,
            attemptID: attemptID,
            ioKind: .writeExecutor,
            providerID: nil,
            toolName: S4ToolName.edit.rawValue,
            toolCallID: toolCallID,
            approvalNonce: request.nonce,
            inputSHA256: edit.inputSHA256
        )) else {
            await writerGate.release(workspaceID: workspace.workspaceID, token: writerToken)
            return .failure(.durableEvidenceUnavailable)
        }

        let outcome = await executor.edit(edit)
        await writerGate.release(workspaceID: workspace.workspaceID, token: writerToken)
        switch outcome {
        case let .observation(observation):
            guard await recordTerminal(
                taskID: taskID,
                operationID: operationID,
                attemptID: attemptID,
                ioKind: .writeExecutor,
                providerID: nil,
                toolName: S4ToolName.edit.rawValue,
                toolCallID: toolCallID,
                approvalNonce: request.nonce,
                inputSHA256: edit.inputSHA256,
                phase: .succeeded,
                category: .writeApplied,
                result: Data(observation.modelContent().utf8),
                facts: observation.facts
            ) else { return .reconciliationRequired }
            return .success(observation)
        case .failure:
            let recorded = await recordTerminal(
                taskID: taskID,
                operationID: operationID,
                attemptID: attemptID,
                ioKind: .writeExecutor,
                providerID: nil,
                toolName: S4ToolName.edit.rawValue,
                toolCallID: toolCallID,
                approvalNonce: request.nonce,
                inputSHA256: edit.inputSHA256,
                phase: .failed,
                category: .executorFailure,
                result: nil
            )
            return recorded ? .failure(.executorFailure) : .reconciliationRequired
        case .unknown:
            _ = await recordTerminal(
                taskID: taskID,
                operationID: operationID,
                attemptID: attemptID,
                ioKind: .writeExecutor,
                providerID: nil,
                toolName: S4ToolName.edit.rawValue,
                toolCallID: toolCallID,
                approvalNonce: request.nonce,
                inputSHA256: edit.inputSHA256,
                phase: .reconciliationRequired,
                category: .executorUnknown,
                result: nil
            )
            return .reconciliationRequired
        }
    }

    private func executeVerify(
        taskID: UUID,
        toolCallID: String,
        profile: S4VerificationProfile,
        approvalRequest: S4ApprovalRequest,
        approvalGrant: S4ApprovalGrant
    ) async -> S4StepResult<S4VerifyObservation> {
        guard valid(grant: approvalGrant, for: approvalRequest, at: approvalGrant.approvedAt),
              profile == approvalRequest.verificationProfile else {
            return .failure(.approvalTampered)
        }
        let operationID = makeUUID()
        let attemptID = makeUUID()
        let inputHash = ProviderDigest.sha256Hex(
            "verify\u{0}\(profile.rawValue)\u{0}\(approvalRequest.bindingSHA256)"
        )
        guard await recordAttempt(intent(
            taskID: taskID,
            operationID: operationID,
            attemptID: attemptID,
            ioKind: .verifyExecutor,
            providerID: nil,
            toolName: S4ToolName.verify.rawValue,
            toolCallID: toolCallID,
            approvalNonce: approvalRequest.nonce,
            inputSHA256: inputHash
        )) else { return .failure(.durableEvidenceUnavailable) }

        switch await executor.verify(profile) {
        case let .observation(observation):
            guard await recordTerminal(
                taskID: taskID,
                operationID: operationID,
                attemptID: attemptID,
                ioKind: .verifyExecutor,
                providerID: nil,
                toolName: S4ToolName.verify.rawValue,
                toolCallID: toolCallID,
                approvalNonce: approvalRequest.nonce,
                inputSHA256: inputHash,
                phase: .succeeded,
                category: .verifyPassed,
                result: Data(observation.modelContent().utf8),
                facts: observation.facts
            ) else { return .reconciliationRequired }
            return .success(observation)
        case .failure:
            let recorded = await recordTerminal(
                taskID: taskID,
                operationID: operationID,
                attemptID: attemptID,
                ioKind: .verifyExecutor,
                providerID: nil,
                toolName: S4ToolName.verify.rawValue,
                toolCallID: toolCallID,
                approvalNonce: approvalRequest.nonce,
                inputSHA256: inputHash,
                phase: .failed,
                category: .executorFailure,
                result: nil
            )
            return recorded ? .failure(.executorFailure) : .reconciliationRequired
        case .unknown:
            _ = await recordTerminal(
                taskID: taskID,
                operationID: operationID,
                attemptID: attemptID,
                ioKind: .verifyExecutor,
                providerID: nil,
                toolName: S4ToolName.verify.rawValue,
                toolCallID: toolCallID,
                approvalNonce: approvalRequest.nonce,
                inputSHA256: inputHash,
                phase: .reconciliationRequired,
                category: .executorUnknown,
                result: nil
            )
            return .reconciliationRequired
        }
    }

    private func recover(taskID: UUID, snapshot: S4DurableSnapshot) async -> S4LoopOutcome {
        if let unknown = snapshot.attempts.last(where: {
            $0.phase == .reconciliationRequired
                && ($0.ioKind == .provider || $0.ioKind == .readExecutor)
        }) {
            _ = unknown
            return .reconciliationRequired
        }
        if let unknownWrite = snapshot.attempts.last(where: {
            $0.phase == .reconciliationRequired && $0.ioKind == .writeExecutor
        }),
           let writeIntent = snapshot.attempts.first(where: {
               $0.attemptID == unknownWrite.attemptID && $0.phase == .intentRecorded
           }) {
            return await reconcileWrite(taskID: taskID, attempt: writeIntent, snapshot: snapshot)
        }
        if snapshot.attempts.contains(where: {
            $0.phase == .reconciliationRequired && $0.ioKind == .verifyExecutor
        }) {
            return await reconcileThenVerify(taskID: taskID, snapshot: snapshot)
        }
        let unresolved = unresolvedAttempts(snapshot.attempts)
        if unresolved.count > 1 { return .reconciliationRequired }
        if let attempt = unresolved.first {
            switch attempt.ioKind {
            case .provider, .readExecutor:
                _ = await recordRecoveredTerminal(
                    attempt,
                    phase: .reconciliationRequired,
                    category: attempt.ioKind == .provider ? .providerUnknown : .executorUnknown
                )
                return .reconciliationRequired
            case .writeExecutor:
                return await reconcileWrite(taskID: taskID, attempt: attempt, snapshot: snapshot)
            case .verifyExecutor:
                _ = await recordRecoveredTerminal(
                    attempt,
                    phase: .reconciliationRequired,
                    category: .executorUnknown
                )
                return await reconcileThenVerify(taskID: taskID, snapshot: snapshot)
            case .workspacePrepare, .reconciliation, .completionCheck:
                return .reconciliationRequired
            }
        }

        guard let approval = latestApproval(snapshot.approvals) else {
            return .reconciliationRequired
        }
        switch approval.phase {
        case .pending:
            guard approval.request.valid(for: workspace, now: now()) else {
                _ = await recordApproval(S4ApprovalEvidence(
                    request: approval.request,
                    phase: .expired,
                    recordedAt: now(),
                    grant: nil,
                    rejection: .expired
                ))
                return .failure(.approvalExpired)
            }
            let resumed = await approvalAuthorizer.requestApproval(approval.request)
            switch resumed {
            case let .approved(grant):
                guard valid(grant: grant, for: approval.request, at: now()),
                      await recordApproval(S4ApprovalEvidence(
                          request: approval.request,
                          phase: .granted,
                          recordedAt: now(),
                          grant: grant,
                          rejection: nil
                      )) else { return .failure(.approvalTampered) }
                return await recoverFromGrant(taskID: taskID, request: approval.request, grant: grant)
            case let .rejected(reason):
                _ = await recordApproval(S4ApprovalEvidence(
                    request: approval.request,
                    phase: reason == .expired ? .expired : .rejected,
                    recordedAt: now(),
                    grant: nil,
                    rejection: reason
                ))
                return .failure(reason == .expired ? .approvalExpired : .approvalRejected)
            }
        case .granted:
            guard let grant = approval.grant else { return .failure(.approvalTampered) }
            if let verifyTerminal = snapshot.attempts.last(where: {
                $0.ioKind == .verifyExecutor
                    && $0.phase == .succeeded
                    && $0.resultCategory == .verifyPassed
            }),
               let verifyFacts = facts(from: verifyTerminal),
               verifyFacts.completionBarrierSatisfied,
               !verifyFacts.truncated,
               verifyFacts.finalState == .exited(0),
               snapshot.attempts.contains(where: {
                   $0.ioKind == .writeExecutor
                       && ($0.phase == .succeeded || $0.phase == .reconciledApplied)
               }) {
                return await establishCompletion(
                    taskID: taskID,
                    providerRequestCount: 0,
                    toolExecutionCount: 0,
                    approvalRequest: approval.request,
                    approvalGrant: grant,
                    editObservation: S4EditObservation(
                        relativePath: approval.request.relativePath,
                        beforeSHA256: approval.request.beforeSHA256,
                        afterSHA256: approval.request.afterSHA256,
                        facts: syntheticRecoveredFacts()
                    ),
                    verifyObservation: S4VerifyObservation(
                        profile: approval.request.verificationProfile,
                        afterSHA256: approval.request.afterSHA256,
                        contextSHA256: S4TaskContract.contextHash,
                        facts: verifyFacts
                    )
                )
            }
            let writeTerminals = snapshot.attempts.filter {
                $0.ioKind == .writeExecutor && $0.phase != .intentRecorded
            }
            if writeTerminals.isEmpty {
                return await recoverFromGrant(taskID: taskID, request: approval.request, grant: grant)
            }
            if writeTerminals.contains(where: {
                $0.phase == .succeeded || $0.phase == .reconciledApplied
            }) {
                return await reconcileThenVerify(taskID: taskID, snapshot: snapshot)
            }
            return .reconciliationRequired
        case .rejected: return .failure(.approvalRejected)
        case .expired: return .failure(.approvalExpired)
        }
    }

    private func recoverFromGrant(
        taskID: UUID,
        request: S4ApprovalRequest,
        grant: S4ApprovalGrant
    ) async -> S4LoopOutcome {
        let edit = S4AuthorizedEdit(
            relativePath: request.relativePath,
            beforeHash: request.beforeSHA256,
            afterHash: request.afterSHA256
        )
        let editStep = await executeApprovedEdit(
            taskID: taskID,
            toolCallID: request.toolCallID,
            edit: edit,
            request: request,
            grant: grant
        )
        switch editStep {
        case let .success(editObservation):
            let verifyStep = await executeVerify(
                taskID: taskID,
                toolCallID: "recovery-verify-\(makeUUID().uuidString.lowercased())",
                profile: request.verificationProfile,
                approvalRequest: request,
                approvalGrant: grant
            )
            switch verifyStep {
            case let .success(verifyObservation):
                return await establishCompletion(
                    taskID: taskID,
                    providerRequestCount: 0,
                    toolExecutionCount: 2,
                    approvalRequest: request,
                    approvalGrant: grant,
                    editObservation: editObservation,
                    verifyObservation: verifyObservation
                )
            case let .failure(failure): return .failure(failure)
            case .reconciliationRequired: return .reconciliationRequired
            }
        case let .failure(failure): return .failure(failure)
        case .reconciliationRequired: return .reconciliationRequired
        }
    }

    private func reconcileWrite(
        taskID: UUID,
        attempt: S4AttemptEvidence,
        snapshot: S4DurableSnapshot
    ) async -> S4LoopOutcome {
        let inspection = await reconcileWorkspace(taskID: taskID)
        switch inspection {
        case let .success(value):
            if value.contentState == .before,
               !value.temporaryFilePresent,
               value.exactFileSet,
               value.contextUnchanged {
                _ = await recordRecoveredTerminal(
                    attempt,
                    phase: .reconciledNotApplied,
                    category: .workspaceBefore
                )
                return .reconciliationRequired
            }
            if value.contentState == .after,
               !value.temporaryFilePresent,
               value.exactFileSet,
               value.contextUnchanged {
                guard await recordRecoveredTerminal(
                    attempt,
                    phase: .reconciledApplied,
                    category: .workspaceAfter
                ) else { return .reconciliationRequired }
                return await reconcileThenVerify(taskID: taskID, snapshot: snapshot)
            }
            _ = await recordRecoveredTerminal(
                attempt,
                phase: .manualReconciliation,
                category: .workspaceOther
            )
            return .reconciliationRequired
        case .failure: return .failure(.durableEvidenceUnavailable)
        case .reconciliationRequired: return .reconciliationRequired
        }
    }

    private func reconcileThenVerify(
        taskID: UUID,
        snapshot: S4DurableSnapshot
    ) async -> S4LoopOutcome {
        let inspection = await reconcileWorkspace(taskID: taskID)
        guard case let .success(value) = inspection,
              value.contentState == .after,
              !value.temporaryFilePresent,
              value.exactFileSet,
              value.contextUnchanged,
              let approval = latestApproval(snapshot.approvals),
              approval.phase == .granted,
              let grant = approval.grant,
              valid(grant: grant, for: approval.request, at: grant.approvedAt) else {
            return .reconciliationRequired
        }
        let verifyStep = await executeVerify(
            taskID: taskID,
            toolCallID: "recovery-verify-\(makeUUID().uuidString.lowercased())",
            profile: approval.request.verificationProfile,
            approvalRequest: approval.request,
            approvalGrant: grant
        )
        switch verifyStep {
        case let .success(verifyObservation):
            let editObservation = S4EditObservation(
                relativePath: approval.request.relativePath,
                beforeSHA256: approval.request.beforeSHA256,
                afterSHA256: approval.request.afterSHA256,
                facts: syntheticRecoveredFacts()
            )
            return await establishCompletion(
                taskID: taskID,
                providerRequestCount: 0,
                toolExecutionCount: 1,
                approvalRequest: approval.request,
                approvalGrant: grant,
                editObservation: editObservation,
                verifyObservation: verifyObservation
            )
        case let .failure(failure): return .failure(failure)
        case .reconciliationRequired: return .reconciliationRequired
        }
    }

    private func reconcileWorkspace(taskID: UUID) async -> S4StepResult<S4WorkspaceInspection> {
        let operationID = makeUUID()
        let attemptID = makeUUID()
        let inputHash = ProviderDigest.sha256Hex("reconcile\u{0}\(workspace.workspaceID)")
        guard await recordAttempt(intent(
            taskID: taskID,
            operationID: operationID,
            attemptID: attemptID,
            ioKind: .reconciliation,
            providerID: nil,
            toolName: nil,
            toolCallID: nil,
            approvalNonce: nil,
            inputSHA256: inputHash
        )) else { return .failure(.durableEvidenceUnavailable) }
        do {
            let inspection = try workspace.inspect()
            let category: S4AttemptResultCategory
            switch inspection.contentState {
            case .before: category = .workspaceBefore
            case .after: category = .workspaceAfter
            case .other: category = .workspaceOther
            }
            guard await recordTerminal(
                taskID: taskID,
                operationID: operationID,
                attemptID: attemptID,
                ioKind: .reconciliation,
                providerID: nil,
                toolName: nil,
                toolCallID: nil,
                approvalNonce: nil,
                inputSHA256: inputHash,
                phase: .succeeded,
                category: category,
                result: Data(inspection.workspaceDiffSHA256.utf8)
            ) else { return .reconciliationRequired }
            return .success(inspection)
        } catch {
            let recorded = await recordTerminal(
                taskID: taskID,
                operationID: operationID,
                attemptID: attemptID,
                ioKind: .reconciliation,
                providerID: nil,
                toolName: nil,
                toolCallID: nil,
                approvalNonce: nil,
                inputSHA256: inputHash,
                phase: .manualReconciliation,
                category: .workspaceOther,
                result: nil
            )
            return recorded ? .reconciliationRequired : .failure(.durableEvidenceUnavailable)
        }
    }

    private func establishCompletion(
        taskID: UUID,
        providerRequestCount: Int,
        toolExecutionCount: Int,
        approvalRequest: S4ApprovalRequest,
        approvalGrant: S4ApprovalGrant,
        editObservation: S4EditObservation,
        verifyObservation: S4VerifyObservation
    ) async -> S4LoopOutcome {
        guard valid(grant: approvalGrant, for: approvalRequest, at: approvalGrant.approvedAt),
              editObservation.relativePath == S4TaskContract.authorizedPath,
              editObservation.beforeSHA256 == S4TaskContract.beforeHash,
              editObservation.afterSHA256 == S4TaskContract.afterHash,
              editObservation.facts.completionBarrierSatisfied,
              !editObservation.facts.truncated,
              editObservation.facts.finalState == .exited(0),
              verifyObservation.profile == S4TaskContract.verificationProfile,
              verifyObservation.afterSHA256 == S4TaskContract.afterHash,
              verifyObservation.contextSHA256 == S4TaskContract.contextHash,
              verifyObservation.facts.completionBarrierSatisfied,
              !verifyObservation.facts.truncated,
              verifyObservation.facts.finalState == .exited(0) else {
            return .failure(.completionNotEstablished)
        }

        let operationID = makeUUID()
        let attemptID = makeUUID()
        let inputHash = ProviderDigest.sha256Hex(
            "completion\u{0}\(approvalRequest.bindingSHA256)\u{0}\(S4TaskContract.afterHash)"
        )
        guard await recordAttempt(intent(
            taskID: taskID,
            operationID: operationID,
            attemptID: attemptID,
            ioKind: .completionCheck,
            providerID: nil,
            toolName: nil,
            toolCallID: nil,
            approvalNonce: approvalRequest.nonce,
            inputSHA256: inputHash
        )) else { return .failure(.durableEvidenceUnavailable) }
        do {
            let inspection = try workspace.inspect()
            guard inspection.contentState == .after,
                  inspection.exactFileSet,
                  inspection.contextUnchanged,
                  !inspection.temporaryFilePresent else {
                _ = await recordTerminal(
                    taskID: taskID,
                    operationID: operationID,
                    attemptID: attemptID,
                    ioKind: .completionCheck,
                    providerID: nil,
                    toolName: nil,
                    toolCallID: nil,
                    approvalNonce: approvalRequest.nonce,
                    inputSHA256: inputHash,
                    phase: .failed,
                    category: .workspaceOther,
                    result: nil
                )
                return .failure(.completionNotEstablished)
            }
            guard await recordTerminal(
                taskID: taskID,
                operationID: operationID,
                attemptID: attemptID,
                ioKind: .completionCheck,
                providerID: nil,
                toolName: nil,
                toolCallID: nil,
                approvalNonce: approvalRequest.nonce,
                inputSHA256: inputHash,
                phase: .succeeded,
                category: .completionEstablished,
                result: Data(inspection.workspaceDiffSHA256.utf8)
            ) else { return .reconciliationRequired }
            let finalSnapshot = try await durableStore.snapshot(taskID: taskID)
            guard unresolvedAttempts(finalSnapshot.attempts).isEmpty else {
                return .reconciliationRequired
            }
            return .completed(S4Completion(
                taskID: taskID,
                authorizedPath: S4TaskContract.authorizedPath,
                beforeSHA256: S4TaskContract.beforeHash,
                afterSHA256: S4TaskContract.afterHash,
                workspaceDiffSHA256: inspection.workspaceDiffSHA256,
                providerRequestCount: providerRequestCount,
                toolExecutionCount: toolExecutionCount
            ))
        } catch {
            let recorded = await recordTerminal(
                taskID: taskID,
                operationID: operationID,
                attemptID: attemptID,
                ioKind: .completionCheck,
                providerID: nil,
                toolName: nil,
                toolCallID: nil,
                approvalNonce: approvalRequest.nonce,
                inputSHA256: inputHash,
                phase: .failed,
                category: .workspaceOther,
                result: nil
            )
            return recorded ? .failure(.completionNotEstablished) : .reconciliationRequired
        }
    }

    private func makeApprovalRequest(
        taskID: UUID,
        toolCallID: String,
        edit: S4AuthorizedEdit
    ) -> S4ApprovalRequest {
        let date = now()
        return S4ApprovalRequest(
            requestID: makeUUID(),
            taskID: taskID,
            workspaceID: workspace.workspaceID,
            workspaceSnapshotSHA256: workspace.seedSnapshotSHA256,
            toolCallID: toolCallID,
            relativePath: edit.relativePath,
            beforeSHA256: edit.beforeHash,
            afterSHA256: edit.afterHash,
            changeSummarySHA256: S4TaskContract.changeSummaryHash,
            verificationProfile: S4TaskContract.verificationProfile,
            nonce: makeUUID(),
            createdAt: date,
            expiresAt: date.addingTimeInterval(S4Limits.maximumApprovalSeconds)
        )
    }

    private func valid(
        grant: S4ApprovalGrant,
        for request: S4ApprovalRequest,
        at date: Date
    ) -> Bool {
        request.valid(for: workspace, now: date)
            && grant.requestID == request.requestID
            && grant.requestBindingSHA256 == request.bindingSHA256
            && grant.nonce == request.nonce
            && grant.approvedAt >= request.createdAt
            && grant.approvedAt <= request.expiresAt
            && grant.approvedAt <= date
    }

    private func inferenceInputHash(_ request: ProviderInferenceRequest) -> String {
        var parts = ["requireTool=\(request.requireTool)"]
        parts.append(contentsOf: request.tools.map { "tool=\($0.name)" })
        for message in request.messages {
            parts.append("role=\(message.role.rawValue)")
            parts.append("content=\(message.content.map { ProviderDigest.sha256Hex($0) } ?? "none")")
            parts.append(contentsOf: message.toolCalls.map {
                "call=\(ProviderDigest.sha256Hex($0.id)):\($0.name):\(ProviderDigest.sha256Hex($0.arguments))"
            })
            parts.append("toolCallID=\(message.toolCallID.map { ProviderDigest.sha256Hex($0) } ?? "none")")
        }
        return ProviderDigest.sha256Hex(parts.joined(separator: "\n"))
    }

    private func intent(
        taskID: UUID,
        operationID: UUID,
        attemptID: UUID,
        ioKind: S4ExternalIOKind,
        providerID: String?,
        toolName: String?,
        toolCallID: String?,
        approvalNonce: UUID?,
        inputSHA256: String
    ) -> S4AttemptEvidence {
        evidence(
            taskID: taskID,
            operationID: operationID,
            attemptID: attemptID,
            ioKind: ioKind,
            providerID: providerID,
            toolName: toolName,
            toolCallID: toolCallID,
            approvalNonce: approvalNonce,
            inputSHA256: inputSHA256,
            phase: .intentRecorded,
            category: .none,
            result: nil
        )
    }

    private func evidence(
        taskID: UUID,
        operationID: UUID,
        attemptID: UUID,
        ioKind: S4ExternalIOKind,
        providerID: String?,
        toolName: String?,
        toolCallID: String?,
        approvalNonce: UUID?,
        inputSHA256: String,
        phase: S4AttemptPhase,
        category: S4AttemptResultCategory,
        result: Data?,
        facts: S3ExecutorFacts? = nil
    ) -> S4AttemptEvidence {
        S4AttemptEvidence(
            taskID: taskID,
            operationID: operationID,
            attemptID: attemptID,
            ioKind: ioKind,
            providerID: providerID,
            toolName: toolName,
            toolCallIDHash: toolCallID.map(ProviderDigest.sha256Hex),
            approvalNonceHash: approvalNonce.map { ProviderDigest.sha256Hex($0.uuidString.lowercased()) },
            inputSHA256: inputSHA256,
            recordedAt: now(),
            phase: phase,
            resultCategory: category,
            resultByteCount: result?.count,
            resultSHA256: result.map(ProviderDigest.sha256Hex),
            rootExitObserved: facts?.rootExitObserved,
            stdoutEOFObserved: facts?.stdoutEOFObserved,
            stderrEOFObserved: facts?.stderrEOFObserved,
            finalStateKind: facts.map { finalStateFields($0.finalState).kind },
            finalStateValue: facts.map { finalStateFields($0.finalState).value },
            truncated: facts?.truncated
        )
    }

    private func recordTerminal(
        taskID: UUID,
        operationID: UUID,
        attemptID: UUID,
        ioKind: S4ExternalIOKind,
        providerID: String?,
        toolName: String?,
        toolCallID: String?,
        approvalNonce: UUID?,
        inputSHA256: String,
        phase: S4AttemptPhase,
        category: S4AttemptResultCategory,
        result: Data?,
        facts: S3ExecutorFacts? = nil
    ) async -> Bool {
        await recordAttempt(evidence(
            taskID: taskID,
            operationID: operationID,
            attemptID: attemptID,
            ioKind: ioKind,
            providerID: providerID,
            toolName: toolName,
            toolCallID: toolCallID,
            approvalNonce: approvalNonce,
            inputSHA256: inputSHA256,
            phase: phase,
            category: category,
            result: result,
            facts: facts
        ))
    }

    private func recordRecoveredTerminal(
        _ attempt: S4AttemptEvidence,
        phase: S4AttemptPhase,
        category: S4AttemptResultCategory
    ) async -> Bool {
        await recordAttempt(S4AttemptEvidence(
            taskID: attempt.taskID,
            operationID: attempt.operationID,
            attemptID: attempt.attemptID,
            ioKind: attempt.ioKind,
            providerID: attempt.providerID,
            toolName: attempt.toolName,
            toolCallIDHash: attempt.toolCallIDHash,
            approvalNonceHash: attempt.approvalNonceHash,
            inputSHA256: attempt.inputSHA256,
            recordedAt: now(),
            phase: phase,
            resultCategory: category,
            resultByteCount: nil,
            resultSHA256: nil,
            rootExitObserved: attempt.rootExitObserved,
            stdoutEOFObserved: attempt.stdoutEOFObserved,
            stderrEOFObserved: attempt.stderrEOFObserved,
            finalStateKind: attempt.finalStateKind,
            finalStateValue: attempt.finalStateValue,
            truncated: attempt.truncated
        ))
    }

    private func recordAttempt(_ evidence: S4AttemptEvidence) async -> Bool {
        do { try await durableStore.recordAttempt(evidence); return true }
        catch { return false }
    }

    private func recordApproval(_ evidence: S4ApprovalEvidence) async -> Bool {
        do { try await durableStore.recordApproval(evidence); return true }
        catch { return false }
    }

    private func unresolvedAttempts(_ attempts: [S4AttemptEvidence]) -> [S4AttemptEvidence] {
        let groups = Dictionary(grouping: attempts, by: \.attemptID)
        return groups.values.compactMap { records in
            guard let intent = records.first(where: { $0.phase == .intentRecorded }),
                  !records.contains(where: { $0.phase != .intentRecorded }) else { return nil }
            return intent
        }.sorted { $0.recordedAt < $1.recordedAt }
    }

    private func latestApproval(_ approvals: [S4ApprovalEvidence]) -> S4ApprovalEvidence? {
        approvals.last
    }

    private func syntheticRecoveredFacts() -> S3ExecutorFacts {
        S3ExecutorFacts(
            rootExitObserved: true,
            stdoutEOFObserved: true,
            stderrEOFObserved: true,
            finalState: .exited(0),
            stdoutByteCount: 0,
            stderrByteCount: 0,
            stdoutSHA256: ProviderDigest.sha256Hex(Data()),
            stderrSHA256: ProviderDigest.sha256Hex(Data()),
            truncated: false
        )
    }

    private func finalStateFields(_ state: ExecutorFinalState) -> (kind: String, value: Int32) {
        switch state {
        case let .exited(value): return ("exited", value)
        case let .signaled(value): return ("signaled", value)
        case .unknown: return ("signaled", -1)
        }
    }

    private func facts(from evidence: S4AttemptEvidence) -> S3ExecutorFacts? {
        guard let rootExit = evidence.rootExitObserved,
              let stdoutEOF = evidence.stdoutEOFObserved,
              let stderrEOF = evidence.stderrEOFObserved,
              let kind = evidence.finalStateKind,
              let value = evidence.finalStateValue,
              let truncated = evidence.truncated else { return nil }
        let finalState: ExecutorFinalState = kind == "exited" ? .exited(value) : .signaled(value)
        return S3ExecutorFacts(
            rootExitObserved: rootExit,
            stdoutEOFObserved: stdoutEOF,
            stderrEOFObserved: stderrEOF,
            finalState: finalState,
            stdoutByteCount: evidence.resultByteCount ?? 0,
            stderrByteCount: 0,
            stdoutSHA256: evidence.resultSHA256 ?? ProviderDigest.sha256Hex(Data()),
            stderrSHA256: ProviderDigest.sha256Hex(Data()),
            truncated: truncated
        )
    }
}

private enum S4InspectionVerifier {
    static func verify(_ observations: [S3ToolObservation]) -> Bool {
        guard let listIndex = observations.firstIndex(where: {
            $0.tool == .list && $0.relativePath.isEmpty
        }) else { return false }
        for searchIndex in observations.indices where searchIndex > listIndex {
            let search = observations[searchIndex]
            guard search.tool == .search,
                  search.query == S4TaskContract.expectedOldText,
                  case let .search(matches) = search.payload,
                  matches.count == 1,
                  matches[0].path == S4TaskContract.authorizedPath,
                  matches[0].text == S4TaskContract.expectedOldText else { continue }
            guard case let .list(entries) = observations[listIndex].payload,
                  entries.contains("records") else { continue }
            for readIndex in observations.indices where readIndex > searchIndex {
                let read = observations[readIndex]
                guard read.tool == .read,
                      read.relativePath == S4TaskContract.authorizedPath,
                      case let .read(path, content) = read.payload,
                      path == S4TaskContract.authorizedPath,
                      content == S4TaskContract.expectedBeforeContent else { continue }
                return true
            }
        }
        return false
    }
}
