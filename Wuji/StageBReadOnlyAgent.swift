import Foundation

struct StageBPreparedSession: Sendable {
    let session: StageBSessionRecord
    let workspace: StageBReadyWorkspace
    let ruleSet: StageBRuleSet
}

struct StageBProviderMessageBinding: Codable, Equatable, Sendable {
    let contentByteCount: Int
    let contentSHA256: String?

    static func make(_ message: ProviderTurnMessage) -> StageBProviderMessageBinding {
        StageBProviderMessageBinding(
            contentByteCount: message.content?.utf8.count ?? 0,
            contentSHA256: message.content.map(ProviderDigest.sha256Hex)
        )
    }
}

struct StageBCanonicalProviderRequest: Sendable {
    let request: ProviderInferenceRequest
    let inputSHA256: String
}

struct StageBProviderRequestCanonicalizer: Sendable {
    private struct CanonicalMessage: Codable {
        let role: ProviderTurnRole
        let contentByteCount: Int
        let contentSHA256: String?
        let toolCalls: [ProviderTurnToolCall]
        let toolCallID: String?
    }

    private struct BindingEnvelope: Encodable {
        let schemaVersion: Int
        let providerID: String
        let sessionID: UUID
        let importID: UUID
        let workspaceID: UUID
        let workspaceIdentitySHA256: String
        let markerSHA256: String
        let goal: StageBGoal
        let ruleSetBindingSHA256: String
        let rules: [StageBRuleDescriptor]
        let providerTurnOrdinal: Int
        let completedToolExecutionCount: Int
        let unresolvedPolicyRejection: Bool
        let usedToolCallIDHashes: [String]
        let historyBindingSHA256: String
        let stageBLimits: [Int]
        let providerLimits: [Int]
        let messages: [CanonicalMessage]
        let tools: [ProviderToolDefinition]
        let requireTool: Bool
    }

    private struct ProviderHistoryEvent: Encodable {
        let category: StageBAttemptCategory
        let outcome: StageBProviderOutcomeEvidence
    }

    private struct ObservationHistoryEvent: Encodable {
        let toolCallIDHash: String
        let observation: StageBObservationEvidence
    }

    private struct PolicyHistoryEvent: Encodable {
        let toolCallIDHashes: [String]
        let rejection: StageBPolicyRejectionEvidence
        let feedbackSHA256: String
    }

    static let emptyHistorySHA256 = ProviderDigest.sha256Hex(
        "stage-b-provider-history-v1"
    )

    static func boundedPolicyFeedback(_ rejection: StageBBatchPolicyError) -> String {
        let index = rejection.callIndex.map(String.init) ?? "none"
        let value = "{\"status\":\"not_executed\",\"reason\":\"policy_rejected\",\"policy_code\":\"\(rejection.reason.rawValue)\",\"call_index\":\"\(index)\"}"
        return String(value.prefix(512))
    }

    let providerID: String
    let limits: StageBLimits

