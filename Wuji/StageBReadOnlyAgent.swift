import Foundation

struct StageBPreparedSession: Sendable {
    let session: StageBSessionRecord
    let workspace: StageBReadyWorkspace
    let ruleSet: StageBRuleSet
}

struct StageBSessionCoordinator: Sendable {
    private let stageAStore: StageAWorkspaceStore
    private let sessionStore: StageBSessionStore
    private let limits: StageBLimits
    private let now: @Sendable () -> Date
    private let makeUUID: @Sendable () -> UUID

    init(
        stageAStore: StageAWorkspaceStore,
        sessionStore: StageBSessionStore,
        limits: StageBLimits = .production,
        now: @escaping @Sendable () -> Date = { Date() },
        makeUUID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.stageAStore = stageAStore
        self.sessionStore = sessionStore
        self.limits = limits
        self.now = now
        self.makeUUID = makeUUID
    }

    func create(importID: UUID, goal: StageBGoal) async throws -> StageBPreparedSession {
        let workspace = try StageBWorkspaceResolver(store: stageAStore)
            .openReadyWorkspace(importID: importID, now: now())
        var session = try await sessionStore.create(
            workspace: workspace,
            goal: goal,
            sessionID: makeUUID(),
            now: now()
        )
        let operationID = makeUUID()
        let attemptID = makeUUID()
        let inputHash = ProviderDigest.sha256Hex(
            "rules\u{0}\(workspace.identitySHA256)\u{0}\(workspace.markerSHA256)"
        )
        try await sessionStore.record(attempt(
            sessionID: session.id,
            operationID: operationID,
            attemptID: attemptID,
            kind: .ruleDiscovery,
            inputSHA256: inputHash,
            phase: .intentRecorded,
            category: .none
        ))
        do {
            let rules = try StageBRuleDiscovery(limits: limits).discover(in: workspace)
            try await sessionStore.record(attempt(
                sessionID: session.id,
                operationID: operationID,
                attemptID: attemptID,
                kind: .ruleDiscovery,
                inputSHA256: inputHash,
                phase: .succeeded,
                category: .rulesBound,
                result: Data(rules.bindingSHA256.utf8)
            ))
            session = try await sessionStore.bindRules(session: session, ruleSet: rules, now: now())
            return StageBPreparedSession(session: session, workspace: workspace, ruleSet: rules)
        } catch {
            try? await sessionStore.record(attempt(
                sessionID: session.id,
                operationID: operationID,
                attemptID: attemptID,
                kind: .ruleDiscovery,
                inputSHA256: inputHash,
                phase: .failed,
                category: .recoveryBlocked
            ))
            _ = try? await sessionStore.transition(
                session,
                to: .failed,
                diagnostic: "rule_discovery_failed",
                now: now()
            )
            throw error
        }
    }

    func restore(sessionID: UUID) async throws -> StageBPreparedSession {
        let snapshot = try await sessionStore.snapshot(sessionID: sessionID)
        let session = snapshot.session
        let operationID = makeUUID()
        let attemptID = makeUUID()
        let inputHash = ProviderDigest.sha256Hex(
            "recovery\u{0}\(session.workspaceIdentitySHA256)\u{0}\(session.goal.bindingSHA256)"
        )
        try await sessionStore.record(attempt(
            sessionID: session.id,
            operationID: operationID,
            attemptID: attemptID,
            kind: .recovery,
            inputSHA256: inputHash,
            phase: .intentRecorded,
            category: .none
        ))
        do {
            let workspace = try StageBWorkspaceResolver(store: stageAStore)
                .openReadyWorkspace(importID: session.importID, now: now())
            guard workspace.workspaceID == session.workspaceID,
                  workspace.identitySHA256 == session.workspaceIdentitySHA256,
                  workspace.markerSHA256 == session.markerSHA256 else {
                throw StageBError.workspaceBindingMismatch
            }
            let rules = try StageBRuleDiscovery(limits: limits).discover(in: workspace)
            guard rules.bindingSHA256 == session.ruleSetBindingSHA256,
                  rules.descriptors == session.rules else {
                throw StageBError.ruleBindingMismatch
            }
            try await sessionStore.record(attempt(
                sessionID: session.id,
                operationID: operationID,
                attemptID: attemptID,
                kind: .recovery,
                inputSHA256: inputHash,
                phase: .succeeded,
                category: .rulesBound,
                result: Data(rules.bindingSHA256.utf8)
            ))
            return StageBPreparedSession(session: session, workspace: workspace, ruleSet: rules)
        } catch {
            try? await sessionStore.record(attempt(
                sessionID: session.id,
                operationID: operationID,
                attemptID: attemptID,
                kind: .recovery,
                inputSHA256: inputHash,
                phase: .reconciliationRequired,
                category: .recoveryBlocked
            ))
            _ = try? await sessionStore.transition(
                session,
                to: .reconciliationRequired,
                diagnostic: "recovery_binding_failed",
                now: now()
            )
            throw error
        }
    }

