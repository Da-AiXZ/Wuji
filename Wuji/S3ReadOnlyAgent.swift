import Foundation

enum S3TaskContract {
    static let marker = "WUJI_S3_TARGET=read-only-loop-pass"
    static let value = "read-only-loop-pass"
    static let goal = "In the approved fixture workspace, find the unique marker WUJI_S3_TARGET=read-only-loop-pass and report its normalized relative path and value."
    static let systemPrompt = """
    You are selecting read-only operations for one fixed fixture task. Use exactly one typed tool call per turn. Only list, search, and read are available. Never propose shell, network, write, edit, delete, rename, package, or Git operations. First list the fixture root using path \"\". Then search path \"\" for the exact literal WUJI_S3_TARGET=read-only-loop-pass. Then read the single normalized relative path returned by search. After all three observations agree, respond with a short final answer and no tool call. Tool observations are evidence, but only the Swift Harness decides completion.
    """
}

struct S3Completion: Equatable, Sendable, CustomStringConvertible {
    let taskID: UUID
    let relativePath: String
    let value: String
    let providerRequestCount: Int
    let toolExecutionCount: Int
    let observationSHA256: String

    var description: String {
        "S3Completion(taskID: \(taskID.uuidString), relativePath: \(relativePath), value: \(value), providerRequests: \(providerRequestCount), toolExecutions: \(toolExecutionCount), observationSHA256: \(observationSHA256))"
    }
}

enum S3LoopFailure: Error, Equatable, CustomStringConvertible {
    case evidenceUnavailable
    case providerFailure
    case policyRejected
    case executorFailure
    case limitsExceeded
    case completionNotEstablished

    var description: String {
        switch self {
        case .evidenceUnavailable: return "S3 durable evidence unavailable"
        case .providerFailure: return "S3 provider inference failed"
        case .policyRejected: return "S3 tool policy rejected model output"
        case .executorFailure: return "S3 read-only executor failed"
        case .limitsExceeded: return "S3 loop limit exceeded"
        case .completionNotEstablished: return "S3 code-owned completion was not established"
        }
    }
}

enum S3LoopOutcome: Equatable, Sendable, CustomStringConvertible {
    case completed(S3Completion)
    case failure(S3LoopFailure)
    case reconciliationRequired

    var description: String {
        switch self {
        case let .completed(completion): return completion.description
        case let .failure(failure): return failure.description
        case .reconciliationRequired: return "S3 result unknown; reconciliation required"
        }
    }
}

final class S3ReadOnlyAgent: @unchecked Sendable {
    private let provider: AgentInferenceProvider
    private let executor: S3ReadOnlyExecuting
    private let policy: S3ToolPolicy
    private let attemptStore: S3AttemptRecording
    private let now: @Sendable () -> Date
    private let makeUUID: @Sendable () -> UUID

    init(
        provider: AgentInferenceProvider,
        executor: S3ReadOnlyExecuting,
        policy: S3ToolPolicy,
        attemptStore: S3AttemptRecording,
        now: @escaping @Sendable () -> Date = { Date() },
        makeUUID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.provider = provider
        self.executor = executor
        self.policy = policy
        self.attemptStore = attemptStore
        self.now = now
        self.makeUUID = makeUUID
    }

