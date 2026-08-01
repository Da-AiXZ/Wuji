import XCTest
@testable import Wuji

final class WujiS4AgentTests: XCTestCase {
    func testHappyPathPreservesHistoryApprovalOrderingAndCodeOwnedCompletion() async throws {
        let fixture = try makeWorkspace()
        let events = TestS4EventLog()
        let provider = TestS4Provider(outcomes: happyProviderOutcomes(), events: events)
        let executor = TestS4Executor(workspace: fixture.workspace, events: events)
        let store = TestS4Store(events: events)
        let approval = TestS4ApprovalAuthorizer(mode: .approve, events: events)
        let agent = try makeAgent(
            fixture: fixture,
            provider: provider,
            executor: executor,
            store: store,
            approval: approval
        )

        guard case let .completed(completion) = await agent.run(taskID: fixture.taskID) else {
            return XCTFail("fixed S4 task did not complete")
        }
        XCTAssertEqual(completion.authorizedPath, S4TaskContract.authorizedPath)
        XCTAssertEqual(completion.beforeSHA256, S4TaskContract.beforeHash)
        XCTAssertEqual(completion.afterSHA256, S4TaskContract.afterHash)
        XCTAssertEqual(completion.providerRequestCount, 4)
        XCTAssertEqual(completion.toolExecutionCount, 5)

        let executorCalls = await executor.calls()
        XCTAssertEqual(executorCalls, ["list", "search", "read", "edit", "verify"])
        let eventValues = await events.values()
        assertPrecedes("attempt:provider:intent_recorded", "io:provider", in: eventValues)
        assertPrecedes("approval:pending", "approval:granted", in: eventValues)
        assertPrecedes("approval:granted", "attempt:write_executor:intent_recorded", in: eventValues)
        assertPrecedes("attempt:write_executor:intent_recorded", "io:edit", in: eventValues)
        assertPrecedes("attempt:verify_executor:intent_recorded", "io:verify", in: eventValues)

        let requests = await provider.requests()
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests.map { $0.tools.map(\.name) }, [
            ["list", "search", "read"],
            ["edit"],
            ["verify"],
            []
        ])
        XCTAssertEqual(requests.map(\.requireTool), [true, true, true, false])
        let secondMessages = requests[1].messages
        let assistantBatch = secondMessages.first { $0.role == .assistant && $0.toolCalls.count == 3 }
        XCTAssertEqual(assistantBatch?.toolCalls.map(\.id), ["list-1", "search-1", "read-1"])
        XCTAssertEqual(secondMessages.filter { $0.role == .tool }.map(\.toolCallID), [
            "list-1", "search-1", "read-1"
        ])
        XCTAssertTrue(requests[2].messages.contains {
            $0.role == .tool && $0.toolCallID == "edit-1"
        })
        XCTAssertTrue(requests[3].messages.contains {
            $0.role == .tool && $0.toolCallID == "verify-1"
        })