    private func attempt(
        sessionID: UUID,
        operationID: UUID,
        attemptID: UUID,
        kind: StageBAttemptKind,
        inputSHA256: String,
        phase: StageBAttemptPhase,
        category: StageBAttemptCategory,
        result: Data? = nil
    ) -> StageBAttemptEvidence {
        StageBAttemptEvidence(
            sessionID: sessionID,
            operationID: operationID,
            attemptID: attemptID,
            kind: kind,
            toolName: nil,
            toolCallIDHash: nil,
            inputSHA256: inputSHA256,
            recordedAt: now(),
            phase: phase,
            category: category,
            resultByteCount: result?.count,
            resultSHA256: result.map(ProviderDigest.sha256Hex),
            observation: nil
        )
    }
}

final class StageBReadOnlyAgent: @unchecked Sendable {
    private struct PendingToolAttempt: Sendable {
        let call: ProviderTurnToolCall
        let operationID: UUID
        let attemptID: UUID
        let inputSHA256: String
    }

    private let provider: AgentInferenceProvider
    private let executor: StageBReadOnlyExecuting
    private let policy: StageBReadOnlyPolicy
    private let sessionStore: StageBSessionStore
    private let workspace: StageBReadyWorkspace
    private let ruleSet: StageBRuleSet
    private let limits: StageBLimits
    private let now: @Sendable () -> Date
    private let makeUUID: @Sendable () -> UUID

    init(
        provider: AgentInferenceProvider,
        executor: StageBReadOnlyExecuting,
        policy: StageBReadOnlyPolicy,
        sessionStore: StageBSessionStore,
        workspace: StageBReadyWorkspace,
        ruleSet: StageBRuleSet,
        limits: StageBLimits = .production,
        now: @escaping @Sendable () -> Date = { Date() },
        makeUUID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.provider = provider
        self.executor = executor
        self.policy = policy
        self.sessionStore = sessionStore
        self.workspace = workspace
        self.ruleSet = ruleSet
        self.limits = limits
        self.now = now
        self.makeUUID = makeUUID
    }

