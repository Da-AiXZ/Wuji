import Foundation

private struct StageDProviderArguments: Decodable {
    let command: String
    let cwd: String
}

struct StageDValidationApprovalAuthorizer: StageDApprovalAuthorizing, Sendable {
    let enabledRisks: Set<StageDCommandRisk>
    let now: @Sendable () -> Date

    func requestApproval(_ request: StageDApprovalRequest) async -> StageDApprovalDecision {
        let date = now()
        guard enabledRisks.contains(request.risk), date <= request.expiresAt else {
            return .rejected
        }
        return .approved(.init(
            requestID: request.requestID,
            requestBindingSHA256: request.bindingSHA256,
            nonce: request.nonce,
            approvedAt: date
        ))
    }
}

enum StageDProviderContract {
    static let toolName = "run_shell_command"

    static let tool = ProviderToolDefinition(
        name: toolName,
        descriptionText: "Propose one strict single command for Swift policy classification and bounded iSH execution.",
        parameters: ProviderToolParameters(
            type: "object",
            properties: [
                "command": .init(type: "string", description: "One command string without shell composition."),
                "cwd": .init(type: "string", description: "A workspace-relative working directory, or dot.")
            ],
            required: ["command", "cwd"],
            additionalProperties: false
        )
    )

    static func request(for task: StageDTaskRecord) -> ProviderInferenceRequest {
        let command: String
        if let write = task.write {
            command = "sed -i \(write.sedExpression) \(write.relativePath)"
        } else {
            command = "pwd"
        }
        let system = ProviderTurnMessage(
            role: .system,
            content: "You propose one command only. Swift policy is the sole authority. Use only the provided command exactly; no quotes, shell operators, environment assignment, absolute path, or parent traversal."
        )
        let user = ProviderTurnMessage(
            role: .user,
            content: "Call \(toolName) once with command \(command) and cwd dot. Do not claim completion."
        )
        return ProviderInferenceRequest(messages: [system, user], tools: [tool], requireTool: true)
    }

    static func inputSHA256(task: StageDTaskRecord) -> String {
        let request = request(for: task)
        let material = request.messages.map {
            [$0.role.rawValue, $0.content ?? "", $0.toolCallID ?? ""].joined(separator: "\u{0}")
        }.joined(separator: "\u{0}") + "\u{0}" + request.tools.map(\.name).joined(separator: "\u{0}")
        return ProviderDigest.sha256Hex(material)
    }
}

struct StageDCompletionVerifier {
    static func verify(
        record: StageDTaskRecord,
        result: StageDCommandResult,
        command: StageDAuthorizedCommand,
        operationID: UUID,
        attemptID: UUID,
        approvalBindingSHA256: String?,
        requireProvider: Bool,
        now: Date
    ) -> StageDCompletion? {
        let hasUnpairedIntent = record.attempts.contains { intent in
            intent.phase == .intentRecorded && !record.attempts.contains { candidate in
                candidate.attemptID == intent.attemptID && candidate.phase != .intentRecorded
            }
        }
        guard record.phase != .reconciliationRequired,
              record.workspaceIdentitySHA256 == command.workspaceIdentitySHA256,
              result.commandBindingSHA256 == command.bindingSHA256,
              result.verified,
              record.attempts.contains(where: {
                  $0.kind == .command && $0.phase == .succeeded
                      && $0.operationID == operationID && $0.attemptID == attemptID
                      && $0.command == command && $0.result == result
              }),
              !hasUnpairedIntent,
              !record.attempts.contains(where: { $0.phase == .reconciliationRequired }) else {
            return nil
        }

        if requireProvider {
            guard record.attempts.contains(where: {
                $0.kind == .provider && $0.phase == .succeeded && $0.providerDecision != nil
            }) else { return nil }
        }
        if command.risk.requiresApproval {
            guard let approvalBindingSHA256,
                  record.approvals.contains(where: {
                      $0.state == .consumed
                          && $0.request.commandBindingSHA256 == command.bindingSHA256
                          && $0.request.bindingSHA256 == approvalBindingSHA256
                  }) else { return nil }
        } else if approvalBindingSHA256 != nil {
            return nil
        }
        switch record.expectation.kind {
        case .exactFile:
            guard let write = command.write,
                  record.expectation.relativePath == write.relativePath,
                  record.expectation.expectedSHA256 == write.expectedAfterSHA256 else { return nil }
        case .exactClone:
            guard command.risk == .network,
                  record.expectation.cloneTarget == command.cloneTarget,
                  result.cloneRemote == record.expectation.cloneRemote,
                  result.cloneHEAD == record.expectation.cloneHEAD,
                  result.cloneEntryCount != nil,
                  result.cloneByteCount != nil else { return nil }
        case .successfulCommand:
            break
        }
        guard let resultSHA256 = StageDTaskStore.digest(result) else { return nil }
        return .init(
            taskID: record.id,
            sessionID: record.sessionID,
            workspaceIdentitySHA256: record.workspaceIdentitySHA256,
            commandBindingSHA256: command.bindingSHA256,
            approvalBindingSHA256: approvalBindingSHA256,
            operationID: operationID,
            attemptID: attemptID,
            resultSHA256: resultSHA256,
            verificationSHA256: result.verificationSHA256,
            completedAt: now
        )
    }
}