        let snapshot = await store.currentSnapshot()
        XCTAssertTrue(snapshot.attempts.allSatisfy { evidence in
            let sameAttempt = snapshot.attempts.filter { $0.attemptID == evidence.attemptID }
            return evidence.phase != .intentRecorded || sameAttempt.contains { $0.phase != .intentRecorded }
        })
        let verifyTerminal = try XCTUnwrap(snapshot.attempts.last {
            $0.ioKind == .verifyExecutor && $0.phase == .succeeded
        })
        XCTAssertEqual(verifyTerminal.rootExitObserved, true)
        XCTAssertEqual(verifyTerminal.stdoutEOFObserved, true)
        XCTAssertEqual(verifyTerminal.stderrEOFObserved, true)
        XCTAssertEqual(verifyTerminal.finalStateKind, "exited")
        XCTAssertEqual(verifyTerminal.finalStateValue, 0)
        XCTAssertEqual(verifyTerminal.truncated, false)
    }

    func testModelFinishCannotCompleteBeforeInspectionApprovalEditAndVerify() async throws {
        let fixture = try makeWorkspace()
        let provider = TestS4Provider(outcomes: [.decision(.finish(
            ProviderTurnMessage(role: .assistant, content: "done")
        ))])
        let executor = TestS4Executor(workspace: fixture.workspace)
        let agent = try makeAgent(
            fixture: fixture,
            provider: provider,
            executor: executor,
            store: TestS4Store(),
            approval: TestS4ApprovalAuthorizer(mode: .approve)
        )
        let outcome = await agent.run(taskID: fixture.taskID)
        XCTAssertFalse(outcome.isCompleted)
        let calls = await executor.calls()
        XCTAssertTrue(calls.isEmpty)
    }

    func testPolicyRejectionReportsOnlyBoundedReasonAndIndexWithZeroExecutorIO() async throws {
        let fixture = try makeWorkspace()
        let provider = TestS4Provider(outcomes: [.decision(toolDecision([
            call(id: "blocked-1", name: "shell", arguments: "{}")
        ]))])
        let executor = TestS4Executor(workspace: fixture.workspace)
        let agent = try makeAgent(
            fixture: fixture,
            provider: provider,
            executor: executor,
            store: TestS4Store(),
            approval: TestS4ApprovalAuthorizer(mode: .approve)
        )

        let outcome = await agent.run(taskID: fixture.taskID)
        XCTAssertEqual(
            outcome,
            .policyRejected(S4BatchPolicyError(reason: .unknownTool, callIndex: 0))
        )
        let calls = await executor.calls()
        XCTAssertTrue(calls.isEmpty)
    }

    func testRejectExpiredAndTamperedApprovalProduceZeroWriteIO() async throws {
        for mode in [
            TestS4ApprovalAuthorizer.Mode.reject,
            .expired,
            .tamper
        ] {
            let fixture = try makeWorkspace()
            let provider = TestS4Provider(outcomes: providerThroughEdit())
            let executor = TestS4Executor(workspace: fixture.workspace)
            let agent = try makeAgent(
                fixture: fixture,
                provider: provider,
                executor: executor,
                store: TestS4Store(),
                approval: TestS4ApprovalAuthorizer(mode: mode)
            )
            let outcome = await agent.run(taskID: fixture.taskID)
            XCTAssertFalse(outcome.isCompleted)
            let calls = await executor.calls()
            XCTAssertFalse(calls.contains("edit"))
        }
    }

    func testStaleBeforeSnapshotProducesZeroWriteExecutorIO() async throws {
        let fixture = try makeWorkspace()
        try Data("stale\n".utf8).write(
            to: fixture.root.appendingPathComponent(S4TaskContract.authorizedPath),
            options: .atomic
        )
        let executor = TestS4Executor(workspace: fixture.workspace)
        let agent = try makeAgent(
            fixture: fixture,
            provider: TestS4Provider(outcomes: providerThroughEdit()),
            executor: executor,
            store: TestS4Store(),
            approval: TestS4ApprovalAuthorizer(mode: .approve)
        )

        let outcome = await agent.run(taskID: fixture.taskID)
        XCTAssertEqual(outcome, .failure(.approvalTampered))
        let calls = await executor.calls()
        XCTAssertEqual(calls, ["list", "search", "read"])
    }

    func testWriteIntentFailureAndWriterBusyCauseZeroWriteIO() async throws {
        do {
            let fixture = try makeWorkspace()
            let executor = TestS4Executor(workspace: fixture.workspace)
            let store = TestS4Store(failIntentKinds: [.writeExecutor])
            let agent = try makeAgent(
                fixture: fixture,
                provider: TestS4Provider(outcomes: providerThroughEdit()),
                executor: executor,
                store: store,
                approval: TestS4ApprovalAuthorizer(mode: .approve)
            )
            let outcome = await agent.run(taskID: fixture.taskID)
            let calls = await executor.calls()
            XCTAssertEqual(outcome, .failure(.durableEvidenceUnavailable))
            XCTAssertFalse(calls.contains("edit"))
        }
        do {
            let fixture = try makeWorkspace()
            let executor = TestS4Executor(workspace: fixture.workspace)
            let agent = try makeAgent(
                fixture: fixture,
                provider: TestS4Provider(outcomes: providerThroughEdit()),
                executor: executor,
                store: TestS4Store(),
                approval: TestS4ApprovalAuthorizer(mode: .approve),
                writerGate: TestS4WriterGate(alwaysBusy: true)
            )
            let outcome = await agent.run(taskID: fixture.taskID)
            let calls = await executor.calls()
            XCTAssertEqual(outcome, .failure(.writerBusy))
            XCTAssertFalse(calls.contains("edit"))
        }
    }

    func testProviderReadAndVerifyIntentFailuresPreventCorrespondingIO() async throws {
        do {
            let fixture = try makeWorkspace()
            let provider = TestS4Provider(outcomes: happyProviderOutcomes())
            let agent = try makeAgent(
                fixture: fixture,
                provider: provider,
                executor: TestS4Executor(workspace: fixture.workspace),
                store: TestS4Store(failIntentKinds: [.provider]),
                approval: TestS4ApprovalAuthorizer(mode: .approve)
            )
            let outcome = await agent.run(taskID: fixture.taskID)
            XCTAssertEqual(outcome, .failure(.durableEvidenceUnavailable))
            let count = await provider.requestCount()
            XCTAssertEqual(count, 0)
        }
        do {
            let fixture = try makeWorkspace()
            let executor = TestS4Executor(workspace: fixture.workspace)
            let agent = try makeAgent(
                fixture: fixture,
                provider: TestS4Provider(outcomes: happyProviderOutcomes()),
                executor: executor,
                store: TestS4Store(failIntentKinds: [.readExecutor]),
                approval: TestS4ApprovalAuthorizer(mode: .approve)
            )
            let outcome = await agent.run(taskID: fixture.taskID)
            XCTAssertEqual(outcome, .failure(.durableEvidenceUnavailable))
            let calls = await executor.calls()
            XCTAssertTrue(calls.isEmpty)
        }
        do {
            let fixture = try makeWorkspace()
            let executor = TestS4Executor(workspace: fixture.workspace)
            let agent = try makeAgent(
                fixture: fixture,
                provider: TestS4Provider(outcomes: happyProviderOutcomes()),
                executor: executor,
                store: TestS4Store(failIntentKinds: [.verifyExecutor]),
                approval: TestS4ApprovalAuthorizer(mode: .approve)
            )
            let outcome = await agent.run(taskID: fixture.taskID)
            XCTAssertEqual(outcome, .failure(.durableEvidenceUnavailable))
            let calls = await executor.calls()
            XCTAssertEqual(calls, ["list", "search", "read", "edit"])
        }
    }

    func testProviderReadAndVerifyTerminalFailuresEnterReconciliationWithoutRetry() async throws {
        let kinds: [S4ExternalIOKind] = [.provider, .readExecutor, .verifyExecutor]
        for kind in kinds {
            let fixture = try makeWorkspace()
            let provider = TestS4Provider(outcomes: happyProviderOutcomes())
            let executor = TestS4Executor(workspace: fixture.workspace)
            let agent = try makeAgent(
                fixture: fixture,
                provider: provider,
                executor: executor,
                store: TestS4Store(failTerminalKinds: [kind]),
                approval: TestS4ApprovalAuthorizer(mode: .approve)
            )
            let outcome = await agent.run(taskID: fixture.taskID)
            XCTAssertEqual(outcome, .reconciliationRequired)
            let calls = await executor.calls()
            let providerCount = await provider.requestCount()
            switch kind {
            case .provider:
                XCTAssertEqual(providerCount, 1)
                XCTAssertTrue(calls.isEmpty)
            case .readExecutor:
                XCTAssertEqual(calls, ["list"])
            case .verifyExecutor:
                XCTAssertEqual(calls, ["list", "search", "read", "edit", "verify"])
            default:
                XCTFail("unexpected test kind")
            }
        }
    }

    func testWriteTerminalPersistenceFailureAndUnknownStopBeforeVerify() async throws {
        for mode in [TestS4Executor.EditMode.success, .unknownBefore] {
            let fixture = try makeWorkspace()
            let executor = TestS4Executor(workspace: fixture.workspace, editMode: mode)
            let store = TestS4Store(
                failTerminalKinds: mode == .success ? [.writeExecutor] : []
            )
            let agent = try makeAgent(
                fixture: fixture,
                provider: TestS4Provider(outcomes: happyProviderOutcomes()),
                executor: executor,
                store: store,
                approval: TestS4ApprovalAuthorizer(mode: .approve)
            )
            let outcome = await agent.run(taskID: fixture.taskID)
            let calls = await executor.calls()
            XCTAssertEqual(outcome, .reconciliationRequired)
            XCTAssertEqual(calls.filter { $0 == "edit" }.count, 1)
            XCTAssertFalse(calls.contains("verify"))
        }
    }

    func testUnknownAfterWriteColdRecoveryReconcilesAppliedStateWithoutRewrite() async throws {
        let fixture = try makeWorkspace()
        let provider = TestS4Provider(outcomes: happyProviderOutcomes())
        let executor = TestS4Executor(workspace: fixture.workspace, editMode: .unknownAfter)
        let store = TestS4Store()
        let agent = try makeAgent(
            fixture: fixture,
            provider: provider,
            executor: executor,
            store: store,
            approval: TestS4ApprovalAuthorizer(mode: .approve)
        )
        let firstOutcome = await agent.run(taskID: fixture.taskID)
        XCTAssertEqual(firstOutcome, .reconciliationRequired)
        guard case .completed = await agent.run(taskID: fixture.taskID) else {
            return XCTFail("applied unknown write did not reconcile")
        }
        let calls = await executor.calls()
        XCTAssertEqual(calls.filter { $0 == "edit" }.count, 1)
        XCTAssertEqual(calls.filter { $0 == "verify" }.count, 1)
        let providerCount = await provider.requestCount()
        XCTAssertEqual(providerCount, 2)
    }

    func testUnknownSecondReadStopsThirdCallAndDoesNotRetry() async throws {
        let fixture = try makeWorkspace()
        let executor = TestS4Executor(workspace: fixture.workspace, unknownReadIndex: 2)
        let provider = TestS4Provider(outcomes: [happyProviderOutcomes()[0]])
        let agent = try makeAgent(
            fixture: fixture,
            provider: provider,
            executor: executor,
            store: TestS4Store(),
            approval: TestS4ApprovalAuthorizer(mode: .approve)
        )
        let outcome = await agent.run(taskID: fixture.taskID)
        let calls = await executor.calls()
        let requestCount = await provider.requestCount()
        XCTAssertEqual(outcome, .reconciliationRequired)
        XCTAssertEqual(calls, ["list", "search"])
        XCTAssertEqual(requestCount, 1)
    }

    func testPendingApprovalColdRecoveryUsesSameRequestWithoutProviderReplay() async throws {
        let fixture = try makeWorkspace()
        let date = testDate
        let request = approvalRequest(workspace: fixture.workspace, date: date)
        let store = TestS4Store(approvals: [approvalEvidence(request: request, phase: .pending)])
        let provider = TestS4Provider(outcomes: [])
        let executor = TestS4Executor(workspace: fixture.workspace)
        let approval = TestS4ApprovalAuthorizer(mode: .approve)
        let agent = try makeAgent(
            fixture: fixture,
            provider: provider,
            executor: executor,
            store: store,
            approval: approval
        )

        guard case .completed = await agent.run(taskID: fixture.taskID) else {
            return XCTFail("pending approval did not cold-recover")
        }
        let requestCount = await provider.requestCount()
        let approvalRequestIDs = await approval.requests().map(\.requestID)
        let calls = await executor.calls()
        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(approvalRequestIDs, [request.requestID])
        XCTAssertEqual(calls, ["edit", "verify"])
    }

    func testProviderIntentWithoutTerminalColdRecoveryDoesNotResend() async throws {
        let fixture = try makeWorkspace()
        let providerIntent = attempt(
            taskID: fixture.taskID,
            kind: .provider,
            phase: .intentRecorded
        )
        let store = TestS4Store(attempts: [providerIntent])
        let provider = TestS4Provider(outcomes: happyProviderOutcomes())
        let agent = try makeAgent(
            fixture: fixture,
            provider: provider,
            executor: TestS4Executor(workspace: fixture.workspace),
            store: store,
            approval: TestS4ApprovalAuthorizer(mode: .approve)
        )
        let outcome = await agent.run(taskID: fixture.taskID)
        let requestCount = await provider.requestCount()
        XCTAssertEqual(outcome, .reconciliationRequired)
        XCTAssertEqual(requestCount, 0)
        let snapshot = await store.currentSnapshot()
        XCTAssertTrue(snapshot.attempts.contains {
            $0.attemptID == providerIntent.attemptID
                && $0.phase == .reconciliationRequired
                && $0.resultCategory == .providerUnknown
        })
    }

    func testUnresolvedWriteBeforeStateIsReconciledWithoutRetry() async throws {
        let fixture = try makeWorkspace()
        let seeded = seededGrant(workspace: fixture.workspace)
        let writeIntent = attempt(
            taskID: fixture.taskID,
            kind: .writeExecutor,
            phase: .intentRecorded,
            approvalNonce: seeded.request.nonce
        )
        let store = TestS4Store(attempts: [writeIntent], approvals: seeded.evidence)
        let executor = TestS4Executor(workspace: fixture.workspace)
        let agent = try makeAgent(
            fixture: fixture,
            provider: TestS4Provider(outcomes: []),
            executor: executor,
            store: store,
            approval: TestS4ApprovalAuthorizer(mode: .approve)
        )
        let outcome = await agent.run(taskID: fixture.taskID)
        let calls = await executor.calls()
        XCTAssertEqual(outcome, .reconciliationRequired)
        XCTAssertTrue(calls.isEmpty)
        let snapshot = await store.currentSnapshot()
        XCTAssertTrue(snapshot.attempts.contains {
            $0.attemptID == writeIntent.attemptID && $0.phase == .reconciledNotApplied
        })
    }

    func testUnresolvedWriteAfterStateIsReconciledThenVerifiedWithoutRewrite() async throws {
        let fixture = try makeWorkspace(initialState: .after)
        let seeded = seededGrant(workspace: fixture.workspace)
        let writeIntent = attempt(
            taskID: fixture.taskID,
            kind: .writeExecutor,
            phase: .intentRecorded,
            approvalNonce: seeded.request.nonce
        )
        let store = TestS4Store(attempts: [writeIntent], approvals: seeded.evidence)
        let executor = TestS4Executor(workspace: fixture.workspace)
        let agent = try makeAgent(
            fixture: fixture,
            provider: TestS4Provider(outcomes: []),
            executor: executor,
            store: store,
            approval: TestS4ApprovalAuthorizer(mode: .approve)
        )
        guard case .completed = await agent.run(taskID: fixture.taskID) else {
            return XCTFail("after-state reconciliation did not complete")
        }
        let calls = await executor.calls()
        XCTAssertEqual(calls, ["verify"])
        let snapshot = await store.currentSnapshot()
        XCTAssertTrue(snapshot.attempts.contains {
            $0.attemptID == writeIntent.attemptID && $0.phase == .reconciledApplied
        })
    }

    func testUnresolvedWriteWithTempOrOtherStateRequiresManualReconciliation() async throws {
        for mutation in ["temp", "other"] {
            let fixture = try makeWorkspace()
            if mutation == "temp" {
                try Data("partial\n".utf8).write(
                    to: fixture.root.appendingPathComponent(S4TaskContract.authorizedPath + S4TaskContract.temporarySuffix)
                )
            } else {
                try Data("unexpected\n".utf8).write(
                    to: fixture.root.appendingPathComponent(S4TaskContract.authorizedPath),
                    options: .atomic
                )
            }
            let seeded = seededGrant(workspace: fixture.workspace)
            let writeIntent = attempt(
                taskID: fixture.taskID,
                kind: .writeExecutor,
                phase: .intentRecorded,
                approvalNonce: seeded.request.nonce
            )
            let executor = TestS4Executor(workspace: fixture.workspace)
            let agent = try makeAgent(
                fixture: fixture,
                provider: TestS4Provider(outcomes: []),
                executor: executor,
                store: TestS4Store(attempts: [writeIntent], approvals: seeded.evidence),
                approval: TestS4ApprovalAuthorizer(mode: .approve)
            )
            let outcome = await agent.run(taskID: fixture.taskID)
            let calls = await executor.calls()
            XCTAssertEqual(outcome, .reconciliationRequired)
            XCTAssertTrue(calls.isEmpty)
        }
    }

    func testUnresolvedVerifyMarksOldAttemptUnknownThenCreatesOneNewAttempt() async throws {
        let fixture = try makeWorkspace(initialState: .after)
        let seeded = seededGrant(workspace: fixture.workspace)
        let write = attemptPair(
            taskID: fixture.taskID,
            kind: .writeExecutor,
            terminalCategory: .writeApplied,
            approvalNonce: seeded.request.nonce,
            facts: successFacts()
        )
        let verifyIntent = attempt(
            taskID: fixture.taskID,
            kind: .verifyExecutor,
            phase: .intentRecorded,
            approvalNonce: seeded.request.nonce
        )
        let store = TestS4Store(attempts: write + [verifyIntent], approvals: seeded.evidence)
        let executor = TestS4Executor(workspace: fixture.workspace)
        let agent = try makeAgent(
            fixture: fixture,
            provider: TestS4Provider(outcomes: []),
            executor: executor,
            store: store,
            approval: TestS4ApprovalAuthorizer(mode: .approve)
        )
        guard case .completed = await agent.run(taskID: fixture.taskID) else {
            return XCTFail("verify recovery did not complete")
        }
        let calls = await executor.calls()
        XCTAssertEqual(calls, ["verify"])
        let snapshot = await store.currentSnapshot()
        XCTAssertTrue(snapshot.attempts.contains {
            $0.attemptID == verifyIntent.attemptID && $0.phase == .reconciliationRequired
        })
        XCTAssertEqual(Set(snapshot.attempts.filter {
            $0.ioKind == .verifyExecutor && $0.phase == .intentRecorded
        }.map(\.attemptID)).count, 2)
    }

    func testExistingVerifySuccessColdRecoveryDoesNotRepeatVerify() async throws {
        let fixture = try makeWorkspace(initialState: .after)
        let seeded = seededGrant(workspace: fixture.workspace)
        let attempts = attemptPair(
            taskID: fixture.taskID,
            kind: .writeExecutor,
            terminalCategory: .writeApplied,
            approvalNonce: seeded.request.nonce,
            facts: successFacts()
        ) + attemptPair(
            taskID: fixture.taskID,
            kind: .verifyExecutor,
            terminalCategory: .verifyPassed,
            approvalNonce: seeded.request.nonce,
            facts: successFacts()
        )
        let executor = TestS4Executor(workspace: fixture.workspace)
        let agent = try makeAgent(
            fixture: fixture,
            provider: TestS4Provider(outcomes: []),
            executor: executor,
            store: TestS4Store(attempts: attempts, approvals: seeded.evidence),
            approval: TestS4ApprovalAuthorizer(mode: .approve)
        )
        guard case .completed = await agent.run(taskID: fixture.taskID) else {
            return XCTFail("verified recovery state did not complete")
        }
        let calls = await executor.calls()
        XCTAssertTrue(calls.isEmpty)
    }

    func testConsumedGrantIsNotReplayedAfterReconciledNotAppliedWrite() async throws {
        let fixture = try makeWorkspace()
        let seeded = seededGrant(workspace: fixture.workspace)
        let operationID = UUID()
        let attemptID = UUID()
        let attempts = [
            attempt(
                taskID: fixture.taskID,
                kind: .writeExecutor,
                phase: .intentRecorded,
                operationID: operationID,
                attemptID: attemptID,
                approvalNonce: seeded.request.nonce
            ),
            attempt(
                taskID: fixture.taskID,
                kind: .writeExecutor,
                phase: .reconciledNotApplied,
                operationID: operationID,
                attemptID: attemptID,
                category: .workspaceBefore,
                approvalNonce: seeded.request.nonce
            )
        ]
        let executor = TestS4Executor(workspace: fixture.workspace)
        let agent = try makeAgent(
            fixture: fixture,
            provider: TestS4Provider(outcomes: []),
            executor: executor,
            store: TestS4Store(attempts: attempts, approvals: seeded.evidence),
            approval: TestS4ApprovalAuthorizer(mode: .approve)
        )
        let outcome = await agent.run(taskID: fixture.taskID)
        XCTAssertEqual(outcome, .reconciliationRequired)
        let calls = await executor.calls()
        XCTAssertTrue(calls.isEmpty)
    }

    func testAdditionalWorkspaceDiffPreventsCompletion() async throws {
        let fixture = try makeWorkspace()
        let provider = TestS4Provider(outcomes: happyProviderOutcomes())
        let executor = TestS4Executor(
            workspace: fixture.workspace,
            addUnexpectedFileAfterVerify: true
        )
        let agent = try makeAgent(
            fixture: fixture,
            provider: provider,
            executor: executor,
            store: TestS4Store(),
            approval: TestS4ApprovalAuthorizer(mode: .approve)
        )
        let outcome = await agent.run(taskID: fixture.taskID)
        XCTAssertFalse(outcome.isCompleted)
    }

    private let testDate = Date(timeIntervalSince1970: 10_000)

    private struct Fixture {
        let temp: URL
        let root: URL
        let taskID: UUID
        let workspace: S4ApprovedWorkspace
    }

    private func makeWorkspace(initialState: S4WorkspaceContentState = .before) throws -> Fixture {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = temp.appendingPathComponent("workspace", isDirectory: true)
        let records = root.appendingPathComponent("records", isDirectory: true)
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        let draft = initialState == .after
            ? S4TaskContract.expectedAfterContent
            : S4TaskContract.expectedBeforeContent
        try Data(draft.utf8).write(to: root.appendingPathComponent(S4TaskContract.authorizedPath))
        try Data(S4TaskContract.expectedContextContent.utf8).write(
            to: root.appendingPathComponent(S4TaskContract.contextPath)
        )
        let taskID = UUID()
        let workspace = try S4ApprovedWorkspace(
            taskID: taskID,
            rootURL: root,
            requireInitialSeed: initialState == .before
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: temp) }
        return Fixture(temp: temp, root: root, taskID: taskID, workspace: workspace)
    }

    private func makeAgent(
        fixture: Fixture,
        provider: TestS4Provider,
        executor: TestS4Executor,
        store: TestS4Store,
        approval: TestS4ApprovalAuthorizer,
        writerGate: S4WriterSerializing = TestS4WriterGate()
    ) throws -> S4Agent {
        let date = testDate
        return S4Agent(
            provider: provider,
            executor: executor,
            policy: try S4ToolPolicy(workspace: fixture.workspace),
            durableStore: store,
            approvalAuthorizer: approval,
            writerGate: writerGate,
            workspace: fixture.workspace,
            now: { date }
        )
    }

    private func happyProviderOutcomes() -> [ProviderInferenceOutcome] {
        [
            .decision(toolDecision([
                call(id: "list-1", name: "list", arguments: #"{"path":""}"#),
                call(id: "search-1", name: "search", arguments: #"{"path":"","query":"STATUS=pending"}"#),
                call(id: "read-1", name: "read", arguments: #"{"path":"records/draft.txt"}"#)
            ])),
            .decision(toolDecision([
                call(id: "edit-1", name: "edit", arguments: #"{"path":"records/draft.txt","expected_old":"STATUS=pending","replacement":"STATUS=verified"}"#)
            ])),
            .decision(toolDecision([
                call(id: "verify-1", name: "verify", arguments: #"{"profile":"s4_status_verified"}"#)
            ])),
            .decision(.finish(ProviderTurnMessage(role: .assistant, content: "fixed task complete")))
        ]
    }

    private func providerThroughEdit() -> [ProviderInferenceOutcome] {
        Array(happyProviderOutcomes().prefix(2))
    }

    private func toolDecision(_ calls: [ProviderTurnToolCall]) -> ProviderInferenceDecision {
        .toolCalls(
            ProviderTurnMessage(role: .assistant, toolCalls: calls),
            calls
        )
    }

    private func call(id: String, name: String, arguments: String) -> ProviderTurnToolCall {
        ProviderTurnToolCall(id: id, name: name, arguments: arguments)
    }

    private func approvalRequest(workspace: S4ApprovedWorkspace, date: Date) -> S4ApprovalRequest {
        S4ApprovalRequest(
            requestID: UUID(),
            taskID: workspace.taskID,
            workspaceID: workspace.workspaceID,
            workspaceSnapshotSHA256: workspace.seedSnapshotSHA256,
            toolCallID: "edit-recovery",
            relativePath: S4TaskContract.authorizedPath,
            beforeSHA256: S4TaskContract.beforeHash,
            afterSHA256: S4TaskContract.afterHash,
            changeSummarySHA256: S4TaskContract.changeSummaryHash,
            verificationProfile: .s4StatusVerified,
            nonce: UUID(),
            createdAt: date,
            expiresAt: date.addingTimeInterval(S4Limits.maximumApprovalSeconds)
        )
    }

    private func approvalEvidence(
        request: S4ApprovalRequest,
        phase: S4ApprovalEvidencePhase,
        grant: S4ApprovalGrant? = nil
    ) -> S4ApprovalEvidence {
        S4ApprovalEvidence(
            request: request,
            phase: phase,
            recordedAt: testDate,
            grant: grant,
            rejection: nil
        )
    }

    private func seededGrant(workspace: S4ApprovedWorkspace) -> (
        request: S4ApprovalRequest,
        grant: S4ApprovalGrant,
        evidence: [S4ApprovalEvidence]
    ) {
        let request = approvalRequest(workspace: workspace, date: testDate)
        let grant = S4ApprovalGrant(
            requestID: request.requestID,
            requestBindingSHA256: request.bindingSHA256,
            nonce: request.nonce,
            approvedAt: testDate
        )
        return (
            request,
            grant,
            [
                approvalEvidence(request: request, phase: .pending),
                approvalEvidence(request: request, phase: .granted, grant: grant)
            ]
        )
    }

    private func attempt(
        taskID: UUID,
        kind: S4ExternalIOKind,
        phase: S4AttemptPhase,
        operationID: UUID = UUID(),
        attemptID: UUID = UUID(),
        category: S4AttemptResultCategory = .none,
        approvalNonce: UUID? = nil,
        facts: S3ExecutorFacts? = nil
    ) -> S4AttemptEvidence {
        let state: (String, Int32)? = facts.map {
            switch $0.finalState {
            case let .exited(value): return ("exited", value)
            case let .signaled(value): return ("signaled", value)
            case .unknown: return ("signaled", -1)
            }
        }
        return S4AttemptEvidence(
            taskID: taskID,
            operationID: operationID,
            attemptID: attemptID,
            ioKind: kind,
            providerID: kind == .provider ? "mock" : nil,
            toolName: kind == .writeExecutor ? "edit" : (kind == .verifyExecutor ? "verify" : nil),
            toolCallIDHash: nil,
            approvalNonceHash: approvalNonce.map { ProviderDigest.sha256Hex($0.uuidString.lowercased()) },
            inputSHA256: String(repeating: "a", count: 64),
            recordedAt: testDate,
            phase: phase,
            resultCategory: category,
            resultByteCount: facts == nil ? nil : 16,
            resultSHA256: facts == nil ? nil : String(repeating: "b", count: 64),
            rootExitObserved: facts?.rootExitObserved,
            stdoutEOFObserved: facts?.stdoutEOFObserved,
            stderrEOFObserved: facts?.stderrEOFObserved,
            finalStateKind: state?.0,
            finalStateValue: state?.1,
            truncated: facts?.truncated
        )
    }

    private func attemptPair(
        taskID: UUID,
        kind: S4ExternalIOKind,
        terminalCategory: S4AttemptResultCategory,
        approvalNonce: UUID?,
        facts: S3ExecutorFacts
    ) -> [S4AttemptEvidence] {
        let operationID = UUID()
        let attemptID = UUID()
        return [
            attempt(
                taskID: taskID,
                kind: kind,
                phase: .intentRecorded,
                operationID: operationID,
                attemptID: attemptID,
                approvalNonce: approvalNonce
            ),
            attempt(
                taskID: taskID,
                kind: kind,
                phase: .succeeded,
                operationID: operationID,
                attemptID: attemptID,
                category: terminalCategory,
                approvalNonce: approvalNonce,
                facts: facts
            )
        ]
    }

    private func successFacts() -> S3ExecutorFacts {
        S3ExecutorFacts(
            rootExitObserved: true,
            stdoutEOFObserved: true,
            stderrEOFObserved: true,
            finalState: .exited(0),
            stdoutByteCount: 16,
            stderrByteCount: 0,
            stdoutSHA256: String(repeating: "c", count: 64),
            stderrSHA256: String(repeating: "d", count: 64),
            truncated: false
        )
    }

    private func assertPrecedes(_ first: String, _ second: String, in values: [String]) {
        guard let firstIndex = values.firstIndex(of: first),
              let secondIndex = values.firstIndex(of: second) else {
            return XCTFail("missing event ordering evidence: \(first) -> \(second)")
        }
        XCTAssertLessThan(firstIndex, secondIndex)
    }
}

private extension S4LoopOutcome {
    var isCompleted: Bool {
        if case .completed = self { return true }
        return false
    }
}

private actor TestS4EventLog {
    private var items: [String] = []
    func append(_ item: String) { items.append(item) }
    func values() -> [String] { items }
}

private actor TestS4Provider: AgentInferenceProvider {
    nonisolated let providerID = "mock"
    private var outcomes: [ProviderInferenceOutcome]
    private var captured: [ProviderInferenceRequest] = []
    private let events: TestS4EventLog?

    init(outcomes: [ProviderInferenceOutcome], events: TestS4EventLog? = nil) {
        self.outcomes = outcomes
        self.events = events
    }

    func infer(request: ProviderInferenceRequest, requestID: UUID) async -> ProviderInferenceOutcome {
        _ = requestID
        captured.append(request)
        await events?.append("io:provider")
        guard !outcomes.isEmpty else { return .failure(.malformedResponse) }
        return outcomes.removeFirst()
    }

    func requests() -> [ProviderInferenceRequest] { captured }
    func requestCount() -> Int { captured.count }
}

private actor TestS4Executor: S4Executing {
    enum EditMode: Equatable { case success, unknownBefore, unknownAfter }

    nonisolated let workspace: S4ApprovedWorkspace
    private let events: TestS4EventLog?
    private let editMode: EditMode
    private let unknownReadIndex: Int?
    private let addUnexpectedFileAfterVerify: Bool
    private var callNames: [String] = []
    private var readCount = 0

    init(
        workspace: S4ApprovedWorkspace,
        events: TestS4EventLog? = nil,
        editMode: EditMode = .success,
        unknownReadIndex: Int? = nil,
        addUnexpectedFileAfterVerify: Bool = false
    ) {
        self.workspace = workspace
        self.events = events
        self.editMode = editMode
        self.unknownReadIndex = unknownReadIndex
        self.addUnexpectedFileAfterVerify = addUnexpectedFileAfterVerify
    }

    func execute(_ tool: S3AuthorizedTool) async -> S3ExecutorOutcome {
        readCount += 1
        callNames.append(tool.name.rawValue)
        await events?.append("io:\(tool.name.rawValue)")
        if unknownReadIndex == readCount { return .unknown }
        let facts = successFacts()
        switch tool {
        case .list:
            return .observation(S3ToolObservation(
                tool: .list,
                relativePath: "",
                query: nil,
                payload: .list(entries: ["records"]),
                facts: facts
            ))
        case .search:
            return .observation(S3ToolObservation(
                tool: .search,
                relativePath: "",
                query: S4TaskContract.expectedOldText,
                payload: .search(matches: [S3SearchMatch(
                    path: S4TaskContract.authorizedPath,
                    line: 2,
                    text: S4TaskContract.expectedOldText
                )]),
                facts: facts
            ))
        case .read:
            return .observation(S3ToolObservation(
                tool: .read,
                relativePath: S4TaskContract.authorizedPath,
                query: nil,
                payload: .read(
                    path: S4TaskContract.authorizedPath,
                    content: S4TaskContract.expectedBeforeContent
                ),
                facts: facts
            ))
        }
    }

    func edit(_ edit: S4AuthorizedEdit) async -> S4EditOutcome {
        callNames.append("edit")
        await events?.append("io:edit")
        switch editMode {
        case .unknownBefore:
            return .unknown
        case .success, .unknownAfter:
            do {
                try Data(S4TaskContract.expectedAfterContent.utf8).write(
                    to: workspace.canonicalRootURL.appendingPathComponent(S4TaskContract.authorizedPath),
                    options: .atomic
                )
            } catch {
                return .failure(.nonzeroExit)
            }
            if editMode == .unknownAfter { return .unknown }
            return .observation(S4EditObservation(
                relativePath: edit.relativePath,
                beforeSHA256: edit.beforeHash,
                afterSHA256: edit.afterHash,
                facts: successFacts()
            ))
        }
    }

    func verify(_ profile: S4VerificationProfile) async -> S4VerifyOutcome {
        callNames.append("verify")
        await events?.append("io:verify")
        if addUnexpectedFileAfterVerify {
            try? Data("unexpected\n".utf8).write(
                to: workspace.canonicalRootURL.appendingPathComponent("records/unexpected.txt")
            )
        }
        return .observation(S4VerifyObservation(
            profile: profile,
            afterSHA256: S4TaskContract.afterHash,
            contextSHA256: S4TaskContract.contextHash,
            facts: successFacts()
        ))
    }

    nonisolated func requestCancellation() -> CancellationReceipt {
        CancellationReceipt(requested: true, delivery: .noActiveTask)
    }
    func calls() -> [String] { callNames }

    private func successFacts() -> S3ExecutorFacts {
        S3ExecutorFacts(
            rootExitObserved: true,
            stdoutEOFObserved: true,
            stderrEOFObserved: true,
            finalState: .exited(0),
            stdoutByteCount: 16,
            stderrByteCount: 0,
            stdoutSHA256: String(repeating: "e", count: 64),
            stderrSHA256: String(repeating: "f", count: 64),
            truncated: false
        )
    }
}

private actor TestS4Store: S4DurableRecording {
    private var attemptValues: [S4AttemptEvidence]
    private var approvalValues: [S4ApprovalEvidence]
    private let failIntentKinds: Set<S4ExternalIOKind>
    private let failTerminalKinds: Set<S4ExternalIOKind>
    private let events: TestS4EventLog?

    init(
        attempts: [S4AttemptEvidence] = [],
        approvals: [S4ApprovalEvidence] = [],
        failIntentKinds: Set<S4ExternalIOKind> = [],
        failTerminalKinds: Set<S4ExternalIOKind> = [],
        events: TestS4EventLog? = nil
    ) {
        attemptValues = attempts
        approvalValues = approvals
        self.failIntentKinds = failIntentKinds
        self.failTerminalKinds = failTerminalKinds
        self.events = events
    }

    func recordAttempt(_ evidence: S4AttemptEvidence) async throws {
        if evidence.phase == .intentRecorded, failIntentKinds.contains(evidence.ioKind) {
            throw S4DurableStoreError.persistenceFailed
        }
        if evidence.phase != .intentRecorded, failTerminalKinds.contains(evidence.ioKind) {
            throw S4DurableStoreError.persistenceFailed
        }
        attemptValues.append(evidence)
        await events?.append("attempt:\(evidence.ioKind.rawValue):\(evidence.phase.rawValue)")
    }

    func recordApproval(_ evidence: S4ApprovalEvidence) async throws {
        approvalValues.append(evidence)
        await events?.append("approval:\(evidence.phase.rawValue)")
    }

    func snapshot(taskID: UUID) async throws -> S4DurableSnapshot {
        S4DurableSnapshot(
            attempts: attemptValues.filter { $0.taskID == taskID },
            approvals: approvalValues.filter { $0.request.taskID == taskID }
        )
    }

    func currentSnapshot() -> S4DurableSnapshot {
        S4DurableSnapshot(attempts: attemptValues, approvals: approvalValues)
    }
}

private actor TestS4ApprovalAuthorizer: S4ApprovalAuthorizing {
    enum Mode { case approve, reject, expired, tamper }
    private let mode: Mode
    private let events: TestS4EventLog?
    private var captured: [S4ApprovalRequest] = []

    init(mode: Mode, events: TestS4EventLog? = nil) {
        self.mode = mode
        self.events = events
    }

    func requestApproval(_ request: S4ApprovalRequest) async -> S4ApprovalDecision {
        captured.append(request)
        await events?.append("io:approval")
        switch mode {
        case .approve:
            return .approved(S4ApprovalGrant(
                requestID: request.requestID,
                requestBindingSHA256: request.bindingSHA256,
                nonce: request.nonce,
                approvedAt: request.createdAt
            ))
        case .reject:
            return .rejected(.rejected)
        case .expired:
            return .rejected(.expired)
        case .tamper:
            return .approved(S4ApprovalGrant(
                requestID: request.requestID,
                requestBindingSHA256: String(repeating: "0", count: 64),
                nonce: request.nonce,
                approvedAt: request.createdAt
            ))
        }
    }

    func requests() -> [S4ApprovalRequest] { captured }
}

private actor TestS4WriterGate: S4WriterSerializing {
    private let alwaysBusy: Bool
    private var active: [String: UUID] = [:]

    init(alwaysBusy: Bool = false) { self.alwaysBusy = alwaysBusy }

    func acquire(workspaceID: String) async -> UUID? {
        guard !alwaysBusy, active[workspaceID] == nil else { return nil }
        let token = UUID()
        active[workspaceID] = token
        return token
    }

    func release(workspaceID: String, token: UUID) async {
        if active[workspaceID] == token { active.removeValue(forKey: workspaceID) }
    }
}