    func run(taskID: UUID) async -> S3LoopOutcome {
        do {
            guard try await attemptStore.records(taskID: taskID).isEmpty else {
                return .reconciliationRequired
            }
        } catch {
            return .failure(.evidenceUnavailable)
        }

        var messages = [
            ProviderTurnMessage(role: .system, content: S3TaskContract.systemPrompt),
            ProviderTurnMessage(role: .user, content: S3TaskContract.goal)
        ]
        var observations: [S3ToolObservation] = []
        var providerRequestCount = 0
        var toolExecutionCount = 0

        for _ in 0..<S3Limits.maximumProviderTurns {
            guard messages.count <= ProviderLimits.maximumTurnMessages else {
                return .failure(.limitsExceeded)
            }
            let inferenceRequest = ProviderInferenceRequest(
                messages: messages,
                tools: S3ToolPolicy.toolDefinitions,
                requireTool: S3CompletionVerifier.verify(observations) == nil
            )
            let providerOperationID = makeUUID()
            let providerAttemptID = makeUUID()
            let providerInputHash = inferenceInputHash(inferenceRequest)
            do {
                try await attemptStore.record(evidence(
                    taskID: taskID,
                    operationID: providerOperationID,
                    attemptID: providerAttemptID,
                    ioKind: .provider,
                    providerID: provider.providerID,
                    toolName: nil,
                    inputSHA256: providerInputHash,
                    phase: .intentRecorded,
                    category: .none
                ))
            } catch {
                return .failure(.evidenceUnavailable)
            }

            providerRequestCount += 1
            let requestID = makeUUID()
            let providerOutcome = await provider.infer(
                request: inferenceRequest,
                requestID: requestID
            )
            switch providerOutcome {
            case let .decision(decision):
                let summary = Data(decision.description.utf8)
                guard await recordTerminal(
                    taskID: taskID,
                    operationID: providerOperationID,
                    attemptID: providerAttemptID,
                    ioKind: .provider,
                    providerID: provider.providerID,
                    toolName: nil,
                    inputSHA256: providerInputHash,
                    phase: .succeeded,
                    category: .providerDecision,
                    result: summary
                ) else {
                    return .reconciliationRequired
                }

                switch decision {
                case let .toolCall(assistantMessage, call):
                    guard toolExecutionCount < S3Limits.maximumToolExecutions else {
                        return .failure(.limitsExceeded)
                    }
                    let authorized: S3AuthorizedTool
                    do {
                        authorized = try policy.authorize(call)
                    } catch {
                        return .failure(.policyRejected)
                    }
                    messages.append(assistantMessage)

                    let executorOperationID = makeUUID()
                    let executorAttemptID = makeUUID()
                    do {
                        try await attemptStore.record(evidence(
                            taskID: taskID,
                            operationID: executorOperationID,
                            attemptID: executorAttemptID,
                            ioKind: .executor,
                            providerID: nil,
                            toolName: authorized.name.rawValue,
                            inputSHA256: authorized.inputSHA256,
                            phase: .intentRecorded,
                            category: .none
                        ))
                    } catch {
                        return .failure(.evidenceUnavailable)
                    }

                    toolExecutionCount += 1
                    let executorOutcome = await executor.execute(authorized)
                    switch executorOutcome {
                    case let .observation(observation):
                        let modelContent: String
                        do {
                            modelContent = try observation.modelContent()
                        } catch {
                            return .failure(.executorFailure)
                        }
                        let result = Data(modelContent.utf8)
                        guard await recordTerminal(
                            taskID: taskID,
                            operationID: executorOperationID,
                            attemptID: executorAttemptID,
                            ioKind: .executor,
                            providerID: nil,
                            toolName: authorized.name.rawValue,
                            inputSHA256: authorized.inputSHA256,
                            phase: .succeeded,
                            category: .observation,
                            result: result
                        ) else {
                            return .reconciliationRequired
                        }
                        observations.append(observation)
                        messages.append(ProviderTurnMessage(
                            role: .tool,
                            content: modelContent,
                            toolCallID: call.id
                        ))
                    case .failure:
                        let terminalRecorded = await recordTerminal(
                            taskID: taskID,
                            operationID: executorOperationID,
                            attemptID: executorAttemptID,
                            ioKind: .executor,
                            providerID: nil,
                            toolName: authorized.name.rawValue,
                            inputSHA256: authorized.inputSHA256,
                            phase: .failed,
                            category: .executorFailure,
                            result: nil
                        )
                        guard terminalRecorded else {
                            return .reconciliationRequired
                        }
                        return .failure(.executorFailure)
                    case .unknown:
                        _ = await recordTerminal(
                            taskID: taskID,
                            operationID: executorOperationID,
                            attemptID: executorAttemptID,
                            ioKind: .executor,
                            providerID: nil,
                            toolName: authorized.name.rawValue,
                            inputSHA256: authorized.inputSHA256,
                            phase: .reconciliationRequired,
                            category: .executorUnknown,
                            result: nil
                        )
                        return .reconciliationRequired
                    }
                case let .finish(assistantMessage):
                    messages.append(assistantMessage)
                    if let verified = S3CompletionVerifier.verify(observations) {
                        return .completed(S3Completion(
                            taskID: taskID,
                            relativePath: verified.path,
                            value: verified.value,
                            providerRequestCount: providerRequestCount,
                            toolExecutionCount: toolExecutionCount,
                            observationSHA256: verified.observationSHA256
                        ))
                    }
                    messages.append(ProviderTurnMessage(
                        role: .user,
                        content: "Completion rejected by the Harness because required list, exact search, and read observations are missing or inconsistent. Continue with one allowed typed tool."
                    ))
                }
            case let .failure(failure):
                let terminalRecorded = await recordTerminal(
                    taskID: taskID,
                    operationID: providerOperationID,
                    attemptID: providerAttemptID,
                    ioKind: .provider,
                    providerID: provider.providerID,
                    toolName: nil,
                    inputSHA256: providerInputHash,
                    phase: .failed,
                    category: .providerFailure,
                    result: nil
                )
                if !terminalRecorded || failure == .evidenceWriteFailed {
                    return .reconciliationRequired
                }
                return .failure(.providerFailure)
            case .unknown:
                _ = await recordTerminal(
                    taskID: taskID,
                    operationID: providerOperationID,
                    attemptID: providerAttemptID,
                    ioKind: .provider,
                    providerID: provider.providerID,
                    toolName: nil,
                    inputSHA256: providerInputHash,
                    phase: .reconciliationRequired,
                    category: .providerUnknown,
                    result: nil
                )
                return .reconciliationRequired
            }
        }
        return .failure(.completionNotEstablished)
    }