final class StageDCommandAgent: @unchecked Sendable {
    private let provider: AgentInferenceProvider?
    private let executor: StageDCommandExecuting
    private let approvalAuthorizer: StageDApprovalAuthorizing
    private let store: StageDTaskStore
    private let taskID: UUID
    private let policy: StageDCommandPolicy
    private let limits: StageDLimits
    private let requireProvider: Bool
    private let now: @Sendable () -> Date
    private let makeUUID: @Sendable () -> UUID

    init(
        provider: AgentInferenceProvider?,
        executor: StageDCommandExecuting,
        approvalAuthorizer: StageDApprovalAuthorizing,
        store: StageDTaskStore,
        task: StageDTaskRecord,
        policy: StageDCommandPolicy,
        limits: StageDLimits = .production,
        requireProvider: Bool,
        now: @escaping @Sendable () -> Date = Date.init,
        makeUUID: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.provider = provider
        self.executor = executor
        self.approvalAuthorizer = approvalAuthorizer
        self.store = store
        taskID = task.id
        self.policy = policy
        self.limits = limits
        self.requireProvider = requireProvider
        self.now = now
        self.makeUUID = makeUUID
    }

    func runModelCommand() async -> StageDLoopOutcome {
        do {
            let record = try await store.snapshot(taskID: taskID)
            if let completion = record.completion { return .completed(completion) }
            if let recovered = try await recover(record) { return recovered }
            guard let provider else { return .failed(.providerFailure) }
            let operationID = makeUUID(), attemptID = makeUUID()
            let inputSHA256 = StageDProviderContract.inputSHA256(task: record)
            let intent = StageDAttemptEvidence(
                taskID: record.id,
                operationID: operationID,
                attemptID: attemptID,
                kind: .provider,
                phase: .intentRecorded,
                inputSHA256: inputSHA256,
                recordedAt: now(),
                command: nil,
                approvalBindingSHA256: nil,
                providerDecision: nil,
                result: nil,
                resultSHA256: nil
            )
            _ = try await store.appendAttempt(taskID: taskID, evidence: intent, phase: .ready)
            let outcome = await provider.infer(request: StageDProviderContract.request(for: record), requestID: makeUUID())
            switch outcome {
            case let .decision(.toolCalls(assistant, calls)):
                guard calls.count == 1,
                      let call = calls.first,
                      call.name == StageDProviderContract.toolName,
                      !call.id.isEmpty,
                      call.id.utf8.count <= ProviderLimits.maximumToolCallIDBytes,
                      call.arguments.utf8.count <= ProviderLimits.maximumToolArgumentsBytes,
                      let arguments = try? JSONDecoder().decode(
                        StageDProviderArguments.self,
                        from: Data(call.arguments.utf8)
                      ),
                      let assistantHash = StageDTaskStore.digest(assistant) else {
                    _ = try await recordProviderTerminal(
                        intent: intent, phase: .failed, decision: nil, resultSHA256: nil
                    )
                    return .rejected(.providerPolicy)
                }
                let decision = StageDProviderDecision(
                    toolCallID: call.id,
                    command: arguments.command,
                    cwd: arguments.cwd,
                    assistantSHA256: assistantHash
                )
                guard let decisionSHA256 = StageDTaskStore.digest(decision) else {
                    throw StageDCommandError.evidenceFailure
                }
                _ = try await recordProviderTerminal(
                    intent: intent,
                    phase: .succeeded,
                    decision: decision,
                    resultSHA256: decisionSHA256
                )
                return await run(command: decision.command, cwd: decision.cwd)
            case .decision(.finish):
                _ = try await recordProviderTerminal(intent: intent, phase: .failed, decision: nil, resultSHA256: nil)
                return .rejected(.providerPolicy)
            case .failure:
                _ = try await recordProviderTerminal(intent: intent, phase: .failed, decision: nil, resultSHA256: nil)
                return .failed(.providerFailure)
            case .unknown:
                _ = try await recordProviderTerminal(
                    intent: intent, phase: .reconciliationRequired, decision: nil, resultSHA256: nil
                )
                return .reconciliationRequired
            }
        } catch {
            return .failed(.evidenceFailure)
        }
    }

