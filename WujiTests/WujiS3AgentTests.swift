import Foundation
import XCTest
@testable import Wuji

final class WujiS3AgentTests: XCTestCase {
    private var workspaceRoot: URL!
    private var outsideRoot: URL!

    override func setUpWithError() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("WujiS3AgentTests-\(UUID().uuidString)", isDirectory: true)
        workspaceRoot = temporary.appendingPathComponent("fixture", isDirectory: true)
        outsideRoot = temporary.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspaceRoot.appendingPathComponent("records", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        try Data("guide\n".utf8).write(to: workspaceRoot.appendingPathComponent("guide.txt"))
        try Data("header\n\(S3TaskContract.marker)\nfooter\n".utf8).write(
            to: workspaceRoot.appendingPathComponent("records/target.txt")
        )
        try Data("outside\n".utf8).write(to: outsideRoot.appendingPathComponent("secret.txt"))
    }

    override func tearDownWithError() throws {
        if let parent = workspaceRoot?.deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: parent)
        }
    }

    func testThreeToolLoopCompletesOnlyFromConsistentObservations() async throws {
        let events = S3EventRecorder()
        let provider = S3ScriptedProvider(
            outcomes: [
                toolDecision(id: "call-list", name: "list", arguments: ["path": ""]),
                toolDecision(id: "call-search", name: "search", arguments: [
                    "path": "",
                    "query": S3TaskContract.marker
                ]),
                toolDecision(id: "call-read", name: "read", arguments: [
                    "path": "records/target.txt"
                ]),
                .decision(.finish(ProviderTurnMessage(role: .assistant, content: "finished")))
            ],
            events: events
        )
        let executor = S3MockExecutor(events: events)
        let store = S3RecordingAttemptStore(events: events)
        let agent = try makeAgent(provider: provider, executor: executor, store: store)
        let taskID = UUID()

        let outcome = await agent.run(taskID: taskID)

        guard case let .completed(completion) = outcome else {
            return XCTFail("expected code-owned completion, got \(outcome)")
        }
        XCTAssertEqual(completion.relativePath, "records/target.txt")
        XCTAssertEqual(completion.value, S3TaskContract.value)
        XCTAssertEqual(completion.providerRequestCount, 4)
        XCTAssertEqual(completion.toolExecutionCount, 3)
        let providerCalls = await provider.callCount
        let executorCalls = await executor.callCount
        XCTAssertEqual(providerCalls, 4)
        XCTAssertEqual(executorCalls, 3)

        let values = await events.values
        for index in values.indices where values[index].hasPrefix("io:") {
            XCTAssertGreaterThan(index, 0)
            XCTAssertEqual(values[index - 1], "intent:\(values[index].dropFirst(3))")
        }
        let records = await store.storedRecords
        XCTAssertEqual(records.filter { $0.ioKind == .provider }.count, 8)
        XCTAssertEqual(records.filter { $0.ioKind == .executor }.count, 6)
        XCTAssertFalse(String(describing: records).contains(S3TaskContract.marker))
    }

    func testTwoAndThreeCallBatchesExecuteSeriallyWithIndependentEvidenceAndIDHistory() async throws {
        for batchSize in [2, 3] {
            let calls = [
                call(id: "batch-list", name: "list", arguments: ["path": ""]),
                call(id: "batch-search", name: "search", arguments: [
                    "path": "",
                    "query": S3TaskContract.marker
                ]),
                call(id: "batch-read", name: "read", arguments: [
                    "path": "records/target.txt"
                ])
            ]
            var outcomes = [batchDecision(Array(calls.prefix(batchSize)))]
            if batchSize == 2 {
                outcomes.append(batchDecision([calls[2]]))
            }
            outcomes.append(.decision(.finish(
                ProviderTurnMessage(role: .assistant, content: "finished")
            )))
            let events = S3EventRecorder()
            let provider = S3ScriptedProvider(outcomes: outcomes, events: events)
            let executor = S3MockExecutor(events: events)
            let store = S3RecordingAttemptStore(events: events)
            let agent = try makeAgent(provider: provider, executor: executor, store: store)

            let outcome = await agent.run(taskID: UUID())

            guard case let .completed(completion) = outcome else {
                return XCTFail("expected completion for batch size \(batchSize), got \(outcome)")
            }
            XCTAssertEqual(completion.toolExecutionCount, 3)
            let executed = await executor.executedTools
            XCTAssertEqual(executed.map(\.name), [.list, .search, .read])

            let records = await store.storedRecords
            let executorRecords = records.filter { $0.ioKind == .executor }
            XCTAssertEqual(executorRecords.count, 6)
            let operations = Dictionary(grouping: executorRecords, by: \.operationID)
            XCTAssertEqual(operations.count, 3)
            XCTAssertEqual(Set(executorRecords.map(\.attemptID)).count, 3)
            XCTAssertEqual(
                executorRecords.filter { $0.phase == .intentRecorded }.compactMap(\.toolName),
                ["list", "search", "read"]
            )
            for operation in operations.values {
                XCTAssertEqual(operation.map(\.phase), [.intentRecorded, .succeeded])
                XCTAssertEqual(Set(operation.map(\.attemptID)).count, 1)
            }

            let requests = await provider.requests
            guard requests.count >= 2 else {
                return XCTFail("expected a follow-up Provider request")
            }
            let followUp = requests[1].messages
            let assistant = try XCTUnwrap(followUp.last(where: { $0.role == .assistant }))
            XCTAssertEqual(assistant.toolCalls.map(\.id), Array(calls.prefix(batchSize)).map(\.id))
            let pairedIDs = followUp.filter { $0.role == .tool }.compactMap(\.toolCallID)
            XCTAssertEqual(pairedIDs, Array(calls.prefix(batchSize)).map(\.id))

            let values = await events.values
            for index in values.indices where values[index] == "io:executor" {
                XCTAssertGreaterThan(index, 0)
                XCTAssertEqual(values[index - 1], "intent:executor")
            }
        }
    }

    func testInvalidBatchMemberOrExcessCountRejectsWholeBatchBeforeExecutor() async throws {
        let valid = call(id: "valid-list", name: "list", arguments: ["path": ""])
        let link = workspaceRoot.appendingPathComponent("batch-escape")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: outsideRoot.appendingPathComponent("secret.txt")
        )
        let invalidBatches: [[ProviderTurnToolCall]] = [
            [valid, call(id: "bad-name", name: "network", arguments: ["path": ""])],
            [valid, ProviderTurnToolCall(id: "bad-json", name: "read", arguments: "not-json")],
            [valid, call(id: "bad-path", name: "read", arguments: ["path": "../outside/secret.txt"])],
            [valid, call(id: "bad-symlink", name: "read", arguments: ["path": "batch-escape"])],
            [valid, call(id: "", name: "read", arguments: ["path": "records/target.txt"])],
            [valid, call(id: valid.id, name: "read", arguments: ["path": "records/target.txt"])],
            [
                valid,
                call(id: "extra-1", name: "list", arguments: ["path": ""]),
                call(id: "extra-2", name: "list", arguments: ["path": ""]),
                call(id: "extra-3", name: "list", arguments: ["path": ""])
            ]
        ]

        for batch in invalidBatches {
            let provider = S3ScriptedProvider(outcomes: [batchDecision(batch)])
            let executor = S3MockExecutor()
            let agent = try makeAgent(
                provider: provider,
                executor: executor,
                store: S3RecordingAttemptStore()
            )

            let outcome = await agent.run(taskID: UUID())

            XCTAssertEqual(outcome, .failure(.policyRejected))
            let executorCalls = await executor.callCount
            XCTAssertEqual(executorCalls, 0)
        }
    }

    func testSecondCallUnknownStopsThirdCallAndRequiresReconciliation() async throws {
        let calls = [
            call(id: "unknown-list", name: "list", arguments: ["path": ""]),
            call(id: "unknown-search", name: "search", arguments: [
                "path": "",
                "query": S3TaskContract.marker
            ]),
            call(id: "never-read", name: "read", arguments: [
                "path": "records/target.txt"
            ])
        ]
        let provider = S3ScriptedProvider(outcomes: [batchDecision(calls)])
        let executor = S3MockExecutor(mode: .unknownAt(2))
        let store = S3RecordingAttemptStore()
        let agent = try makeAgent(provider: provider, executor: executor, store: store)

        let outcome = await agent.run(taskID: UUID())

        XCTAssertEqual(outcome, .reconciliationRequired)
        let providerCalls = await provider.callCount
        let executorCalls = await executor.callCount
        let executed = await executor.executedTools
        XCTAssertEqual(providerCalls, 1)
        XCTAssertEqual(executorCalls, 2)
        XCTAssertEqual(executed.map(\.name), [.list, .search])
        let storedRecords = await store.storedRecords
        let executorRecords = storedRecords.filter { $0.ioKind == .executor }
        XCTAssertEqual(executorRecords.map(\.phase), [
            .intentRecorded, .succeeded, .intentRecorded, .reconciliationRequired
        ])
    }

    func testIDReusedByLaterBatchIsRejectedBeforeThatBatchExecutes() async throws {
        let reusedID = "reused-across-batches"
        let provider = S3ScriptedProvider(outcomes: [
            toolDecision(id: reusedID, name: "list", arguments: ["path": ""]),
            batchDecision([
                call(id: reusedID, name: "search", arguments: [
                    "path": "",
                    "query": S3TaskContract.marker
                ]),
                call(id: "new-read", name: "read", arguments: [
                    "path": "records/target.txt"
                ])
            ])
        ])
        let executor = S3MockExecutor()
        let agent = try makeAgent(
            provider: provider,
            executor: executor,
            store: S3RecordingAttemptStore()
        )

        let outcome = await agent.run(taskID: UUID())

        XCTAssertEqual(outcome, .failure(.policyRejected))
        let providerCalls = await provider.callCount
        let executorCalls = await executor.callCount
        XCTAssertEqual(providerCalls, 2)
        XCTAssertEqual(executorCalls, 1)
    }

    func testUnknownWriteShellAndNetworkToolsFailClosedBeforeExecutor() async throws {
        for name in ["unknown", "write", "shell", "network", "delete"] {
            let provider = S3ScriptedProvider(outcomes: [
                toolDecision(id: "call-\(name)", name: name, arguments: ["path": ""])
            ])
            let executor = S3MockExecutor()
            let agent = try makeAgent(
                provider: provider,
                executor: executor,
                store: S3RecordingAttemptStore()
            )

            let outcome = await agent.run(taskID: UUID())
            let executorCalls = await executor.callCount
            XCTAssertEqual(outcome, .failure(.policyRejected), name)
            XCTAssertEqual(executorCalls, 0, name)
        }
    }

    func testAbsoluteTraversalEncodedAndSymlinkEscapeAreRejected() throws {
        let policy = S3ToolPolicy(workspace: try S3ApprovedWorkspace(rootURL: workspaceRoot))
        for path in [
            "/etc/passwd",
            "../outside/secret.txt",
            "records/../../outside/secret.txt",
            "%2e%2e/outside/secret.txt",
            "records\\target.txt",
            "C:/outside/secret.txt"
        ] {
            XCTAssertThrowsError(try policy.authorize(call(
                id: "bad-path",
                name: "read",
                arguments: ["path": path]
            )), path)
        }

        let link = workspaceRoot.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: outsideRoot.appendingPathComponent("secret.txt")
        )
        XCTAssertThrowsError(try policy.authorize(call(
            id: "symlink",
            name: "read",
            arguments: ["path": "escape"]
        ))) { error in
            XCTAssertEqual(error as? S3PolicyError, .symlinkEscape)
        }
        XCTAssertThrowsError(try policy.authorize(call(
            id: "search-root",
            name: "search",
            arguments: ["path": "", "query": S3TaskContract.marker]
        ))) { error in
            XCTAssertEqual(error as? S3PolicyError, .symlinkEscape)
        }
    }

    func testEntryMatchReadLineAndTotalCapsAreIndependent() throws {
        XCTAssertThrowsError(try observation(
            tool: .list,
            payload: .list(entries: (0...S3Limits.maximumEntries).map { "entry-\($0)" })
        ).modelContent())
        XCTAssertThrowsError(try observation(
            tool: .search,
            query: S3TaskContract.marker,
            payload: .search(matches: (0...S3Limits.maximumMatches).map {
                S3SearchMatch(path: "records/target.txt", line: $0 + 1, text: "match")
            })
        ).modelContent())
        XCTAssertThrowsError(try observation(
            tool: .read,
            path: "records/target.txt",
            payload: .read(
                path: "records/target.txt",
                content: String(repeating: "x", count: S3Limits.maximumReadBytes + 1)
            )
        ).modelContent())
        XCTAssertThrowsError(try observation(
            tool: .read,
            path: "records/target.txt",
            payload: .read(
                path: "records/target.txt",
                content: String(repeating: "x", count: S3Limits.maximumLineBytes + 1)
            )
        ).modelContent())
        var oversizedFacts = facts()
        oversizedFacts = S3ExecutorFacts(
            rootExitObserved: oversizedFacts.rootExitObserved,
            stdoutEOFObserved: oversizedFacts.stdoutEOFObserved,
            stderrEOFObserved: oversizedFacts.stderrEOFObserved,
            finalState: oversizedFacts.finalState,
            stdoutByteCount: S3Limits.executorStreamBytes + 1,
            stderrByteCount: 0,
            stdoutSHA256: oversizedFacts.stdoutSHA256,
            stderrSHA256: oversizedFacts.stderrSHA256,
            truncated: false
        )
        XCTAssertThrowsError(try S3ToolObservation(
            tool: .read,
            relativePath: "records/target.txt",
            query: nil,
            payload: .read(path: "records/target.txt", content: "ok"),
            facts: oversizedFacts
        ).modelContent())
    }

    func testProviderAndExecutorUnknownNeverRetry() async throws {
        let providerUnknown = S3ScriptedProvider(outcomes: [
            .unknown(.reconciliationRequired)
        ])
        let unusedExecutor = S3MockExecutor()
        let providerAgent = try makeAgent(
            provider: providerUnknown,
            executor: unusedExecutor,
            store: S3RecordingAttemptStore()
        )
        let providerOutcome = await providerAgent.run(taskID: UUID())
        let providerUnknownCalls = await providerUnknown.callCount
        let unusedExecutorCalls = await unusedExecutor.callCount
        XCTAssertEqual(providerOutcome, .reconciliationRequired)
        XCTAssertEqual(providerUnknownCalls, 1)
        XCTAssertEqual(unusedExecutorCalls, 0)

        let provider = S3ScriptedProvider(outcomes: [
            toolDecision(id: "call-list", name: "list", arguments: ["path": ""])
        ])
        let executorUnknown = S3MockExecutor(mode: .unknown)
        let executorAgent = try makeAgent(
            provider: provider,
            executor: executorUnknown,
            store: S3RecordingAttemptStore()
        )
        let executorOutcome = await executorAgent.run(taskID: UUID())
        let providerCalls = await provider.callCount
        let executorUnknownCalls = await executorUnknown.callCount
        XCTAssertEqual(executorOutcome, .reconciliationRequired)
        XCTAssertEqual(providerCalls, 1)
        XCTAssertEqual(executorUnknownCalls, 1)
    }

    func testExecutorTerminalEvidenceFailureRequiresReconciliation() async throws {
        let provider = S3ScriptedProvider(outcomes: [batchDecision([
            call(id: "call-list", name: "list", arguments: ["path": ""]),
            call(id: "call-search", name: "search", arguments: [
                "path": "",
                "query": S3TaskContract.marker
            ]),
            call(id: "call-read", name: "read", arguments: [
                "path": "records/target.txt"
            ])
        ])])
        let executor = S3MockExecutor()
        let store = S3RecordingAttemptStore(failOnRecordNumber: 4)
        let agent = try makeAgent(provider: provider, executor: executor, store: store)

        let outcome = await agent.run(taskID: UUID())
        let providerCalls = await provider.callCount
        let executorCalls = await executor.callCount
        XCTAssertEqual(outcome, .reconciliationRequired)
        XCTAssertEqual(providerCalls, 1)
        XCTAssertEqual(executorCalls, 1)
    }

    func testExistingDurableStateStopsRecoveryBeforeExternalIO() async throws {
        let taskID = UUID()
        let store = S3RecordingAttemptStore(initial: [S3AttemptEvidence(
            taskID: taskID,
            operationID: UUID(),
            attemptID: UUID(),
            ioKind: .provider,
            providerID: "deepseek",
            toolName: nil,
            inputSHA256: String(repeating: "a", count: 64),
            recordedAt: Date(timeIntervalSince1970: 1),
            phase: .intentRecorded,
            resultCategory: .none,
            resultByteCount: nil,
            resultSHA256: nil
        )])
        let provider = S3ScriptedProvider(outcomes: [])
        let executor = S3MockExecutor()
        let agent = try makeAgent(provider: provider, executor: executor, store: store)

        let outcome = await agent.run(taskID: taskID)
        let providerCalls = await provider.callCount
        let executorCalls = await executor.callCount
        XCTAssertEqual(outcome, .reconciliationRequired)
        XCTAssertEqual(providerCalls, 0)
        XCTAssertEqual(executorCalls, 0)
    }

    func testModelFinishCannotBypassCodeOwnedCompletion() async throws {
        let finishes = (0..<S3Limits.maximumProviderTurns).map { _ in
            ProviderInferenceOutcome.decision(.finish(
                ProviderTurnMessage(role: .assistant, content: "I am done")
            ))
        }
        let provider = S3ScriptedProvider(outcomes: finishes)
        let executor = S3MockExecutor()
        let agent = try makeAgent(
            provider: provider,
            executor: executor,
            store: S3RecordingAttemptStore()
        )

        let outcome = await agent.run(taskID: UUID())
        let providerCalls = await provider.callCount
        let executorCalls = await executor.callCount
        XCTAssertEqual(outcome, .failure(.completionNotEstablished))
        XCTAssertEqual(providerCalls, S3Limits.maximumProviderTurns)
        XCTAssertEqual(executorCalls, 0)
    }

    private func makeAgent(
        provider: S3ScriptedProvider,
        executor: S3MockExecutor,
        store: S3RecordingAttemptStore
    ) throws -> S3ReadOnlyAgent {
        let workspace = try S3ApprovedWorkspace(rootURL: workspaceRoot)
        return S3ReadOnlyAgent(
            provider: provider,
            executor: executor,
            policy: S3ToolPolicy(workspace: workspace),
            attemptStore: store,
            now: { Date(timeIntervalSince1970: 1_000) }
        )
    }

    private func toolDecision(
        id: String,
        name: String,
        arguments: [String: String]
    ) -> ProviderInferenceOutcome {
        let call = call(id: id, name: name, arguments: arguments)
        return .decision(.toolCalls(
            ProviderTurnMessage(role: .assistant, toolCalls: [call]),
            [call]
        ))
    }

    private func batchDecision(
        _ calls: [ProviderTurnToolCall]
    ) -> ProviderInferenceOutcome {
        .decision(.toolCalls(
            ProviderTurnMessage(role: .assistant, toolCalls: calls),
            calls
        ))
    }

    private func call(
        id: String,
        name: String,
        arguments: [String: String]
    ) -> ProviderTurnToolCall {
        let data = try! JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
        return ProviderTurnToolCall(
            id: id,
            name: name,
            arguments: String(decoding: data, as: UTF8.self)
        )
    }

    private func facts() -> S3ExecutorFacts {
        S3ExecutorFacts(
            rootExitObserved: true,
            stdoutEOFObserved: true,
            stderrEOFObserved: true,
            finalState: .exited(0),
            stdoutByteCount: 2,
            stderrByteCount: 0,
            stdoutSHA256: ProviderDigest.sha256Hex("ok"),
            stderrSHA256: ProviderDigest.sha256Hex(""),
            truncated: false
        )
    }

    private func observation(
        tool: S3ToolName,
        path: String = "",
        query: String? = nil,
        payload: S3ObservationPayload
    ) -> S3ToolObservation {
        S3ToolObservation(
            tool: tool,
            relativePath: path,
            query: query,
            payload: payload,
            facts: facts()
        )
    }
}