    func run(sessionID: UUID) async -> StageBLoopOutcome {
        let initial: StageBDurableSnapshot
        do { initial = try await sessionStore.snapshot(sessionID: sessionID) }
        catch { return .failure(.evidenceUnavailable) }
        var session = initial.session
        guard session.id == sessionID,
              session.workspaceID == workspace.workspaceID,
              session.workspaceIdentitySHA256 == workspace.identitySHA256,
              session.markerSHA256 == workspace.markerSHA256,
              session.ruleSetBindingSHA256 == ruleSet.bindingSHA256,
              session.rules == ruleSet.descriptors else {
            return .failure(.workspaceBindingMismatch)
        }
        if hasUnresolvedExternalAttempt(initial.attempts) {
            _ = try? await sessionStore.transition(
                session,
                to: .reconciliationRequired,
                diagnostic: "external_attempt_requires_reconciliation",
                now: now()
            )
            return .reconciliationRequired
        }
        if session.phase == .completed, let completion = session.completion {
            guard durableCompletionIsValid(
                completion,
                session: session,
                attempts: initial.attempts
            ) else { return .reconciliationRequired }
            return .completed(completion)
        }
        if initial.attempts.contains(where: { $0.kind == .provider || $0.kind == .executor }) {
            _ = try? await sessionStore.transition(
                session,
                to: .reconciliationRequired,
                diagnostic: "external_attempt_requires_reconciliation",
                now: now()
            )
            return .reconciliationRequired
        }
        do {
            session = try await sessionStore.transition(session, to: .running, now: now())
        } catch {
            return .failure(.evidenceUnavailable)
        }

        let contextWindow = StageBContextWindow(limits: limits)
        let baseMessages: [ProviderTurnMessage]
        do { baseMessages = try contextWindow.baseMessages(session: session, ruleSet: ruleSet) }
        catch { return await fail(session, .contextLimit) }

        var observations: [StageBToolObservation] = []
        var lastExchange: [ProviderTurnMessage] = []
        var usedToolCallIDs = Set<String>()
        var providerRequestCount = 0
        var toolExecutionCount = 0
        var unresolvedPolicyRejection = false

        for _ in 0..<limits.maximumProviderTurns {
            let verified = StageBCompletionVerifier.verify(
                observations: observations,
                session: session,
                ruleSet: ruleSet
            )
            let request: ProviderInferenceRequest
            do {
                request = try contextWindow.request(
                    baseMessages: baseMessages,
                    observations: observations,
                    lastExchange: lastExchange,
                    requireTool: verified == nil
                )
            } catch {
                return await fail(session, .contextLimit)
            }
            let providerOperationID = makeUUID()
            let providerAttemptID = makeUUID()
            let inputHash = inferenceInputHash(request)
            guard await record(intent(
                sessionID: session.id,
                operationID: providerOperationID,
                attemptID: providerAttemptID,
                kind: .provider,
                inputSHA256: inputHash
            )) else { return await fail(session, .evidenceUnavailable) }

            providerRequestCount += 1
            let outcome = await provider.infer(request: request, requestID: makeUUID())
            switch outcome {
            case let .decision(decision):
                let providerCategory: StageBAttemptCategory
                switch decision {
                case .toolCalls: providerCategory = .providerToolCalls
                case .finish: providerCategory = .providerFinish
                }
                guard await record(terminal(
                    sessionID: session.id,
                    operationID: providerOperationID,
                    attemptID: providerAttemptID,
                    kind: .provider,
                    inputSHA256: inputHash,
                    phase: .succeeded,
                    category: providerCategory,
                    result: Data(decision.description.utf8)
                )) else { return .reconciliationRequired }

                switch decision {
                case let .finish(assistant):
                    if let verified, !unresolvedPolicyRejection {
                        return await establishCompletion(
                            session: session,
                            verified: verified,
                            observations: observations,
                            providerRequestCount: providerRequestCount,
                            toolExecutionCount: toolExecutionCount
                        )
                    }
                    lastExchange = [
                        assistant,
                        ProviderTurnMessage(
                            role: .user,
                            content: "Completion rejected by the Swift Harness because the bound list, exact search, read, rule, or reconciliation evidence is incomplete. Continue with allowed typed tools."
                        )
                    ]

                case let .toolCalls(assistant, calls):
                    let pending = calls.map { call in
                        PendingToolAttempt(
                            call: call,
                            operationID: makeUUID(),
                            attemptID: makeUUID(),
                            inputSHA256: ProviderDigest.sha256Hex(
                                "tool-request\u{0}\(call.name)\u{0}\(ProviderDigest.sha256Hex(call.arguments))"
                            )
                        )
                    }
                    for request in pending {
                        guard await record(intent(
                            sessionID: session.id,
                            operationID: request.operationID,
                            attemptID: request.attemptID,
                            kind: .executor,
                            toolName: StageBToolName(rawValue: request.call.name),
                            toolCallID: request.call.id,
                            inputSHA256: request.inputSHA256
                        )) else { return .reconciliationRequired }
                    }
                    if toolExecutionCount + calls.count > limits.maximumToolExecutions {
                        let rejection = StageBBatchPolicyError(
                            reason: .limitsExceeded,
                            callIndex: nil
                        )
                        unresolvedPolicyRejection = true
                        guard await recordNotExecutedBatch(
                            sessionID: session.id,
                            pending: pending,
                            rejection: rejection
                        ) else { return await fail(session, .evidenceUnavailable) }
                        let feedback = boundedPolicyFeedback(rejection)
                        lastExchange = [assistant] + calls.map {
                            ProviderTurnMessage(role: .tool, content: feedback, toolCallID: $0.id)
                        }
                        usedToolCallIDs.formUnion(calls.map(\.id))
                        continue
                    }
                    let authorized: [StageBAuthorizedToolCall]
                    do {
                        authorized = try policy.authorizeBatch(
                            calls,
                            previouslyUsedIDs: usedToolCallIDs
                        )
                    } catch let rejection as StageBBatchPolicyError {
                        unresolvedPolicyRejection = true
                        guard await recordNotExecutedBatch(
                            sessionID: session.id,
                            pending: pending,
                            rejection: rejection
                        ) else { return await fail(session, .evidenceUnavailable) }
                        let feedback = boundedPolicyFeedback(rejection)
                        lastExchange = [assistant] + calls.map {
                            ProviderTurnMessage(role: .tool, content: feedback, toolCallID: $0.id)
                        }
                        usedToolCallIDs.formUnion(calls.map(\.id))
                        continue
                    } catch {
                        return await fail(session, .invalidArguments)
                    }

                    unresolvedPolicyRejection = false
                    usedToolCallIDs.formUnion(authorized.map(\.toolCallID))
                    var exchange = [assistant]
                    guard authorized.count == pending.count else {
                        return .reconciliationRequired
                    }
                    for (call, request) in zip(authorized, pending) {
                        toolExecutionCount += 1
                        switch await executor.execute(call.tool) {
                        case let .observation(observation):
                            guard observation.ruleSetSHA256 == call.tool.ruleSetSHA256,
                                  observation.tool == call.tool.name,
                                  observation.relativePath == call.tool.relativePath,
                                  observation.query == call.tool.query else {
                                let recorded = await record(terminal(
                                    sessionID: session.id,
                                    operationID: request.operationID,
                                    attemptID: request.attemptID,
                                    kind: .executor,
                                    toolName: call.tool.name,
                                    toolCallID: call.toolCallID,
                                    inputSHA256: request.inputSHA256,
                                    phase: .failed,
                                    category: .executorFailure
                                ))
                                if recorded { return await fail(session, .executorFailure) }
                                return .reconciliationRequired
                            }
                            let modelContent: String
                            let observationEvidence: StageBObservationEvidence
                            do {
                                modelContent = try StageBModelObservation.render(observation, limits: limits)
                                observationEvidence = try StageBObservationEvidence.make(
                                    observation: observation,
                                    exactQuery: session.goal.exactQuery,
                                    limits: limits
                                )
                            } catch {
                                let recorded = await record(terminal(
                                    sessionID: session.id,
                                    operationID: request.operationID,
                                    attemptID: request.attemptID,
                                    kind: .executor,
                                    toolName: call.tool.name,
                                    toolCallID: call.toolCallID,
                                    inputSHA256: request.inputSHA256,
                                    phase: .failed,
                                    category: .executorFailure
                                ))
                                if recorded { return await fail(session, .executorFailure) }
                                return .reconciliationRequired
                            }
                            guard await record(terminal(
                                sessionID: session.id,
                                operationID: request.operationID,
                                attemptID: request.attemptID,
                                kind: .executor,
                                toolName: call.tool.name,
                                toolCallID: call.toolCallID,
                                inputSHA256: request.inputSHA256,
                                phase: .succeeded,
                                category: .observation,
                                result: Data(modelContent.utf8),
                                observation: observationEvidence
                            )) else { return .reconciliationRequired }
                            observations.append(observation)
                            exchange.append(ProviderTurnMessage(
                                role: .tool,
                                content: modelContent,
                                toolCallID: call.toolCallID
                            ))
                        case .failure:
                            let recorded = await record(terminal(
                                sessionID: session.id,
                                operationID: request.operationID,
                                attemptID: request.attemptID,
                                kind: .executor,
                                toolName: call.tool.name,
                                toolCallID: call.toolCallID,
                                inputSHA256: request.inputSHA256,
                                phase: .failed,
                                category: .executorFailure
                            ))
                            if recorded { return await fail(session, .executorFailure) }
                            return .reconciliationRequired
                        case .unknown:
                            _ = await record(terminal(
                                sessionID: session.id,
                                operationID: request.operationID,
                                attemptID: request.attemptID,
                                kind: .executor,
                                toolName: call.tool.name,
                                toolCallID: call.toolCallID,
                                inputSHA256: request.inputSHA256,
                                phase: .reconciliationRequired,
                                category: .executorUnknown
                            ))
                            _ = try? await sessionStore.transition(
                                session,
                                to: .reconciliationRequired,
                                diagnostic: "executor_unknown",
                                now: now()
                            )
                            return .reconciliationRequired
                        }
                    }
                    lastExchange = exchange
                }

            case .failure:
                let recorded = await record(terminal(
                    sessionID: session.id,
                    operationID: providerOperationID,
                    attemptID: providerAttemptID,
                    kind: .provider,
                    inputSHA256: inputHash,
                    phase: .failed,
                    category: .providerFailure
                ))
                if recorded { return await fail(session, .providerFailure) }
                return .reconciliationRequired
            case .unknown:
                _ = await record(terminal(
                    sessionID: session.id,
                    operationID: providerOperationID,
                    attemptID: providerAttemptID,
                    kind: .provider,
                    inputSHA256: inputHash,
                    phase: .reconciliationRequired,
                    category: .providerUnknown
                ))
                _ = try? await sessionStore.transition(
                    session,
                    to: .reconciliationRequired,
                    diagnostic: "provider_unknown",
                    now: now()
                )
                return .reconciliationRequired
            }
        }
        return await fail(session, .completionNotEstablished)
    }