    func run(command: String, cwd: String) async -> StageDLoopOutcome {
        do {
            var record = try await store.snapshot(taskID: taskID)
            if let completion = record.completion { return .completed(completion) }
            if hasUnresolvedAttempt(record) {
                _ = try await store.setPhase(taskID: taskID, phase: .reconciliationRequired)
                return .reconciliationRequired
            }
            let authorized: StageDAuthorizedCommand
            switch policy.decide(command: command, cwd: cwd) {
            case let .authorized(value): authorized = value
            case .unavailable: return .rejected(.unavailableTool)
            case let .rejected(_, error): return .rejected(error)
            }
            let operationID = makeUUID(), attemptID = makeUUID()
            var approvalBinding: String?
            var approvalRequest: StageDApprovalRequest?
            var approvalGrant: StageDApprovalGrant?
            if authorized.risk.requiresApproval {
                let request = makeApproval(
                    record: record,
                    command: authorized,
                    operationID: operationID,
                    attemptID: attemptID
                )
                approvalRequest = request
                _ = try await store.appendApproval(
                    taskID: taskID,
                    evidence: .init(request: request, state: .pending, recordedAt: now(), grant: nil),
                    phase: .awaitingApproval
                )
                switch await approvalAuthorizer.requestApproval(request) {
                case let .approved(grant):
                    let durableGrant = StageDApprovalGrant(
                        requestID: grant.requestID,
                        requestBindingSHA256: grant.requestBindingSHA256,
                        nonce: grant.nonce,
                        approvedAt: StageDTaskStore.durableDate(grant.approvedAt)
                    )
                    guard durableGrant.requestID == request.requestID,
                          durableGrant.requestBindingSHA256 == request.bindingSHA256,
                          durableGrant.nonce == request.nonce,
                          durableGrant.approvedAt <= request.expiresAt else {
                        return .rejected(.approvalTampered)
                    }
                    approvalGrant = durableGrant
                    approvalBinding = request.bindingSHA256
                    _ = try await store.appendApproval(
                        taskID: taskID,
                        evidence: .init(
                            request: request,
                            state: .approved,
                            recordedAt: now(),
                            grant: durableGrant
                        ),
                        phase: .awaitingApproval
                    )
                case .rejected:
                    _ = try await terminalApproval(request, state: .rejected)
                    return .rejected(.approvalRejected)
                case .cancelled:
                    _ = try await terminalApproval(request, state: .cancelled)
                    return .rejected(.approvalCancelled)
                case .expired:
                    _ = try await terminalApproval(request, state: .expired)
                    return .rejected(.approvalExpired)
                }
            }

            guard let gateToken = await StageDWorkspaceGate.shared.acquire(record.workspaceIdentitySHA256) else {
                return .failed(.workspaceBusy)
            }
            defer {
                Task { await StageDWorkspaceGate.shared.release(record.workspaceIdentitySHA256, token: gateToken) }
            }
            let intent = StageDAttemptEvidence(
                taskID: taskID,
                operationID: operationID,
                attemptID: attemptID,
                kind: .command,
                phase: .intentRecorded,
                inputSHA256: authorized.bindingSHA256,
                recordedAt: now(),
                command: authorized,
                approvalBindingSHA256: approvalBinding,
                providerDecision: nil,
                result: nil,
                resultSHA256: nil
            )
            if let request = approvalRequest, let grant = approvalGrant {
                record = try await store.consumeApprovalAndRecordIntent(
                    taskID: taskID,
                    request: request,
                    grant: grant,
                    intent: intent,
                    now: now()
                )
            } else {
                record = try await store.appendAttempt(taskID: taskID, evidence: intent, phase: .executing)
            }
            let outcome = await executor.execute(authorized)
            switch outcome {
            case let .succeeded(result):
                guard let resultSHA = StageDTaskStore.digest(result) else {
                    throw StageDCommandError.evidenceFailure
                }
                let terminal = terminalAttempt(
                    intent: intent, phase: .succeeded, result: result, resultSHA256: resultSHA
                )
                record = try await store.appendAttempt(taskID: taskID, evidence: terminal, phase: .verifying)
                guard let completion = StageDCompletionVerifier.verify(
                    record: record,
                    result: result,
                    command: authorized,
                    operationID: operationID,
                    attemptID: attemptID,
                    approvalBindingSHA256: approvalBinding,
                    requireProvider: requireProvider,
                    now: now()
                ) else {
                    _ = try await store.setPhase(taskID: taskID, phase: .failed)
                    return .failed(.completionRejected)
                }
                let completed = try await store.complete(taskID: taskID, completion: completion)
                guard let durableCompletion = completed.completion else {
                    throw StageDCommandError.evidenceFailure
                }
                return .completed(durableCompletion)
            case let .failed(result):
                let resultSHA = result.flatMap { StageDTaskStore.digest($0) }
                let terminal = terminalAttempt(
                    intent: intent, phase: .failed, result: result, resultSHA256: resultSHA
                )
                _ = try await store.appendAttempt(taskID: taskID, evidence: terminal, phase: .failed)
                return .failed(.executorFailure)
            case let .unknown(result):
                let resultSHA = result.flatMap { StageDTaskStore.digest($0) }
                let terminal = terminalAttempt(
                    intent: intent,
                    phase: .reconciliationRequired,
                    result: result,
                    resultSHA256: resultSHA
                )
                _ = try await store.appendAttempt(
                    taskID: taskID, evidence: terminal, phase: .reconciliationRequired
                )
                return .reconciliationRequired
            }
        } catch {
            return .failed(.evidenceFailure)
        }
    }