private actor S3EventRecorder {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}

private actor S3ScriptedProvider: AgentInferenceProvider {
    let providerID = "scripted"
    private var outcomes: [ProviderInferenceOutcome]
    private let events: S3EventRecorder?
    private(set) var callCount = 0
    private(set) var requests: [ProviderInferenceRequest] = []

    init(outcomes: [ProviderInferenceOutcome], events: S3EventRecorder? = nil) {
        self.outcomes = outcomes
        self.events = events
    }

    func infer(request: ProviderInferenceRequest, requestID: UUID) async -> ProviderInferenceOutcome {
        callCount += 1
        requests.append(request)
        await events?.append("io:provider")
        guard !outcomes.isEmpty else { return .failure(.invalidToolExchange) }
        return outcomes.removeFirst()
    }
}

private actor S3MockExecutor: S3ReadOnlyExecuting {
    enum Mode { case observations, failure, unknown, unknownAt(Int) }

    private let mode: Mode
    private let events: S3EventRecorder?
    private(set) var callCount = 0
    private(set) var executedTools: [S3AuthorizedTool] = []

    init(mode: Mode = .observations, events: S3EventRecorder? = nil) {
        self.mode = mode
        self.events = events
    }

    func execute(_ tool: S3AuthorizedTool) async -> S3ExecutorOutcome {
        callCount += 1
        executedTools.append(tool)
        await events?.append("io:executor")
        if case .unknown = mode { return .unknown }
        if case let .unknownAt(index) = mode, callCount == index { return .unknown }
        if case .failure = mode { return .failure(.nonzeroExit) }
        let facts = S3ExecutorFacts(
            rootExitObserved: true,
            stdoutEOFObserved: true,
            stderrEOFObserved: true,
            finalState: .exited(0),
            stdoutByteCount: 64,
            stderrByteCount: 0,
            stdoutSHA256: ProviderDigest.sha256Hex("bounded"),
            stderrSHA256: ProviderDigest.sha256Hex(""),
            truncated: false
        )
        let payload: S3ObservationPayload
        switch tool {
        case .list:
            payload = .list(entries: ["guide.txt", "records"])
        case .search:
            payload = .search(matches: [S3SearchMatch(
                path: "records/target.txt",
                line: 2,
                text: S3TaskContract.marker
            )])
        case let .read(path):
            payload = .read(path: path, content: "header\n\(S3TaskContract.marker)\nfooter\n")
        }
        return .observation(S3ToolObservation(
            tool: tool.name,
            relativePath: tool.relativePath,
            query: tool.query,
            payload: payload,
            facts: facts
        ))
    }
}

private actor S3RecordingAttemptStore: S3AttemptRecording {
    private(set) var storedRecords: [S3AttemptEvidence]
    private let events: S3EventRecorder?
    private let failOnRecordNumber: Int?
    private var recordCount = 0

    init(
        initial: [S3AttemptEvidence] = [],
        events: S3EventRecorder? = nil,
        failOnRecordNumber: Int? = nil
    ) {
        storedRecords = initial
        self.events = events
        self.failOnRecordNumber = failOnRecordNumber
    }

    func record(_ evidence: S3AttemptEvidence) async throws {
        recordCount += 1
        if recordCount == failOnRecordNumber {
            throw S3AttemptStoreError.persistenceFailed
        }
        storedRecords.append(evidence)
        if evidence.phase == .intentRecorded {
            await events?.append("intent:\(evidence.ioKind.rawValue)")
        } else {
            await events?.append("terminal:\(evidence.ioKind.rawValue)")
        }
    }

    func records(taskID: UUID) async throws -> [S3AttemptEvidence] {
        storedRecords.filter { $0.taskID == taskID }
    }
}