    private func establishCompletion(
        session: StageBSessionRecord,
        verified: StageBCompletionVerifier.Verified,
        observations: [StageBToolObservation],
        providerRequestCount: Int,
        toolExecutionCount: Int
    ) async -> StageBLoopOutcome {
        let operationID = makeUUID()
        let attemptID = makeUUID()
        let inputHash = ProviderDigest.sha256Hex([
            session.workspaceIdentitySHA256,
            session.goal.bindingSHA256,
            ruleSet.bindingSHA256,
            verified.evidenceChainSHA256
        ].joined(separator: "\u{0}"))
        guard await record(intent(
            sessionID: session.id,
            operationID: operationID,
            attemptID: attemptID,
            kind: .completionCheck,
            inputSHA256: inputHash
        )) else { return await fail(session, .evidenceUnavailable) }

        let snapshot: StageBDurableSnapshot
        do { snapshot = try await sessionStore.snapshot(sessionID: session.id) }
        catch { return await fail(session, .evidenceUnavailable) }
        guard !hasUnresolvedExternalAttempt(snapshot.attempts),
              observations.count >= 3,
              session.goal.expectedRelativePath.map({ $0 == verified.relativePath }) ?? true else {
            _ = await record(terminal(
                sessionID: session.id,
                operationID: operationID,
                attemptID: attemptID,
                kind: .completionCheck,
                inputSHA256: inputHash,
                phase: .failed,
                category: .completionRejected
            ))
            return await fail(session, .completionNotEstablished)
        }
        let completion = StageBCompletion(
            sessionID: session.id,
            workspaceIdentitySHA256: session.workspaceIdentitySHA256,
            goalBindingSHA256: session.goal.bindingSHA256,
            ruleSetBindingSHA256: ruleSet.bindingSHA256,
            relativePath: verified.relativePath,
            query: session.goal.exactQuery,
            providerRequestCount: providerRequestCount,
            toolExecutionCount: toolExecutionCount,
            evidenceChainSHA256: verified.evidenceChainSHA256
        )
        let completionData = completionEvidenceData(completion)
        guard !completionData.isEmpty,
              await record(terminal(
                  sessionID: session.id,
                  operationID: operationID,
                  attemptID: attemptID,
                  kind: .completionCheck,
                  inputSHA256: inputHash,
                  phase: .succeeded,
                  category: .completionEstablished,
                  result: completionData
              )) else { return .reconciliationRequired }
        do {
            _ = try await sessionStore.transition(
                session,
                to: .completed,
                completion: completion,
                now: now()
            )
            return .completed(completion)
        } catch {
            return .reconciliationRequired
        }
    }

