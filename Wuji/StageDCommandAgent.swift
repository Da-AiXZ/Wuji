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

    static func inputSHA256(task: StageDTaskRecord, providerID: String) -> String {
        let request = request(for: task)
        let messageSHA256 = StageDTaskStore.digest(request.messages) ?? ""
        let toolSHA256 = StageDTaskStore.digest(request.tools) ?? ""
        let expectationSHA256 = StageDTaskStore.digest(task.expectation) ?? ""
        let writeSHA256 = task.write.flatMap { StageDTaskStore.digest($0) } ?? ""
        let material = [
            "stage_d_provider_position_0",
            providerID,
            task.id.uuidString.lowercased(),
            task.sessionID.uuidString.lowercased(),
            task.importID.uuidString.lowercased(),
            task.workspaceID.uuidString.lowercased(),
            task.workspaceIdentitySHA256,
            task.workspaceRootSHA256,
            task.goalBindingSHA256,
            task.ruleSetBindingSHA256,
            task.cloneRootSHA256,
            expectationSHA256,
            writeSHA256,
            messageSHA256,
            toolSHA256,
            request.requireTool ? "require_tool" : "allow_finish",
        ].joined(separator: "\u{0}")
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
        providerDecisionSHA256: String?,
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
            guard let providerDecisionSHA256,
                  record.attempts.contains(where: {
                      $0.kind == .provider
                          && $0.phase == .succeeded
                          && $0.providerDecision.map {
                              StageDTaskStore.digest($0) == providerDecisionSHA256
                                  && (try? StageDCommandParser.parse(
                                      command: $0.command,
                                      cwd: $0.cwd
                                  )) == command.parsed
                          } == true
                          && $0.resultSHA256 == providerDecisionSHA256
                  }),
                  record.attempts.contains(where: {
                      $0.kind == .command
                          && $0.attemptID == attemptID
                          && $0.providerDecisionSHA256 == providerDecisionSHA256
                  }) else { return nil }
        } else if providerDecisionSHA256 != nil {
            return nil
        }
        if command.risk.requiresApproval {
            guard let approvalBindingSHA256,
                  record.approvals.contains(where: {
                      $0.state == .consumed
                          && $0.request.taskID == record.id
                          && $0.request.operationID == operationID
                          && $0.request.attemptID == attemptID
                          && $0.request.workspaceIdentitySHA256 == record.workspaceIdentitySHA256
                          && $0.request.commandBindingSHA256 == command.bindingSHA256
                          && $0.request.command == command.parsed.original
                          && $0.request.argumentsSHA256 == ProviderDigest.sha256Hex(
                              command.parsed.arguments.joined(separator: "\u{0}")
                          )
                          && $0.request.cwd == command.parsed.cwd
                          && $0.request.risk == command.risk
                          && $0.request.executionRoot == command.executionRoot
                          && $0.request.bindingSHA256 == approvalBindingSHA256
                          && $0.request.providerDecisionSHA256 == providerDecisionSHA256
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
            providerDecisionSHA256: providerDecisionSHA256,
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
            if let recovered = try await recover(record, requestedCommand: nil) { return recovered }
            guard let provider else { return .failed(.providerFailure) }
            let operationID = makeUUID(), attemptID = makeUUID()
            let inputSHA256 = StageDProviderContract.inputSHA256(
                task: record,
                providerID: provider.providerID
            )
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
                providerDecisionSHA256: nil,
                providerDecision: nil,
                result: nil,
                resultSHA256: nil
            )
            do {
                _ = try await store.appendAttempt(taskID: taskID, evidence: intent, phase: .ready)
            } catch {
                return .failed(.intentStoreFailure)
            }
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
                    assistantSHA256: assistantHash,
                    expectedInputSHA256: inputSHA256
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
                return await runAuthorizedProviderDecision(
                    decision,
                    decisionSHA256: decisionSHA256
                )
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
        } catch StageDCommandError.durableTerminalFailure {
            return .failed(.durableTerminalFailure)
        } catch {
            return .failed(.evidenceFailure)
        }
    }

    func run(command: String, cwd: String) async -> StageDLoopOutcome {
        guard !requireProvider else { return .failed(.providerBindingMismatch) }
        return await run(command: command, cwd: cwd, providerDecisionSHA256: nil)
    }

    private func runAuthorizedProviderDecision(
        _ decision: StageDProviderDecision,
        decisionSHA256: String
    ) async -> StageDLoopOutcome {
        await run(
            command: decision.command,
            cwd: decision.cwd,
            providerDecisionSHA256: decisionSHA256
        )
    }

    private func run(
        command: String,
        cwd: String,
        providerDecisionSHA256: String?
    ) async -> StageDLoopOutcome {
        do {
            var record = try await store.snapshot(taskID: taskID)
            if let completion = record.completion { return .completed(completion) }
            if let recovered = try await recover(
                record,
                requestedCommand: (command, cwd, providerDecisionSHA256)
            ) { return recovered }
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
                    attemptID: attemptID,
                    providerDecisionSHA256: providerDecisionSHA256
                )
                approvalRequest = request
                do {
                    _ = try await store.appendApproval(
                        taskID: taskID,
                        evidence: .init(
                            request: request,
                            state: .pending,
                            recordedAt: now(),
                            grant: nil
                        ),
                        phase: .awaitingApproval
                    )
                } catch {
                    throw StageDCommandError.intentStoreFailure
                }
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
                    do {
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
                    } catch {
                        throw StageDCommandError.intentStoreFailure
                    }
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

            let workspaceIdentitySHA256 = record.workspaceIdentitySHA256
            let executionRecord = record
            guard let gatedOutcome = try await StageDWorkspaceGate.shared.withLease(
                workspaceIdentitySHA256,
                operation: { [self] in
                    try await executeAuthorized(
                        record: executionRecord,
                        authorized: authorized,
                        operationID: operationID,
                        attemptID: attemptID,
                        approvalBinding: approvalBinding,
                        providerDecisionSHA256: providerDecisionSHA256,
                        approvalRequest: approvalRequest,
                        approvalGrant: approvalGrant
                    )
                }
            ) else {
                return .failed(.workspaceBusy)
            }
            return gatedOutcome
        } catch StageDCommandError.intentStoreFailure {
            return .failed(.intentStoreFailure)
        } catch StageDCommandError.durableCompletionFailure {
            return .failed(.durableCompletionFailure)
        } catch StageDCommandError.durableTerminalFailure {
            return .failed(.durableTerminalFailure)
        } catch {
            return .failed(.evidenceFailure)
        }
    }

    private func executeAuthorized(
        record initialRecord: StageDTaskRecord,
        authorized: StageDAuthorizedCommand,
        operationID: UUID,
        attemptID: UUID,
        approvalBinding: String?,
        providerDecisionSHA256: String?,
        approvalRequest: StageDApprovalRequest?,
        approvalGrant: StageDApprovalGrant?
    ) async throws -> StageDLoopOutcome {
        var record = initialRecord
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
            providerDecisionSHA256: providerDecisionSHA256,
            providerDecision: nil,
            result: nil,
            resultSHA256: nil
        )
        if let request = approvalRequest, let grant = approvalGrant {
            do {
                record = try await store.consumeApprovalAndRecordIntent(
                    taskID: taskID,
                    request: request,
                    grant: grant,
                    intent: intent,
                    now: now()
                )
            } catch {
                throw StageDCommandError.intentStoreFailure
            }
        } else {
            do {
                record = try await store.appendAttempt(
                    taskID: taskID,
                    evidence: intent,
                    phase: .executing
                )
            } catch {
                throw StageDCommandError.intentStoreFailure
            }
        }
        let outcome = await executor.execute(authorized, policy: policy)
        switch outcome {
        case let .succeeded(result):
            guard let resultSHA = StageDTaskStore.digest(result) else {
                throw StageDCommandError.evidenceFailure
            }
            let terminal = terminalAttempt(
                intent: intent, phase: .succeeded, result: result, resultSHA256: resultSHA
            )
            do {
                record = try await store.appendAttempt(
                    taskID: taskID,
                    evidence: terminal,
                    phase: .verifying
                )
            } catch {
                throw StageDCommandError.durableTerminalFailure
            }
            guard let completion = StageDCompletionVerifier.verify(
                record: record,
                result: result,
                command: authorized,
                operationID: operationID,
                attemptID: attemptID,
                approvalBindingSHA256: approvalBinding,
                providerDecisionSHA256: providerDecisionSHA256,
                requireProvider: requireProvider,
                now: now()
            ) else {
                _ = try await store.setPhase(taskID: taskID, phase: .failed)
                return .failed(.completionRejected)
            }
            let completed: StageDTaskRecord
            do {
                completed = try await store.complete(taskID: taskID, completion: completion)
            } catch {
                throw StageDCommandError.durableCompletionFailure
            }
            guard let durableCompletion = completed.completion else {
                throw StageDCommandError.evidenceFailure
            }
            return .completed(durableCompletion)
        case let .failed(result):
            let resultSHA = result.flatMap { StageDTaskStore.digest($0) }
            let terminal = terminalAttempt(
                intent: intent, phase: .failed, result: result, resultSHA256: resultSHA
            )
            do {
                _ = try await store.appendAttempt(taskID: taskID, evidence: terminal, phase: .failed)
            } catch {
                throw StageDCommandError.durableTerminalFailure
            }
            return .failed(commandError(for: result))
        case let .unknown(result):
            let resultSHA = result.flatMap { StageDTaskStore.digest($0) }
            let terminal = terminalAttempt(
                intent: intent,
                phase: .reconciliationRequired,
                result: result,
                resultSHA256: resultSHA
            )
            do {
                _ = try await store.appendAttempt(
                    taskID: taskID, evidence: terminal, phase: .reconciliationRequired
                )
            } catch {
                throw StageDCommandError.durableTerminalFailure
            }
            return .reconciliationRequired
        }
    }

    private func recover(
        _ record: StageDTaskRecord,
        requestedCommand: (command: String, cwd: String, providerDecisionSHA256: String?)?
    ) async throws -> StageDLoopOutcome? {
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
            guard ISHStageDCommandExecutor.revalidates(command, using: policy) else {
                return .failed(.authorizationRejected)
            }
            if let requestedCommand {
                guard case let .authorized(requested) = policy.decide(
                    command: requestedCommand.command,
                    cwd: requestedCommand.cwd
                ), requested == command,
                requestedCommand.providerDecisionSHA256 == pair[1].providerDecisionSHA256 else {
                    return .failed(.completionRejected)
                }
            }
            if requireProvider {
                guard let binding = pair[1].providerDecisionSHA256,
                      validatedProviderDecision(in: record)?.digest == binding else {
                    return .failed(.providerBindingMismatch)
                }
            } else if pair[1].providerDecisionSHA256 != nil {
                return .failed(.providerBindingMismatch)
            }
            let completion = StageDCompletionVerifier.verify(
                record: record,
                result: result,
                command: command,
                operationID: pair[1].operationID,
                attemptID: pair[1].attemptID,
                approvalBindingSHA256: pair[1].approvalBindingSHA256,
                providerDecisionSHA256: pair[1].providerDecisionSHA256,
                requireProvider: requireProvider,
                now: now()
            )
            if let completion {
                let completed: StageDTaskRecord
                do {
                    completed = try await store.complete(taskID: taskID, completion: completion)
                } catch {
                    throw StageDCommandError.durableCompletionFailure
                }
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
            guard let validated = validatedProviderDecision(in: record),
                  validated.decision == decision else {
                return .failed(.providerBindingMismatch)
            }
            if let requestedCommand {
                guard requestedCommand.command == decision.command,
                      requestedCommand.cwd == decision.cwd,
                      requestedCommand.providerDecisionSHA256 == validated.digest else {
                    return .failed(.providerBindingMismatch)
                }
                return nil
            }
            return await runAuthorizedProviderDecision(
                decision,
                decisionSHA256: validated.digest
            )
        }
        if record.phase == .failed || record.phase == .rejected {
            return .failed(.completionRejected)
        }
        return nil
    }

    private func validatedProviderDecision(
        in record: StageDTaskRecord
    ) -> (decision: StageDProviderDecision, digest: String)? {
        guard let provider else { return nil }
        let pairs = paired(record.attempts.filter { $0.kind == .provider })
        guard pairs.count == 1,
              let pair = pairs.first,
              pair.count == 2,
              pair[0].phase == .intentRecorded,
              pair[1].phase == .succeeded,
              let decision = pair[1].providerDecision,
              let digest = StageDTaskStore.digest(decision),
              pair[1].resultSHA256 == digest else { return nil }
        let expected = StageDProviderContract.inputSHA256(
            task: record,
            providerID: provider.providerID
        )
        guard pair[0].inputSHA256 == expected,
              pair[1].inputSHA256 == expected,
              decision.expectedInputSHA256 == expected else { return nil }
        return (decision, digest)
    }

    private func commandError(for result: StageDCommandResult?) -> StageDCommandError {
        switch result?.failureCategory {
        case .authorizationRejected: return .authorizationRejected
        case .intentStoreFailure: return .intentStoreFailure
        case .resolverNetworkFailure: return .resolverNetworkFailure
        case .cloneProcessNonzero: return .cloneProcessNonzero
        case .cloneTimeoutUnknown: return .cloneTimeoutUnknown
        case .checkoutTargetUnavailable: return .checkoutTargetUnavailable
        case .remoteMismatch: return .remoteMismatch
        case .headMismatch: return .headMismatch
        case .treeOverflow: return .treeOverflow
        case .treeEscape: return .treeEscape
        case .eofTruncationProcessTreeFailure, .adapterFixedError:
            return .terminalBarrierFailure
        case .durableTerminalFailure: return .durableTerminalFailure
        case .durableCompletionFailure: return .durableCompletionFailure
        case nil: return .executorFailure
        }
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
        attemptID: UUID,
        providerDecisionSHA256: String?
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
            providerDecisionSHA256: providerDecisionSHA256,
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
        do {
            return try await store.appendAttempt(
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
                    providerDecisionSHA256: nil,
                    providerDecision: decision,
                    result: nil,
                    resultSHA256: resultSHA256
                ),
                phase: phase == .reconciliationRequired ? .reconciliationRequired : .ready
            )
        } catch {
            throw StageDCommandError.durableTerminalFailure
        }
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
            providerDecisionSHA256: intent.providerDecisionSHA256,
            providerDecision: nil,
            result: result,
            resultSHA256: resultSHA256
        )
    }
}