    private func inferenceInputHash(_ request: ProviderInferenceRequest) -> String {
        var parts = ["requireTool=\(request.requireTool)"]
        parts.append(contentsOf: request.tools.map { "tool=\($0.name)" })
        for message in request.messages {
            parts.append("role=\(message.role.rawValue)")
            parts.append("content=\(message.content.map { ProviderDigest.sha256Hex($0) } ?? "none")")
            parts.append(contentsOf: message.toolCalls.map {
                "call=\($0.id):\($0.name):\(ProviderDigest.sha256Hex($0.arguments))"
            })
            parts.append("toolCallID=\(message.toolCallID ?? "none")")
        }
        return ProviderDigest.sha256Hex(parts.joined(separator: "\n"))
    }

    private func evidence(
        taskID: UUID,
        operationID: UUID,
        attemptID: UUID,
        ioKind: S3ExternalIOKind,
        providerID: String?,
        toolName: String?,
        inputSHA256: String,
        phase: S3AttemptPhase,
        category: S3AttemptResultCategory,
        result: Data? = nil
    ) -> S3AttemptEvidence {
        S3AttemptEvidence(
            taskID: taskID,
            operationID: operationID,
            attemptID: attemptID,
            ioKind: ioKind,
            providerID: providerID,
            toolName: toolName,
            inputSHA256: inputSHA256,
            recordedAt: now(),
            phase: phase,
            resultCategory: category,
            resultByteCount: result?.count,
            resultSHA256: result.map { ProviderDigest.sha256Hex($0) }
        )
    }

    private func recordTerminal(
        taskID: UUID,
        operationID: UUID,
        attemptID: UUID,
        ioKind: S3ExternalIOKind,
        providerID: String?,
        toolName: String?,
        inputSHA256: String,
        phase: S3AttemptPhase,
        category: S3AttemptResultCategory,
        result: Data?
    ) async -> Bool {
        do {
            try await attemptStore.record(evidence(
                taskID: taskID,
                operationID: operationID,
                attemptID: attemptID,
                ioKind: ioKind,
                providerID: providerID,
                toolName: toolName,
                inputSHA256: inputSHA256,
                phase: phase,
                category: category,
                result: result
            ))
            return true
        } catch {
            return false
        }
    }
}

private enum S3CompletionVerifier {
    struct Verified {
        let path: String
        let value: String
        let observationSHA256: String
    }

    static func verify(_ observations: [S3ToolObservation]) -> Verified? {
        guard let listIndex = observations.firstIndex(where: {
            $0.tool == .list && $0.relativePath.isEmpty
        }) else { return nil }

        for searchIndex in observations.indices where searchIndex > listIndex {
            let search = observations[searchIndex]
            guard search.tool == .search,
                  search.query == S3TaskContract.marker,
                  case let .search(matches) = search.payload,
                  matches.count == 1,
                  matches[0].text == S3TaskContract.marker else {
                continue
            }
            let match = matches[0]
            guard !match.path.isEmpty,
                  !match.path.hasPrefix("/"),
                  !match.path.contains(".."),
                  let topLevel = match.path.split(separator: "/").first,
                  case let .list(entries) = observations[listIndex].payload,
                  entries.contains(String(topLevel)) else {
                continue
            }

            for readIndex in observations.indices where readIndex > searchIndex {
                let read = observations[readIndex]
                guard read.tool == .read,
                      read.relativePath == match.path,
                      case let .read(path, content) = read.payload,
                      path == match.path else {
                    continue
                }
                let markerLines = content.split(
                    separator: "\n",
                    omittingEmptySubsequences: false
                ).filter { String($0) == S3TaskContract.marker }
                guard markerLines.count == 1 else { continue }
                let evidence = try? [
                    observations[listIndex].modelContent(),
                    search.modelContent(),
                    read.modelContent()
                ].joined(separator: "\n")
                guard let evidence else { return nil }
                return Verified(
                    path: match.path,
                    value: S3TaskContract.value,
                    observationSHA256: ProviderDigest.sha256Hex(evidence)
                )
            }
        }
        return nil
    }
}