    private func hasUnresolvedExternalAttempt(_ attempts: [StageBAttemptEvidence]) -> Bool {
        let external = attempts.filter { $0.kind == .provider || $0.kind == .executor }
        let groups = Dictionary(grouping: external, by: \.attemptID)
        return groups.values.contains { records in
            records.contains(where: { $0.phase == .intentRecorded })
                && !records.contains(where: { $0.phase != .intentRecorded })
                || records.contains(where: { $0.phase == .reconciliationRequired })
        }
    }

    private func durableCompletionIsValid(
        _ completion: StageBCompletion,
        session: StageBSessionRecord,
        attempts: [StageBAttemptEvidence]
    ) -> Bool {
        guard completion.sessionID == session.id,
              completion.workspaceIdentitySHA256 == session.workspaceIdentitySHA256,
              completion.goalBindingSHA256 == session.goal.bindingSHA256,
              completion.ruleSetBindingSHA256 == ruleSet.bindingSHA256,
              completion.query == session.goal.exactQuery,
              session.goal.expectedRelativePath.map({ $0 == completion.relativePath }) ?? true,
              !attempts.contains(where: { $0.phase == .reconciliationRequired }) else {
            return false
        }
        let externalGroups = Dictionary(
            grouping: attempts.filter { $0.kind == .provider || $0.kind == .executor },
            by: \.attemptID
        )
        guard externalGroups.values.allSatisfy({ records in
            records.count == 2
                && records.map(\.phase) == [.intentRecorded, .succeeded]
                    || records.count == 2
                        && records.map(\.phase) == [.intentRecorded, .failed]
        }) else { return false }
        let completionData = completionEvidenceData(completion)
        guard !completionData.isEmpty,
              let providerFinishIndex = attempts.lastIndex(where: {
                  $0.kind == .provider
                      && $0.phase == .succeeded
                      && $0.category == .providerFinish
              }),
              let completionIndex = attempts.lastIndex(where: {
                  $0.kind == .completionCheck
                      && $0.phase == .succeeded
                      && $0.category == .completionEstablished
                      && $0.resultSHA256 == ProviderDigest.sha256Hex(completionData)
              }),
              providerFinishIndex < completionIndex else {
            return false
        }
        let completionAttempt = attempts[completionIndex]
        let completionGroup = attempts.filter {
            $0.operationID == completionAttempt.operationID
        }
        guard completionGroup.count == 2,
              completionGroup.map(\.phase) == [.intentRecorded, .succeeded],
              Set(completionGroup.map(\.attemptID)).count == 1 else {
            return false
        }
        let observations = attempts.compactMap(\.observation)
        for listIndex in observations.indices {
            let list = observations[listIndex]
            guard list.tool == .list,
                  let entries = list.listedEntries else { continue }
            for searchIndex in observations.indices where searchIndex > listIndex {
                let search = observations[searchIndex]
                guard search.tool == .search,
                      search.querySHA256 == ProviderDigest.sha256Hex(session.goal.exactQuery),
                      let matches = search.matches,
                      matches.count == 1,
                      matches[0].path == completion.relativePath,
                      matches[0].exactQueryOccurrences > 0,
                      StageBCompletionVerifier.listCovers(
                          path: completion.relativePath,
                          listPath: list.relativePath,
                          entries: entries
                      ) else { continue }
                for readIndex in observations.indices where readIndex > searchIndex {
                    let read = observations[readIndex]
                    guard read.tool == .read,
                          read.relativePath == completion.relativePath,
                          (read.exactQueryOccurrences ?? 0) > 0 else { continue }
                    let chain = [
                        list.observationSHA256,
                        search.observationSHA256,
                        read.observationSHA256
                    ].joined(separator: "\n")
                    return ProviderDigest.sha256Hex(chain) == completion.evidenceChainSHA256
                }
            }
        }
        return false
    }