    private func recover(_ record: StageDTaskRecord) async throws -> StageDLoopOutcome? {
        if hasUnresolvedAttempt(record) {
            _ = try await store.setPhase(taskID: taskID, phase: .reconciliationRequired)
            return .reconciliationRequired
        }
        let commandPairs = paired(record.attempts.filter { $0.kind == .command })
        if let pair = commandPairs.last,
           pair.count == 2,
           pair[1].phase == .succeeded,
           let command = pair[1].command,
           let result = pair[1].result {
            let completion = StageDCompletionVerifier.verify(
                record: record,
                result: result,
                command: command,
                operationID: pair[1].operationID,
                attemptID: pair[1].attemptID,
                approvalBindingSHA256: pair[1].approvalBindingSHA256,
                requireProvider: requireProvider,
                now: now()
            )
            if let completion {
                let completed = try await store.complete(taskID: taskID, completion: completion)
                guard let durableCompletion = completed.completion else {
                    throw StageDCommandError.evidenceFailure
                }
                return .completed(durableCompletion)
            }
        }
        let providerPairs = paired(record.attempts.filter { $0.kind == .provider })
        if let pair = providerPairs.last,
           pair.count == 2,
           pair[1].phase == .succeeded,
           let decision = pair[1].providerDecision,
           commandPairs.isEmpty {
            return await run(command: decision.command, cwd: decision.cwd)
        }
        if record.phase == .failed || record.phase == .rejected {
            return .failed(.completionRejected)
        }
        return nil
    }