    func make(
        session: StageBSessionRecord,
        ruleSet: StageBRuleSet,
        observations: [StageBObservationEvidence],
        lastExchange: [ProviderTurnMessage],
        lastExchangeBindings: [StageBProviderMessageBinding],
        historyBindingSHA256: String,
        completedProviderRequestCount: Int,
        completedToolExecutionCount: Int,
        unresolvedPolicyRejection: Bool,
        usedToolCallIDs: Set<String>,
        requireTool: Bool
    ) throws -> StageBCanonicalProviderRequest {
        guard !providerID.isEmpty,
              providerID.utf8.count <= ProviderLimits.maximumToolNameBytes,
              providerID.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }),
              validHash(historyBindingSHA256),
              session.ruleSetBindingSHA256 == ruleSet.bindingSHA256,
              session.rules == ruleSet.descriptors,
              completedProviderRequestCount >= 0,
              completedProviderRequestCount < limits.maximumProviderTurns,
              completedToolExecutionCount >= 0,
              completedToolExecutionCount <= limits.maximumToolExecutions,
              lastExchange.count == lastExchangeBindings.count,
              lastExchangeBindings.allSatisfy({
                  $0.contentByteCount >= 0
                      && $0.contentByteCount <= ProviderLimits.maximumTurnMessageBytes
                      && ($0.contentSHA256.map(validHash) ?? $0.contentByteCount == 0)
              }) else {
            throw StageBError.evidenceUnavailable
        }
        let contextWindow = StageBContextWindow(limits: limits)
        let baseMessages = try contextWindow.baseMessages(session: session, ruleSet: ruleSet)
        var exchange: [ProviderTurnMessage] = []
        if !observations.isEmpty {
            let lines = observations.map {
                "tool=\($0.tool.rawValue) path_hash=\(ProviderDigest.sha256Hex($0.relativePath)) rules=\($0.ruleSetSHA256) evidence=\($0.observationSHA256)"
            }
            exchange.append(ProviderTurnMessage(
                role: .user,
                content: "Harness verified prior read-only observations:\n" + lines.joined(separator: "\n")
            ))
        }
        exchange.append(contentsOf: lastExchange)
        let request = try contextWindow.request(
            baseMessages: baseMessages,
            observations: [],
            lastExchange: exchange,
            requireTool: requireTool
        )
        let exchangeStart = request.messages.count - lastExchange.count
        let canonicalMessages = request.messages.enumerated().map { index, message in
            let binding = index >= exchangeStart
                ? lastExchangeBindings[index - exchangeStart]
                : StageBProviderMessageBinding.make(message)
            return CanonicalMessage(
                role: message.role,
                contentByteCount: binding.contentByteCount,
                contentSHA256: binding.contentSHA256,
                toolCalls: message.toolCalls,
                toolCallID: message.toolCallID
            )
        }
        let envelope = BindingEnvelope(
            schemaVersion: 1,
            providerID: providerID,
            sessionID: session.id,
            importID: session.importID,
            workspaceID: session.workspaceID,
            workspaceIdentitySHA256: session.workspaceIdentitySHA256,
            markerSHA256: session.markerSHA256,
            goal: session.goal,
            ruleSetBindingSHA256: ruleSet.bindingSHA256,
            rules: ruleSet.descriptors,
            providerTurnOrdinal: completedProviderRequestCount + 1,
            completedToolExecutionCount: completedToolExecutionCount,
            unresolvedPolicyRejection: unresolvedPolicyRejection,
            usedToolCallIDHashes: usedToolCallIDs
                .map(ProviderDigest.sha256Hex)
                .sorted(),
            historyBindingSHA256: historyBindingSHA256,
            stageBLimits: stageLimitValues,
            providerLimits: [
                ProviderLimits.maximumRequestBodyBytes,
                ProviderLimits.maximumModelBytes,
                ProviderLimits.maximumResponseBodyBytes,
                ProviderLimits.maximumOutputBytes,
                ProviderLimits.maximumChoices,
                ProviderLimits.maximumTurnMessages,
                ProviderLimits.maximumTurnMessageBytes,
                ProviderLimits.maximumToolDefinitions,
                ProviderLimits.maximumToolNameBytes,
                ProviderLimits.maximumToolArgumentsBytes,
                ProviderLimits.maximumToolCallIDBytes
            ],
            messages: canonicalMessages,
            tools: request.tools,
            requireTool: request.requireTool
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(envelope)
        return StageBCanonicalProviderRequest(
            request: request,
            inputSHA256: ProviderDigest.sha256Hex(data)
        )
    }

    func appendingProviderOutcome(
        _ outcome: StageBProviderOutcomeEvidence,
        category: StageBAttemptCategory,
        to history: String
    ) -> String? {
        appendHistory(
            ProviderHistoryEvent(category: category, outcome: outcome),
            kind: "provider",
            to: history
        )
    }

    func appendingObservation(
        _ observation: StageBObservationEvidence,
        toolCallID: String,
        to history: String
    ) -> String? {
        appendHistory(
            ObservationHistoryEvent(
                toolCallIDHash: ProviderDigest.sha256Hex(toolCallID),
                observation: observation
            ),
            kind: "observation",
            to: history
        )
    }

    func appendingPolicyRejection(
        _ rejection: StageBBatchPolicyError,
        calls: [ProviderTurnToolCall],
        feedback: String,
        to history: String
    ) -> String? {
        appendHistory(
            PolicyHistoryEvent(
                toolCallIDHashes: calls.map { ProviderDigest.sha256Hex($0.id) },
                rejection: StageBPolicyRejectionEvidence(
                    reason: rejection.reason,
                    callIndex: rejection.callIndex
                ),
                feedbackSHA256: ProviderDigest.sha256Hex(feedback)
            ),
            kind: "policy_not_executed",
            to: history
        )
    }

    private func appendHistory<Value: Encodable>(
        _ value: Value,
        kind: String,
        to history: String
    ) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return nil }
        return ProviderDigest.sha256Hex([
            history,
            kind,
            ProviderDigest.sha256Hex(data)
        ].joined(separator: "\u{0}"))
    }

    private var stageLimitValues: [Int] {
        [
            limits.maximumProviderTurns,
            limits.maximumToolExecutions,
            limits.maximumToolCallsPerBatch,
            limits.maximumGoalBytes,
            limits.maximumPathBytes,
            limits.maximumQueryBytes,
            limits.maximumRuleFiles,
            limits.maximumRuleFileBytes,
            limits.maximumRuleAggregateBytes,
            limits.maximumContextBytes,
            limits.maximumListEntries,
            limits.maximumSearchMatches,
            limits.maximumReadBytes,
            limits.maximumLineBytes,
            limits.maximumExecutorStreamBytes,
            limits.maximumModelObservationBytes,
            limits.maximumDurableEvidenceBytes,
            limits.maximumDiagnosticBytes
        ]
    }

    private func validHash(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdef").contains($0)
        }
    }
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

    private struct ExternalAttemptPair: Sendable {
        let intentIndex: Int
        let terminalIndex: Int
        let intent: StageBAttemptEvidence
        let terminal: StageBAttemptEvidence
    }

    private struct LoopState: Sendable {
        var observations: [StageBObservationEvidence] = []
        var lastExchange: [ProviderTurnMessage] = []
        var lastExchangeBindings: [StageBProviderMessageBinding] = []
        var historyBindingSHA256 = StageBProviderRequestCanonicalizer.emptyHistorySHA256
        var usedToolCallIDs = Set<String>()
        var providerRequestCount = 0
        var toolExecutionCount = 0
        var unresolvedPolicyRejection = false
        var pendingDecision: ProviderInferenceDecision?
        var finishCanComplete = false
    }

    private enum ReplayResult: Sendable {
        case state(LoopState)
        case failure(StageBError)
        case reconciliationRequired
    }

    private enum ToolBatchResult: Sendable {
        case state(LoopState)
        case outcome(StageBLoopOutcome)
    }

    private let provider: AgentInferenceProvider
    private let executor: StageBReadOnlyExecuting
    private let policy: StageBReadOnlyPolicy
    private let sessionStore: StageBSessionStore
    private let workspace: StageBReadyWorkspace
    private let ruleSet: StageBRuleSet
    private let limits: StageBLimits
    private let requestCanonicalizer: StageBProviderRequestCanonicalizer
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
        requestCanonicalizer = StageBProviderRequestCanonicalizer(
            providerID: provider.providerID,
            limits: limits
        )
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
        if session.phase == .completed, let completion = session.completion {
            guard case let .state(rebuilt) = rebuild(initial.attempts, session: session),
                  rebuilt.finishCanComplete,
                  rebuilt.pendingDecision == nil,
                  rebuilt.providerRequestCount == completion.providerRequestCount,
                  rebuilt.toolExecutionCount == completion.toolExecutionCount,
                  durableCompletionIsValid(
                completion,
                session: session,
                attempts: initial.attempts
            ) else { return await requireReconciliation(session) }
            return .completed(completion)
        }
        guard session.phase != .completed, session.completion == nil else {
            return await requireReconciliation(session)
        }

        var state: LoopState
        switch rebuild(initial.attempts, session: session) {
        case let .state(rebuilt):
            state = rebuilt
        case let .failure(error):
            return .failure(error)
        case .reconciliationRequired:
            return await requireReconciliation(session)
        }
        do {
            session = try await sessionStore.transition(session, to: .running, now: now())
        } catch {
            return .failure(.evidenceUnavailable)
        }

        if state.finishCanComplete,
           let verified = StageBCompletionVerifier.verify(
               observations: state.observations,
               session: session,
               ruleSet: ruleSet
           ) {
            return await establishCompletion(
                session: session,
                verified: verified,
                observations: state.observations,
                providerRequestCount: state.providerRequestCount,
                toolExecutionCount: state.toolExecutionCount
            )
        }
        if let pending = state.pendingDecision {
            guard case let .toolCalls(assistant, calls) = pending else {
                return await requireReconciliation(session)
            }
            state.pendingDecision = nil
            switch await executeToolBatch(
                session: session,
                assistant: assistant,
                calls: calls,
                state: state
            ) {
            case let .state(updated): state = updated
            case let .outcome(outcome): return outcome
            }
        }

        while state.providerRequestCount < limits.maximumProviderTurns {
            let verified = StageBCompletionVerifier.verify(
                observations: state.observations,
                session: session,
                ruleSet: ruleSet
            )
            let material: StageBCanonicalProviderRequest
            do {
                material = try requestCanonicalizer.make(
                    session: session,
                    ruleSet: ruleSet,
                    observations: state.observations,
                    lastExchange: state.lastExchange,
                    lastExchangeBindings: state.lastExchangeBindings,
                    historyBindingSHA256: state.historyBindingSHA256,
                    completedProviderRequestCount: state.providerRequestCount,
                    completedToolExecutionCount: state.toolExecutionCount,
                    unresolvedPolicyRejection: state.unresolvedPolicyRejection,
                    usedToolCallIDs: state.usedToolCallIDs,
                    requireTool: verified == nil
                )
            } catch {
                return await fail(session, .contextLimit)
            }
            let providerOperationID = makeUUID()
            let providerAttemptID = makeUUID()
            let inputHash = material.inputSHA256
            guard await record(intent(
                sessionID: session.id,
                operationID: providerOperationID,
                attemptID: providerAttemptID,
                kind: .provider,
                inputSHA256: inputHash
            )) else { return await fail(session, .evidenceUnavailable) }

            state.providerRequestCount += 1
            let outcome = await provider.infer(request: material.request, requestID: makeUUID())
            switch outcome {
            case let .decision(decision):
                let providerCategory: StageBAttemptCategory
                switch decision {
                case .toolCalls: providerCategory = .providerToolCalls
                case .finish: providerCategory = .providerFinish
                }
                let outcomeEvidence = providerOutcomeEvidence(decision)
                guard await record(terminal(
                    sessionID: session.id,
                    operationID: providerOperationID,
                    attemptID: providerAttemptID,
                    kind: .provider,
                    inputSHA256: inputHash,
                    phase: .succeeded,
                    category: providerCategory,
                    result: Data(decision.description.utf8),
                    providerOutcome: outcomeEvidence
                )) else { return .reconciliationRequired }
                guard let history = requestCanonicalizer.appendingProviderOutcome(
                    outcomeEvidence,
                    category: providerCategory,
                    to: state.historyBindingSHA256
                ) else { return .reconciliationRequired }
                state.historyBindingSHA256 = history

                switch decision {
                case let .finish(assistant):
                    if let verified, !state.unresolvedPolicyRejection {
                        return await establishCompletion(
                            session: session,
                            verified: verified,
                            observations: state.observations,
                            providerRequestCount: state.providerRequestCount,
                            toolExecutionCount: state.toolExecutionCount
                        )
                    }
                    state.lastExchange = completionRejectedExchange(assistant: assistant)
                    state.lastExchangeBindings = state.lastExchange.map(
                        StageBProviderMessageBinding.make
                    )

                case let .toolCalls(assistant, calls):
                    switch await executeToolBatch(
                        session: session,
                        assistant: assistant,
                        calls: calls,
                        state: state
                    ) {
                    case let .state(updated): state = updated
                    case let .outcome(outcome): return outcome
                    }
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

    private func rebuild(
        _ attempts: [StageBAttemptEvidence],
        session: StageBSessionRecord
    ) -> ReplayResult {
        guard let pairs = externalAttemptPairs(attempts) else {
            return .reconciliationRequired
        }
        if pairs.contains(where: { $0.terminal.phase == .reconciliationRequired }) {
            return .reconciliationRequired
        }
        var state = LoopState()
        var cursor = 0
        while cursor < pairs.count {
            let providerPair = pairs[cursor]
            guard providerPair.intent.kind == .provider,
                  providerPair.intent.toolName == nil,
                  providerPair.intent.toolCallIDHash == nil else {
                return .reconciliationRequired
            }
            let verifiedBeforeRequest = StageBCompletionVerifier.verify(
                observations: state.observations,
                session: session,
                ruleSet: ruleSet
            )
            let expected: StageBCanonicalProviderRequest
            do {
                expected = try requestCanonicalizer.make(
                    session: session,
                    ruleSet: ruleSet,
                    observations: state.observations,
                    lastExchange: state.lastExchange,
                    lastExchangeBindings: state.lastExchangeBindings,
                    historyBindingSHA256: state.historyBindingSHA256,
                    completedProviderRequestCount: state.providerRequestCount,
                    completedToolExecutionCount: state.toolExecutionCount,
                    unresolvedPolicyRejection: state.unresolvedPolicyRejection,
                    usedToolCallIDs: state.usedToolCallIDs,
                    requireTool: verifiedBeforeRequest == nil
                )
            } catch {
                return .reconciliationRequired
            }
            guard expected.inputSHA256 == providerPair.intent.inputSHA256,
                  expected.inputSHA256 == providerPair.terminal.inputSHA256 else {
                return .reconciliationRequired
            }
            state.providerRequestCount += 1
            switch providerPair.terminal.phase {
            case .failed:
                guard providerPair.terminal.category == .providerFailure,
                      cursor == pairs.count - 1 else {
                    return .reconciliationRequired
                }
                return .failure(.providerFailure)
            case .succeeded:
                break
            case .intentRecorded, .reconciliationRequired:
                return .reconciliationRequired
            }
            guard let outcome = providerPair.terminal.providerOutcome,
                  providerPair.terminal.resultByteCount == outcome.resultDescription.utf8.count,
                  providerPair.terminal.resultSHA256 == ProviderDigest.sha256Hex(
                      outcome.resultDescription
                  ) else {
                return .reconciliationRequired
            }
            guard let history = requestCanonicalizer.appendingProviderOutcome(
                outcome,
                category: providerPair.terminal.category,
                to: state.historyBindingSHA256
            ) else {
                return .reconciliationRequired
            }
            state.historyBindingSHA256 = history

            let nextProvider = pairs[(cursor + 1)...].firstIndex {
                $0.intent.kind == .provider
            } ?? pairs.endIndex
            let executorPairs = Array(pairs[(cursor + 1)..<nextProvider])
            if !executorPairs.isEmpty {
                guard executorPairs.allSatisfy({
                    $0.intent.kind == .executor
                        && $0.intentIndex > providerPair.terminalIndex
                }),
                let firstTerminalIndex = executorPairs.map(\.terminalIndex).min(),
                executorPairs.allSatisfy({ $0.intentIndex < firstTerminalIndex }),
                executorPairs.map(\.terminalIndex) == executorPairs.map(\.terminalIndex).sorted(),
                nextProvider == pairs.endIndex
                    || executorPairs.allSatisfy({
                        $0.terminalIndex < pairs[nextProvider].intentIndex
                    }) else {
                    return .reconciliationRequired
                }
            }
            switch outcome.decision {
            case let .finish(assistant):
                guard providerPair.terminal.category == .providerFinish,
                      executorPairs.isEmpty else {
                    return .reconciliationRequired
                }
                if verifiedBeforeRequest != nil, !state.unresolvedPolicyRejection {
                    guard nextProvider == pairs.endIndex else {
                        return .reconciliationRequired
                    }
                    state.finishCanComplete = true
                } else {
                    state.lastExchange = completionRejectedExchange(assistant: assistant)
                    let assistantBinding = nextProvider == pairs.endIndex
                        ? StageBProviderMessageBinding.make(assistant)
                        : StageBProviderMessageBinding(
                            contentByteCount: outcome.assistantContentByteCount,
                            contentSHA256: outcome.assistantContentSHA256
                        )
                    state.lastExchangeBindings = [
                        assistantBinding,
                        StageBProviderMessageBinding.make(state.lastExchange[1])
                    ]
                }
            case let .toolCalls(assistant, calls):
                guard providerPair.terminal.category == .providerToolCalls else {
                    return .reconciliationRequired
                }
                if executorPairs.isEmpty {
                    guard nextProvider == pairs.endIndex else {
                        return .reconciliationRequired
                    }
                    state.pendingDecision = .toolCalls(assistant, calls)
                    return .state(state)
                }
                guard executorPairs.count == calls.count else {
                    return .reconciliationRequired
                }
                let expectedRejection: StageBBatchPolicyError?
                let authorized: [StageBAuthorizedToolCall]
                if state.toolExecutionCount + calls.count > limits.maximumToolExecutions {
                    expectedRejection = StageBBatchPolicyError(
                        reason: .limitsExceeded,
                        callIndex: nil
                    )
                    authorized = []
                } else {
                    do {
                        authorized = try policy.authorizeBatch(
                            calls,
                            previouslyUsedIDs: state.usedToolCallIDs
                        )
                        expectedRejection = nil
                    } catch let rejection as StageBBatchPolicyError {
                        expectedRejection = rejection
                        authorized = []
                    } catch {
                        return .reconciliationRequired
                    }
                }
                if let rejection = expectedRejection {
                    guard zip(calls, executorPairs).allSatisfy({ call, pair in
                        validExecutorPair(pair, for: call)
                            && pair.terminal.phase == .failed
                            && pair.terminal.category == .policyNotExecuted
                            && pair.terminal.policyRejection == StageBPolicyRejectionEvidence(
                                reason: rejection.reason,
                                callIndex: rejection.callIndex
                            )
                            && pair.terminal.resultSHA256 == ProviderDigest.sha256Hex(
                                rejection.reason.rawValue
                            )
                    }) else {
                        return .reconciliationRequired
                    }
                    state.unresolvedPolicyRejection = true
                    let feedback = boundedPolicyFeedback(rejection)
                    state.lastExchange = [assistant] + calls.map {
                        ProviderTurnMessage(role: .tool, content: feedback, toolCallID: $0.id)
                    }
                    let assistantBinding = nextProvider == pairs.endIndex
                        ? StageBProviderMessageBinding.make(assistant)
                        : StageBProviderMessageBinding(
                            contentByteCount: outcome.assistantContentByteCount,
                            contentSHA256: outcome.assistantContentSHA256
                        )
                    state.lastExchangeBindings = [assistantBinding]
                        + state.lastExchange.dropFirst().map(StageBProviderMessageBinding.make)
                    guard let policyHistory = requestCanonicalizer.appendingPolicyRejection(
                        rejection,
                        calls: calls,
                        feedback: feedback,
                        to: state.historyBindingSHA256
                    ) else {
                        return .reconciliationRequired
                    }
                    state.historyBindingSHA256 = policyHistory
                } else {
                    guard authorized.count == calls.count else {
                        return .reconciliationRequired
                    }
                    var exchange = [assistant]
                    var exchangeBindings = [
                        nextProvider == pairs.endIndex
                            ? StageBProviderMessageBinding.make(assistant)
                            : StageBProviderMessageBinding(
                                contentByteCount: outcome.assistantContentByteCount,
                                contentSHA256: outcome.assistantContentSHA256
                            )
                    ]
                    for ((call, authorizedCall), pair) in zip(zip(calls, authorized), executorPairs) {
                        guard validExecutorPair(pair, for: call),
                              authorizedCall.toolCallID == call.id else {
                            return .reconciliationRequired
                        }
                        state.toolExecutionCount += 1
                        if pair.terminal.phase == .failed {
                            guard pair.terminal.category == .executorFailure,
                                  pair.intent.operationID == executorPairs.last?.intent.operationID,
                                  nextProvider == pairs.endIndex else {
                                return .reconciliationRequired
                            }
                            return .failure(.executorFailure)
                        }
                        guard pair.terminal.phase == .succeeded,
                              pair.terminal.category == .observation,
                              let observation = pair.terminal.observation,
                              validObservation(observation, for: authorizedCall.tool),
                              let feedback = restoredObservationFeedback(observation) else {
                            return .reconciliationRequired
                        }
                        state.observations.append(observation)
                        exchange.append(ProviderTurnMessage(
                            role: .tool,
                            content: feedback,
                            toolCallID: call.id
                        ))
                        if nextProvider == pairs.endIndex {
                            exchangeBindings.append(StageBProviderMessageBinding.make(exchange.last!))
                        } else {
                            guard let byteCount = pair.terminal.resultByteCount,
                                  let sha256 = pair.terminal.resultSHA256 else {
                                return .reconciliationRequired
                            }
                            exchangeBindings.append(StageBProviderMessageBinding(
                                contentByteCount: byteCount,
                                contentSHA256: sha256
                            ))
                        }
                        guard let observationHistory = requestCanonicalizer.appendingObservation(
                            observation,
                            toolCallID: call.id,
                            to: state.historyBindingSHA256
                        ) else {
                            return .reconciliationRequired
                        }
                        state.historyBindingSHA256 = observationHistory
                    }
                    state.unresolvedPolicyRejection = false
                    state.lastExchange = exchange
                    state.lastExchangeBindings = exchangeBindings
                }
                state.usedToolCallIDs.formUnion(calls.map(\.id))
            }
            cursor = nextProvider
        }
        return .state(state)
    }

    private func externalAttemptPairs(
        _ attempts: [StageBAttemptEvidence]
    ) -> [ExternalAttemptPair]? {
        let indexed = attempts.enumerated().compactMap { index, evidence in
            evidence.kind == .provider || evidence.kind == .executor
                ? (index: index, evidence: evidence)
                : nil
        }
        let groups = Dictionary(grouping: indexed, by: { $0.evidence.operationID })
        var pairs: [ExternalAttemptPair] = []
        for records in groups.values {
            let ordered = records.sorted { $0.index < $1.index }
            guard ordered.count == 2 else { return nil }
            let intent = ordered[0].evidence
            let terminal = ordered[1].evidence
            guard intent.phase == .intentRecorded,
                  intent.category == .none,
                  intent.resultByteCount == nil,
                  intent.resultSHA256 == nil,
                  intent.observation == nil,
                  intent.providerOutcome == nil,
                  intent.policyRejection == nil,
                  terminal.phase != .intentRecorded,
                  terminal.sessionID == intent.sessionID,
                  terminal.operationID == intent.operationID,
                  terminal.attemptID == intent.attemptID,
                  terminal.kind == intent.kind,
                  terminal.toolName == intent.toolName,
                  terminal.toolCallIDHash == intent.toolCallIDHash,
                  terminal.inputSHA256 == intent.inputSHA256 else {
                return nil
            }
            pairs.append(ExternalAttemptPair(
                intentIndex: ordered[0].index,
                terminalIndex: ordered[1].index,
                intent: intent,
                terminal: terminal
            ))
        }
        let orderedPairs = pairs.sorted { $0.intentIndex < $1.intentIndex }
        guard Set(orderedPairs.map { $0.intent.attemptID }).count == orderedPairs.count else {
            return nil
        }
        for pair in orderedPairs {
            switch (pair.intent.kind, pair.terminal.phase, pair.terminal.category) {
            case (.provider, .succeeded, .providerToolCalls),
                 (.provider, .succeeded, .providerFinish):
                guard pair.terminal.observation == nil,
                      pair.terminal.policyRejection == nil else { return nil }
            case (.provider, .failed, .providerFailure),
                 (.provider, .reconciliationRequired, .providerUnknown):
                guard pair.terminal.observation == nil,
                      pair.terminal.providerOutcome == nil,
                      pair.terminal.policyRejection == nil else { return nil }
            case (.executor, .succeeded, .observation):
                guard pair.terminal.providerOutcome == nil,
                      pair.terminal.policyRejection == nil else { return nil }
            case (.executor, .failed, .policyNotExecuted):
                guard pair.terminal.observation == nil,
                      pair.terminal.providerOutcome == nil else { return nil }
            case (.executor, .failed, .executorFailure),
                 (.executor, .reconciliationRequired, .executorUnknown):
                guard pair.terminal.observation == nil,
                      pair.terminal.providerOutcome == nil,
                      pair.terminal.policyRejection == nil else { return nil }
            default:
                return nil
            }
        }
        return orderedPairs
    }

    private func validExecutorPair(
        _ pair: ExternalAttemptPair,
        for call: ProviderTurnToolCall
    ) -> Bool {
        pair.intent.kind == .executor
            && pair.intent.toolName == StageBToolName(rawValue: call.name)
            && pair.intent.toolCallIDHash == ProviderDigest.sha256Hex(call.id)
            && pair.intent.inputSHA256 == ProviderDigest.sha256Hex(
                "tool-request\u{0}\(call.name)\u{0}\(ProviderDigest.sha256Hex(call.arguments))"
            )
    }

    private func validObservation(
        _ observation: StageBObservationEvidence,
        for tool: StageBAuthorizedTool
    ) -> Bool {
        guard observation.tool == tool.name,
              observation.relativePath == tool.relativePath,
              observation.querySHA256 == tool.query.map(ProviderDigest.sha256Hex),
              observation.ruleSetSHA256 == tool.ruleSetSHA256,
              observation.executorFacts.completionBarrierSatisfied,
              observation.executorFacts.exitedSuccessfully,
              !observation.executorFacts.truncated else {
            return false
        }
        switch tool.name {
        case .list:
            return observation.listedEntries != nil
                && observation.matches == nil
                && observation.readContentSHA256 == nil
        case .search:
            return observation.listedEntries == nil
                && observation.matches != nil
                && observation.readContentSHA256 == nil
        case .read:
            return observation.listedEntries == nil
                && observation.matches == nil
                && observation.readContentSHA256 != nil
                && observation.readContentByteCount != nil
        }
    }

    private func executeToolBatch(
        session: StageBSessionRecord,
        assistant: ProviderTurnMessage,
        calls: [ProviderTurnToolCall],
        state initial: LoopState
    ) async -> ToolBatchResult {
        var state = initial
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
            )) else { return .outcome(.reconciliationRequired) }
        }
        let authorized: [StageBAuthorizedToolCall]
        if state.toolExecutionCount + calls.count > limits.maximumToolExecutions {
            let rejection = StageBBatchPolicyError(reason: .limitsExceeded, callIndex: nil)
            state.unresolvedPolicyRejection = true
            guard await recordNotExecutedBatch(
                sessionID: session.id,
                pending: pending,
                rejection: rejection
            ) else { return .outcome(await fail(session, .evidenceUnavailable)) }
            let feedback = boundedPolicyFeedback(rejection)
            state.lastExchange = [assistant] + calls.map {
                ProviderTurnMessage(role: .tool, content: feedback, toolCallID: $0.id)
            }
            state.lastExchangeBindings = state.lastExchange.map(
                StageBProviderMessageBinding.make
            )
            guard let history = requestCanonicalizer.appendingPolicyRejection(
                rejection,
                calls: calls,
                feedback: feedback,
                to: state.historyBindingSHA256
            ) else { return .outcome(.reconciliationRequired) }
            state.historyBindingSHA256 = history
            state.usedToolCallIDs.formUnion(calls.map(\.id))
            return .state(state)
        }
        do {
            authorized = try policy.authorizeBatch(
                calls,
                previouslyUsedIDs: state.usedToolCallIDs
            )
        } catch let rejection as StageBBatchPolicyError {
            state.unresolvedPolicyRejection = true
            guard await recordNotExecutedBatch(
                sessionID: session.id,
                pending: pending,
                rejection: rejection
            ) else { return .outcome(await fail(session, .evidenceUnavailable)) }
            let feedback = boundedPolicyFeedback(rejection)
            state.lastExchange = [assistant] + calls.map {
                ProviderTurnMessage(role: .tool, content: feedback, toolCallID: $0.id)
            }
            state.lastExchangeBindings = state.lastExchange.map(
                StageBProviderMessageBinding.make
            )
            guard let history = requestCanonicalizer.appendingPolicyRejection(
                rejection,
                calls: calls,
                feedback: feedback,
                to: state.historyBindingSHA256
            ) else { return .outcome(.reconciliationRequired) }
            state.historyBindingSHA256 = history
            state.usedToolCallIDs.formUnion(calls.map(\.id))
            return .state(state)
        } catch {
            return .outcome(await fail(session, .invalidArguments))
        }

        guard authorized.count == pending.count else {
            return .outcome(.reconciliationRequired)
        }
        state.unresolvedPolicyRejection = false
        state.usedToolCallIDs.formUnion(authorized.map(\.toolCallID))
        var exchange = [assistant]
        var exchangeBindings = [StageBProviderMessageBinding.make(assistant)]
        for (call, request) in zip(authorized, pending) {
            state.toolExecutionCount += 1
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
                    if recorded {
                        return .outcome(await fail(session, .executorFailure))
                    }
                    return .outcome(.reconciliationRequired)
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
                    if recorded {
                        return .outcome(await fail(session, .executorFailure))
                    }
                    return .outcome(.reconciliationRequired)
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
                )) else { return .outcome(.reconciliationRequired) }
                state.observations.append(observationEvidence)
                exchange.append(ProviderTurnMessage(
                    role: .tool,
                    content: modelContent,
                    toolCallID: call.toolCallID
                ))
                exchangeBindings.append(StageBProviderMessageBinding.make(exchange.last!))
                guard let history = requestCanonicalizer.appendingObservation(
                    observationEvidence,
                    toolCallID: call.toolCallID,
                    to: state.historyBindingSHA256
                ) else { return .outcome(.reconciliationRequired) }
                state.historyBindingSHA256 = history
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
                if recorded {
                    return .outcome(await fail(session, .executorFailure))
                }
                return .outcome(.reconciliationRequired)
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
                return .outcome(.reconciliationRequired)
            }
        }
        state.lastExchange = exchange
        state.lastExchangeBindings = exchangeBindings
        return .state(state)
    }

    private func restoredObservationFeedback(_ observation: StageBObservationEvidence) -> String? {
        var value: [String: Any] = [
            "status": "succeeded",
            "tool": observation.tool.rawValue,
            "path": observation.relativePath,
            "rules_sha256": observation.ruleSetSHA256,
            "observation_sha256": observation.observationSHA256
        ]
        if let entries = observation.listedEntries {
            value["entry_count"] = entries.count
        }
        if let matches = observation.matches {
            value["match_count"] = matches.count
            if matches.count == 1 {
                value["match"] = [
                    "path": matches[0].path,
                    "line": matches[0].line,
                    "text_sha256": matches[0].textSHA256,
                    "exact_query_occurrences": matches[0].exactQueryOccurrences
                ]
            }
        }
        if let count = observation.readContentByteCount {
            value["read_content_bytes"] = count
        }
        if let hash = observation.readContentSHA256 {
            value["read_content_sha256"] = hash
        }
        if let occurrences = observation.exactQueryOccurrences {
            value["exact_query_occurrences"] = occurrences
        }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              data.count <= limits.maximumModelObservationBytes,
              data.count <= ProviderLimits.maximumTurnMessageBytes else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func completionRejectedExchange(
        assistant: ProviderTurnMessage
    ) -> [ProviderTurnMessage] {
        [
            assistant,
            ProviderTurnMessage(
                role: .user,
                content: "Completion rejected by the Swift Harness because the bound list, exact search, read, rule, or reconciliation evidence is incomplete. Continue with allowed typed tools."
            )
        ]
    }

    private func providerOutcomeEvidence(
        _ decision: ProviderInferenceDecision
    ) -> StageBProviderOutcomeEvidence {
        switch decision {
        case let .toolCalls(assistant, calls):
            return StageBProviderOutcomeEvidence(
                assistantContentByteCount: assistant.content?.utf8.count ?? 0,
                assistantContentSHA256: assistant.content.map(ProviderDigest.sha256Hex),
                toolCalls: calls
            )
        case let .finish(assistant):
            return StageBProviderOutcomeEvidence(
                assistantContentByteCount: assistant.content?.utf8.count ?? 0,
                assistantContentSHA256: assistant.content.map(ProviderDigest.sha256Hex),
                toolCalls: []
            )
        }
    }

    private func requireReconciliation(
        _ session: StageBSessionRecord
    ) async -> StageBLoopOutcome {
        _ = try? await sessionStore.transition(
            session,
            to: .reconciliationRequired,
            diagnostic: "external_attempt_requires_reconciliation",
            now: now()
        )
        return .reconciliationRequired
    }

    private func establishCompletion(
        session: StageBSessionRecord,
        verified: StageBCompletionVerifier.Verified,
        observations: [StageBObservationEvidence],
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
        guard let pairs = externalAttemptPairs(attempts) else { return true }
        return pairs.contains { $0.terminal.phase == .reconciliationRequired }
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
        guard !hasUnresolvedExternalAttempt(attempts) else { return false }
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
                observation: nil,
                policyRejection: StageBPolicyRejectionEvidence(
                    reason: rejection.reason,
                    callIndex: rejection.callIndex
                )
            )
            guard await record(terminal) else { return false }
        }
        return true
    }

    private func boundedPolicyFeedback(_ rejection: StageBBatchPolicyError) -> String {
        StageBProviderRequestCanonicalizer.boundedPolicyFeedback(rejection)
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
        observation: StageBObservationEvidence? = nil,
        providerOutcome: StageBProviderOutcomeEvidence? = nil,
        policyRejection: StageBPolicyRejectionEvidence? = nil
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
            observation: observation,
            providerOutcome: providerOutcome,
            policyRejection: policyRejection
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
        observations: [StageBObservationEvidence],
        session: StageBSessionRecord,
        ruleSet: StageBRuleSet
    ) -> Verified? {
        guard session.ruleSetBindingSHA256 == ruleSet.bindingSHA256 else { return nil }
        let query = session.goal.exactQuery
        for listIndex in observations.indices {
            let list = observations[listIndex]
            guard list.tool == .list,
                  list.executorFacts.completionBarrierSatisfied,
                  list.executorFacts.exitedSuccessfully,
                  !list.executorFacts.truncated,
                  let entries = list.listedEntries else { continue }
            for searchIndex in observations.indices where searchIndex > listIndex {
                let search = observations[searchIndex]
                guard search.tool == .search,
                      search.querySHA256 == ProviderDigest.sha256Hex(query),
                      search.executorFacts.completionBarrierSatisfied,
                      search.executorFacts.exitedSuccessfully,
                      !search.executorFacts.truncated,
                      let matches = search.matches,
                      matches.count == 1,
                      matches[0].exactQueryOccurrences > 0 else { continue }
                let match = matches[0]
                guard session.goal.expectedRelativePath.map({ $0 == match.path }) ?? true,
                      listCovers(path: match.path, listPath: list.relativePath, entries: entries) else {
                    continue
                }
                for readIndex in observations.indices where readIndex > searchIndex {
                    let read = observations[readIndex]
                    guard read.tool == .read,
                          read.relativePath == match.path,
                          read.executorFacts.completionBarrierSatisfied,
                          read.executorFacts.exitedSuccessfully,
                          !read.executorFacts.truncated,
                          (read.exactQueryOccurrences ?? 0) > 0 else { continue }
                    let chain = [list, search, read]
                        .map(\.observationSHA256)
                        .joined(separator: "\n")
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