    private func completionEvidenceData(_ completion: StageBCompletion) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(completion)) ?? Data()
    }

    private func recordNotExecutedBatch(
        sessionID: UUID,
        pending: [PendingToolAttempt],
        rejection: StageBBatchPolicyError
    ) async -> Bool {
        for request in pending {
            let terminal = StageBAttemptEvidence(
                sessionID: sessionID,
                operationID: request.operationID,
                attemptID: request.attemptID,
                kind: .executor,
                toolName: StageBToolName(rawValue: request.call.name),
                toolCallIDHash: ProviderDigest.sha256Hex(request.call.id),
                inputSHA256: request.inputSHA256,
                recordedAt: now(),
                phase: .failed,
                category: .policyNotExecuted,
                resultByteCount: nil,
                resultSHA256: ProviderDigest.sha256Hex(rejection.reason.rawValue),
                observation: nil
            )
            guard await record(terminal) else { return false }
        }
        return true
    }

    private func boundedPolicyFeedback(_ rejection: StageBBatchPolicyError) -> String {
        let index = rejection.callIndex.map(String.init) ?? "none"
        let value = "{\"status\":\"not_executed\",\"reason\":\"policy_rejected\",\"policy_code\":\"\(rejection.reason.rawValue)\",\"call_index\":\"\(index)\"}"
        return String(value.prefix(512))
    }

    private func inferenceInputHash(_ request: ProviderInferenceRequest) -> String {
        var parts = ["requireTool=\(request.requireTool)"]
        parts.append(contentsOf: request.tools.map { "tool=\($0.name)" })
        for message in request.messages {
            parts.append("role=\(message.role.rawValue)")
            let contentHash = message.content.map(ProviderDigest.sha256Hex) ?? "none"
            parts.append("content=\(contentHash)")
            parts.append(contentsOf: message.toolCalls.map {
                "call=\(ProviderDigest.sha256Hex($0.id)):\($0.name):\(ProviderDigest.sha256Hex($0.arguments))"
            })
            let toolCallIDHash = message.toolCallID.map(ProviderDigest.sha256Hex) ?? "none"
            parts.append("toolCallID=\(toolCallIDHash)")
        }
        return ProviderDigest.sha256Hex(parts.joined(separator: "\n"))
    }

    private func intent(
        sessionID: UUID,
        operationID: UUID,
        attemptID: UUID,
        kind: StageBAttemptKind,
        toolName: StageBToolName? = nil,
        toolCallID: String? = nil,
        inputSHA256: String
    ) -> StageBAttemptEvidence {
        terminal(
            sessionID: sessionID,
            operationID: operationID,
            attemptID: attemptID,
            kind: kind,
            toolName: toolName,
            toolCallID: toolCallID,
            inputSHA256: inputSHA256,
            phase: .intentRecorded,
            category: .none
        )
    }

    private func terminal(
        sessionID: UUID,
        operationID: UUID,
        attemptID: UUID,
        kind: StageBAttemptKind,
        toolName: StageBToolName? = nil,
        toolCallID: String? = nil,
        inputSHA256: String,
        phase: StageBAttemptPhase,
        category: StageBAttemptCategory,
        result: Data? = nil,
        observation: StageBObservationEvidence? = nil
    ) -> StageBAttemptEvidence {
        StageBAttemptEvidence(
            sessionID: sessionID,
            operationID: operationID,
            attemptID: attemptID,
            kind: kind,
            toolName: toolName,
            toolCallIDHash: toolCallID.map(ProviderDigest.sha256Hex),
            inputSHA256: inputSHA256,
            recordedAt: now(),
            phase: phase,
            category: category,
            resultByteCount: result?.count,
            resultSHA256: result.map(ProviderDigest.sha256Hex),
            observation: observation
        )
    }

    private func record(_ evidence: StageBAttemptEvidence) async -> Bool {
        do { try await sessionStore.record(evidence); return true }
        catch { return false }
    }

    private func fail(_ session: StageBSessionRecord, _ error: StageBError) async -> StageBLoopOutcome {
        _ = try? await sessionStore.transition(
            session,
            to: .failed,
            diagnostic: error.rawValue,
            now: now()
        )
        return .failure(error)
    }
}