    private func hasUnresolvedAttempt(_ record: StageDTaskRecord) -> Bool {
        paired(record.attempts).contains {
            $0.count == 1 || $0.last?.phase == .reconciliationRequired
        }
    }

    private func paired(_ attempts: [StageDAttemptEvidence]) -> [[StageDAttemptEvidence]] {
        var order: [UUID] = []
        var values: [UUID: [StageDAttemptEvidence]] = [:]
        for attempt in attempts {
            if values[attempt.attemptID] == nil { order.append(attempt.attemptID) }
            values[attempt.attemptID, default: []].append(attempt)
        }
        return order.compactMap { values[$0] }
    }

    private func makeApproval(
        record: StageDTaskRecord,
        command: StageDAuthorizedCommand,
        operationID: UUID,
        attemptID: UUID
    ) -> StageDApprovalRequest {
        let created = StageDTaskStore.durableDate(now())
        return .init(
            requestID: makeUUID(),
            taskID: record.id,
            operationID: operationID,
            attemptID: attemptID,
            workspaceIdentitySHA256: record.workspaceIdentitySHA256,
            commandBindingSHA256: command.bindingSHA256,
            command: command.parsed.original,
            argumentsSHA256: ProviderDigest.sha256Hex(command.parsed.arguments.joined(separator: "\u{0}")),
            cwd: command.parsed.cwd,
            risk: command.risk,
            executionRoot: command.executionRoot,
            nonce: makeUUID(),
            createdAt: created,
            expiresAt: StageDTaskStore.durableDate(
                created.addingTimeInterval(limits.maximumApprovalSeconds)
            )
        )
    }

    private func terminalApproval(
        _ request: StageDApprovalRequest,
        state: StageDApprovalState
    ) async throws -> StageDTaskRecord {
        try await store.appendApproval(
            taskID: taskID,
            evidence: .init(request: request, state: state, recordedAt: now(), grant: nil),
            phase: .rejected
        )
    }

    private func recordProviderTerminal(
        intent: StageDAttemptEvidence,
        phase: StageDAttemptPhase,
        decision: StageDProviderDecision?,
        resultSHA256: String?
    ) async throws -> StageDTaskRecord {
        try await store.appendAttempt(
            taskID: taskID,
            evidence: .init(
                taskID: intent.taskID,
                operationID: intent.operationID,
                attemptID: intent.attemptID,
                kind: .provider,
                phase: phase,
                inputSHA256: intent.inputSHA256,
                recordedAt: now(),
                command: nil,
                approvalBindingSHA256: nil,
                providerDecision: decision,
                result: nil,
                resultSHA256: resultSHA256
            ),
            phase: phase == .reconciliationRequired ? .reconciliationRequired : .ready
        )
    }

    private func terminalAttempt(
        intent: StageDAttemptEvidence,
        phase: StageDAttemptPhase,
        result: StageDCommandResult?,
        resultSHA256: String?
    ) -> StageDAttemptEvidence {
        .init(
            taskID: intent.taskID,
            operationID: intent.operationID,
            attemptID: intent.attemptID,
            kind: intent.kind,
            phase: phase,
            inputSHA256: intent.inputSHA256,
            recordedAt: now(),
            command: intent.command,
            approvalBindingSHA256: intent.approvalBindingSHA256,
            providerDecision: nil,
            result: result,
            resultSHA256: resultSHA256
        )
    }
}