enum StageBCompletionVerifier {
    struct Verified: Equatable, Sendable {
        let relativePath: String
        let evidenceChainSHA256: String
    }

    static func verify(
        observations: [StageBToolObservation],
        session: StageBSessionRecord,
        ruleSet: StageBRuleSet
    ) -> Verified? {
        guard session.ruleSetBindingSHA256 == ruleSet.bindingSHA256 else { return nil }
        let query = session.goal.exactQuery
        for listIndex in observations.indices {
            let list = observations[listIndex]
            guard list.tool == .list,
                  list.facts.completionBarrierSatisfied,
                  list.facts.exitedSuccessfully,
                  !list.facts.truncated,
                  case let .list(entries) = list.payload else { continue }
            for searchIndex in observations.indices where searchIndex > listIndex {
                let search = observations[searchIndex]
                guard search.tool == .search,
                      search.query == query,
                      search.facts.completionBarrierSatisfied,
                      !search.facts.truncated,
                      case let .search(matches) = search.payload,
                      matches.count == 1,
                      matches[0].text.contains(query) else { continue }
                let match = matches[0]
                guard session.goal.expectedRelativePath.map({ $0 == match.path }) ?? true,
                      listCovers(path: match.path, listPath: list.relativePath, entries: entries) else {
                    continue
                }
                for readIndex in observations.indices where readIndex > searchIndex {
                    let read = observations[readIndex]
                    guard read.tool == .read,
                          read.relativePath == match.path,
                          read.facts.completionBarrierSatisfied,
                          read.facts.exitedSuccessfully,
                          !read.facts.truncated,
                          case let .read(path, content) = read.payload,
                          path == match.path,
                          content.contains(query) else { continue }
                    let chain = [list, search, read].map(\.evidenceSHA256).joined(separator: "\n")
                    return Verified(
                        relativePath: match.path,
                        evidenceChainSHA256: ProviderDigest.sha256Hex(chain)
                    )
                }
            }
        }
        return nil
    }

    static func listCovers(path: String, listPath: String, entries: [String]) -> Bool {
        let pathParts = path.split(separator: "/").map(String.init)
        let listParts = listPath.split(separator: "/").map(String.init)
        guard pathParts.count > listParts.count,
              Array(pathParts.prefix(listParts.count)) == listParts else { return false }
        return entries.contains(pathParts[listParts.count])
    }
}
