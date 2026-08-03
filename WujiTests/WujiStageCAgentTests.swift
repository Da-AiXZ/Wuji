import Foundation
import XCTest
@testable import Wuji

final class WujiStageCAgentTests: XCTestCase {
    func testApprovedEditPersistsIntentBeforeWriteAndCompletesOnlyAfterVerifierAndProviderFinish() async throws {
        let prepared = try await StageCTestSupport.prepare()
        defer { prepared.cleanup() }
        let provider = StageCScriptedProvider([
            .decision(.toolCalls(
                ProviderTurnMessage(role: .assistant, toolCalls: [StageCTestSupport.editCall(id: "happy-edit")]),
                [StageCTestSupport.editCall(id: "happy-edit")]
            )),
            .decision(.finish(ProviderTurnMessage(role: .assistant, content: "done")))
        ])
        let editor = StageCMockEditExecutor(
            targetURL: prepared.targetURL,
            taskStore: prepared.taskStore,
            taskID: prepared.task.id,
            outcome: .applied
        )
        let agent = makeAgent(prepared, provider: provider, editor: editor, approval: .approve)
        let outcome = await agent.run()
        guard case let .completed(completion) = outcome else {
            let snapshot = try await prepared.taskStore.snapshot(taskID: prepared.task.id)
            return XCTFail("Stage C did not complete: outcome=\(outcome) \(diagnostic(snapshot))")
        }
        let snapshot = try await prepared.taskStore.snapshot(taskID: prepared.task.id)
        let sawIntent = await editor.intentWasVisible()
        let editCount = await editor.callCount()
        XCTAssertTrue(sawIntent)
        XCTAssertEqual(editCount, 1)
        XCTAssertEqual(completion.finalTreeSHA256, snapshot.proposal?.expectedAfterTreeSHA256)
        XCTAssertEqual(snapshot.phase, .completed)
        XCTAssertTrue(snapshot.providerFinishObserved)
        XCTAssertTrue(snapshot.approvals.contains { $0.state == .consumed })
        XCTAssertTrue(snapshot.attempts.contains {
            $0.ioKind == .verificationRead && $0.phase == .succeeded
        })
    }

    func testRejectedApprovalPerformsZeroWriteIO() async throws {
        let prepared = try await StageCTestSupport.prepare()
        defer { prepared.cleanup() }
        let provider = StageCScriptedProvider([.decision(.toolCalls(
            ProviderTurnMessage(role: .assistant, toolCalls: [StageCTestSupport.editCall(id: "reject-edit")]),
            [StageCTestSupport.editCall(id: "reject-edit")]
        ))])
        let editor = StageCMockEditExecutor(
            targetURL: prepared.targetURL, taskStore: prepared.taskStore,
            taskID: prepared.task.id, outcome: .applied
        )
        let before = try Data(contentsOf: prepared.targetURL)
        let outcome = await makeAgent(
            prepared, provider: provider, editor: editor, approval: .reject
        ).run()
        XCTAssertEqual(outcome, .rejected)
        let editCount = await editor.callCount()
        XCTAssertEqual(editCount, 0)
        XCTAssertEqual(try Data(contentsOf: prepared.targetURL), before)
    }

    func testUnknownWriteColdReopenNeverResendsMutation() async throws {
        let prepared = try await StageCTestSupport.prepare()
        defer { prepared.cleanup() }
        let provider = StageCScriptedProvider([.decision(.toolCalls(
            ProviderTurnMessage(role: .assistant, toolCalls: [StageCTestSupport.editCall(id: "unknown-edit")]),
            [StageCTestSupport.editCall(id: "unknown-edit")]
        ))])
        let editor = StageCMockEditExecutor(
            targetURL: prepared.targetURL, taskStore: prepared.taskStore,
            taskID: prepared.task.id, outcome: .unknown
        )
        let firstOutcome = await makeAgent(
            prepared, provider: provider, editor: editor, approval: .approve
        ).run()
        let firstCount = await editor.callCount()
        XCTAssertEqual(firstOutcome, .reconciliationRequired)
        XCTAssertEqual(firstCount, 1)
        let coldTask = try await prepared.taskStore.snapshot(taskID: prepared.task.id)
        let coldEditor = StageCMockEditExecutor(
            targetURL: prepared.targetURL, taskStore: prepared.taskStore,
            taskID: prepared.task.id, outcome: .applied
        )
        let coldAgent = StageCEditingAgent(
            provider: StageCScriptedProvider([]),
            readExecutor: StageCMockReadExecutor(),
            editExecutor: coldEditor,
            approvalAuthorizer: StageCImmediateApproval(.approve),
            taskStore: prepared.taskStore,
            task: coldTask,
            session: prepared.session,
            workspace: prepared.workspace,
            ruleSet: prepared.ruleSet,
            limits: prepared.limits,
            readLimits: prepared.readLimits
        )
        let coldOutcome = await coldAgent.run()
        let coldCount = await coldEditor.callCount()
        XCTAssertEqual(coldOutcome, .reconciliationRequired)
        XCTAssertEqual(coldCount, 0)
    }

    func testMixedEditAndReadGetsOriginalIDFeedbackAndZeroExecutorIOBeforeCorrection() async throws {
        let prepared = try await StageCTestSupport.prepare()
        defer { prepared.cleanup() }
        let mixedEdit = StageCTestSupport.editCall(id: "mixed-edit")
        let mixedRead = StageCTestSupport.call(
            id: "mixed-read", name: "read", arguments: ["path": StageCTestSupport.targetPath]
        )
        let correct = StageCTestSupport.editCall(id: "correct-edit")
        let provider = StageCScriptedProvider([
            .decision(.toolCalls(
                ProviderTurnMessage(role: .assistant, toolCalls: [mixedEdit, mixedRead]),
                [mixedEdit, mixedRead]
            )),
            .decision(.toolCalls(
                ProviderTurnMessage(role: .assistant, toolCalls: [correct]), [correct]
            )),
            .decision(.finish(ProviderTurnMessage(role: .assistant, content: "done")))
        ])
        let editor = StageCMockEditExecutor(
            targetURL: prepared.targetURL, taskStore: prepared.taskStore,
            taskID: prepared.task.id, outcome: .applied
        )
        guard case .completed = await makeAgent(
            prepared, provider: provider, editor: editor, approval: .approve
        ).run() else { return XCTFail("corrected edit did not complete") }
        let editCount = await editor.callCount()
        XCTAssertEqual(editCount, 1)
        let requests = await provider.requests()
        XCTAssertTrue(requests.dropFirst().first?.messages.contains(where: {
            $0.toolCallID == "mixed-edit" && $0.content?.contains("not_executed") == true
        }) == true)
        XCTAssertTrue(requests.dropFirst().first?.messages.contains(where: {
            $0.toolCallID == "mixed-read" && $0.content?.contains("not_executed") == true
        }) == true)
    }

    func testCompletedColdReopenCreatesZeroProviderAndExecutorAttempts() async throws {
        let prepared = try await StageCTestSupport.prepare()
        defer { prepared.cleanup() }
        let fixedNow = Date(timeIntervalSince1970: 4_000.123_456)
        let provider = StageCScriptedProvider([
            .decision(.toolCalls(
                ProviderTurnMessage(role: .assistant, toolCalls: [StageCTestSupport.editCall(id: "complete-edit")]),
                [StageCTestSupport.editCall(id: "complete-edit")]
            )),
            .decision(.finish(ProviderTurnMessage(role: .assistant, content: "done")))
        ])
        let editor = StageCMockEditExecutor(
            targetURL: prepared.targetURL, taskStore: prepared.taskStore,
            taskID: prepared.task.id, outcome: .applied
        )
        let agent = makeAgent(
            prepared, provider: provider, editor: editor, approval: .approve,
            now: { fixedNow }
        )
        let firstOutcome = await agent.run()
        guard case let .completed(first) = firstOutcome else {
            let snapshot = try await prepared.taskStore.snapshot(taskID: prepared.task.id)
            return XCTFail("not complete: outcome=\(firstOutcome) \(diagnostic(snapshot))")
        }
        let beforeSnapshot = try await prepared.taskStore.snapshot(taskID: prepared.task.id)
        let durableCompletion = try XCTUnwrap(beforeSnapshot.completion)
        XCTAssertEqual(first, durableCompletion)
        let before = beforeSnapshot.attempts.count
        let task = try await prepared.taskStore.snapshot(taskID: prepared.task.id)
        let coldProvider = StageCScriptedProvider([])
        let coldEditor = StageCMockEditExecutor(
            targetURL: prepared.targetURL, taskStore: prepared.taskStore,
            taskID: prepared.task.id, outcome: .applied
        )
        let cold = StageCEditingAgent(
            provider: coldProvider, readExecutor: StageCMockReadExecutor(),
            editExecutor: coldEditor, approvalAuthorizer: StageCImmediateApproval(.approve),
            taskStore: prepared.taskStore, task: task, session: prepared.session,
            workspace: prepared.workspace, ruleSet: prepared.ruleSet,
            limits: prepared.limits, readLimits: prepared.readLimits
        )
        let coldOutcome = await cold.run()
        let providerCount = await coldProvider.callCount()
        let editCount = await coldEditor.callCount()
        let afterSnapshot = try await prepared.taskStore.snapshot(taskID: prepared.task.id)
        let after = afterSnapshot.attempts.count
        XCTAssertEqual(coldOutcome, .completed(first))
        XCTAssertEqual(providerCount, 0)
        XCTAssertEqual(editCount, 0)
        XCTAssertEqual(after, before)
    }

    func testPendingApprovalColdReopenRequiresNewNonceAndExplicitReconfirmation() async throws {
        let prepared = try await StageCTestSupport.prepare()
        defer { prepared.cleanup() }
        let proposal = try prepared.policy.proposeEdit([
            StageCTestSupport.editCall(id: "pending-cold-edit")
        ], previouslyUsedIDs: [], baseline: try prepared.policy.captureWorkspaceBaseline())
        let oldRequest = try prepared.policy.approvalRequest(
            for: proposal,
            now: Date(timeIntervalSince1970: 4_000),
            nonce: UUID()
        )
        _ = try await prepared.taskStore.update(
            taskID: prepared.task.id,
            phase: .pendingApproval,
            proposal: proposal,
            approval: .init(
                request: oldRequest,
                state: .pending,
                recordedAt: oldRequest.createdAt,
                grant: nil
            )
        )
        let provider = StageCScriptedProvider([
            .decision(.finish(ProviderTurnMessage(role: .assistant, content: "done")))
        ])
        let editor = StageCMockEditExecutor(
            targetURL: prepared.targetURL,
            taskStore: prepared.taskStore,
            taskID: prepared.task.id,
            outcome: .applied
        )
        let outcome = await StageCEditingAgent(
            provider: provider,
            readExecutor: StageCMockReadExecutor(),
            editExecutor: editor,
            approvalAuthorizer: StageCImmediateApproval(.approve),
            taskStore: prepared.taskStore,
            task: try await prepared.taskStore.snapshot(taskID: prepared.task.id),
            session: prepared.session,
            workspace: prepared.workspace,
            ruleSet: prepared.ruleSet,
            limits: prepared.limits,
            readLimits: prepared.readLimits
        ).run()
        guard case .completed = outcome else { return XCTFail("pending approval did not resume") }
        let snapshot = try await prepared.taskStore.snapshot(taskID: prepared.task.id)
        let consumed = try XCTUnwrap(snapshot.approvals.last(where: { $0.state == .consumed }))
        let editCount = await editor.callCount()
        let providerCount = await provider.callCount()
        XCTAssertNotEqual(consumed.request.nonce, oldRequest.nonce)
        XCTAssertEqual(editCount, 1)
        XCTAssertEqual(providerCount, 1)
        XCTAssertTrue(snapshot.approvals.contains { $0.request.requestID == oldRequest.requestID && $0.state == .cancelled })
    }

    func testReliableMutationSuccessColdReopenVerifiesWithoutRepeatingWrite() async throws {
        let prepared = try await StageCTestSupport.prepare()
        defer { prepared.cleanup() }
        let proposal = try prepared.policy.proposeEdit([
            StageCTestSupport.editCall(id: "reliable-mutation")
        ], previouslyUsedIDs: [], baseline: try prepared.policy.captureWorkspaceBaseline())
        let request = try prepared.policy.approvalRequest(for: proposal)
        let grant = StageCApprovalGrant(
            requestID: request.requestID,
            requestBindingSHA256: request.bindingSHA256,
            nonce: request.nonce,
            approvedAt: request.createdAt
        )
        try StageCTestSupport.applyProposal(proposal, targetURL: prepared.targetURL)
        let operationID = UUID()
        let attemptID = UUID()
        let facts = StageCExecutorFacts(
            rootExitObserved: true,
            stdoutEOFObserved: true,
            stderrEOFObserved: true,
            finalStateKind: "exited",
            finalStateValue: 0,
            truncated: false
        )
        _ = try await prepared.taskStore.update(
            taskID: prepared.task.id,
            phase: .mutating,
            proposal: proposal,
            approval: .init(
                request: request,
                state: .pending,
                recordedAt: request.createdAt,
                grant: nil
            ),
            attempt: .init(
                taskID: prepared.task.id,
                operationID: operationID,
                attemptID: attemptID,
                ioKind: .mutationExecutor,
                inputSHA256: proposal.proposalSHA256,
                toolCallID: proposal.toolCallID,
                recordedAt: request.createdAt,
                phase: .intentRecorded,
                resultSHA256: nil,
                facts: nil
            )
        )
        _ = try await prepared.taskStore.update(
            taskID: prepared.task.id,
            phase: .approved,
            approval: .init(
                request: request,
                state: .approved,
                recordedAt: request.createdAt,
                grant: grant
            )
        )
        _ = try await prepared.taskStore.update(
            taskID: prepared.task.id,
            phase: .mutating,
            approval: .init(
                request: request,
                state: .consumed,
                recordedAt: request.createdAt,
                grant: grant
            )
        )
        _ = try await prepared.taskStore.update(
            taskID: prepared.task.id,
            attempt: .init(
                taskID: prepared.task.id,
                operationID: operationID,
                attemptID: attemptID,
                ioKind: .mutationExecutor,
                inputSHA256: proposal.proposalSHA256,
                toolCallID: proposal.toolCallID,
                recordedAt: request.createdAt,
                phase: .succeeded,
                resultSHA256: proposal.afterSHA256,
                facts: facts
            )
        )
        let provider = StageCScriptedProvider([
            .decision(.finish(ProviderTurnMessage(role: .assistant, content: "done")))
        ])
        let editor = StageCMockEditExecutor(
            targetURL: prepared.targetURL,
            taskStore: prepared.taskStore,
            taskID: prepared.task.id,
            outcome: .applied
        )
        let outcome = await StageCEditingAgent(
            provider: provider,
            readExecutor: StageCMockReadExecutor(),
            editExecutor: editor,
            approvalAuthorizer: StageCImmediateApproval(.reject),
            taskStore: prepared.taskStore,
            task: try await prepared.taskStore.snapshot(taskID: prepared.task.id),
            session: prepared.session,
            workspace: prepared.workspace,
            ruleSet: prepared.ruleSet,
            limits: prepared.limits,
            readLimits: prepared.readLimits
        ).run()
        guard case .completed = outcome else { return XCTFail("reliable mutation did not resume") }
        let editCount = await editor.callCount()
        XCTAssertEqual(editCount, 0)
        let snapshot = try await prepared.taskStore.snapshot(taskID: prepared.task.id)
        XCTAssertTrue(snapshot.attempts.contains {
            $0.ioKind == .verificationRead && $0.phase == .succeeded
        })
    }

    func testCompletedProjectionWithoutDurableClosureReconcilesWithZeroIO() async throws {
        let prepared = try await StageCTestSupport.prepare()
        defer { prepared.cleanup() }
        let proposal = try prepared.policy.proposeEdit([
            StageCTestSupport.editCall(id: "false-completion")
        ], previouslyUsedIDs: [], baseline: try prepared.policy.captureWorkspaceBaseline())
        let completion = StageCCompletion(
            taskID: prepared.task.id,
            sessionID: prepared.session.id,
            workspaceIdentitySHA256: prepared.task.workspaceIdentitySHA256,
            goalBindingSHA256: prepared.task.goalBindingSHA256,
            ruleSetBindingSHA256: prepared.task.ruleSetBindingSHA256,
            proposalSHA256: proposal.proposalSHA256,
            finalTreeSHA256: proposal.expectedAfterTreeSHA256,
            completedAt: Date()
        )
        _ = try await prepared.taskStore.update(
            taskID: prepared.task.id,
            phase: .completed,
            proposal: proposal,
            completion: completion
        )
        let provider = StageCScriptedProvider([])
        let editor = StageCMockEditExecutor(
            targetURL: prepared.targetURL,
            taskStore: prepared.taskStore,
            taskID: prepared.task.id,
            outcome: .applied
        )
        let outcome = await StageCEditingAgent(
            provider: provider,
            readExecutor: StageCMockReadExecutor(),
            editExecutor: editor,
            approvalAuthorizer: StageCImmediateApproval(.approve),
            taskStore: prepared.taskStore,
            task: try await prepared.taskStore.snapshot(taskID: prepared.task.id),
            session: prepared.session,
            workspace: prepared.workspace,
            ruleSet: prepared.ruleSet,
            limits: prepared.limits,
            readLimits: prepared.readLimits
        ).run()
        XCTAssertEqual(outcome, .reconciliationRequired)
        let providerCount = await provider.callCount()
        let editCount = await editor.callCount()
        XCTAssertEqual(providerCount, 0)
        XCTAssertEqual(editCount, 0)
    }

    func testReliableProviderTerminalWithoutTypedOutcomeReconcilesWithZeroRetry() async throws {
        let prepared = try await StageCTestSupport.prepare()
        defer { prepared.cleanup() }
        let operationID = UUID()
        let attemptID = UUID()
        let input = ProviderDigest.sha256Hex("provider-request")
        _ = try await prepared.taskStore.update(
            taskID: prepared.task.id,
            phase: .running,
            attempt: .init(
                taskID: prepared.task.id,
                operationID: operationID,
                attemptID: attemptID,
                ioKind: .provider,
                inputSHA256: input,
                toolCallID: nil,
                recordedAt: Date(),
                phase: .intentRecorded,
                resultSHA256: nil,
                facts: nil
            )
        )
        _ = try await prepared.taskStore.update(
            taskID: prepared.task.id,
            attempt: .init(
                taskID: prepared.task.id,
                operationID: operationID,
                attemptID: attemptID,
                ioKind: .provider,
                inputSHA256: input,
                toolCallID: nil,
                recordedAt: Date(),
                phase: .succeeded,
                resultSHA256: ProviderDigest.sha256Hex("stage_c_provider_tool_calls"),
                facts: nil
            )
        )
        let provider = StageCScriptedProvider([])
        let editor = StageCMockEditExecutor(
            targetURL: prepared.targetURL,
            taskStore: prepared.taskStore,
            taskID: prepared.task.id,
            outcome: .applied
        )
        let outcome = await StageCEditingAgent(
            provider: provider,
            readExecutor: StageCMockReadExecutor(),
            editExecutor: editor,
            approvalAuthorizer: StageCImmediateApproval(.approve),
            taskStore: prepared.taskStore,
            task: try await prepared.taskStore.snapshot(taskID: prepared.task.id),
            session: prepared.session,
            workspace: prepared.workspace,
            ruleSet: prepared.ruleSet,
            limits: prepared.limits,
            readLimits: prepared.readLimits
        ).run()
        XCTAssertEqual(outcome, .reconciliationRequired)
        let providerCount = await provider.callCount()
        let editCount = await editor.callCount()
        XCTAssertEqual(providerCount, 0)
        XCTAssertEqual(editCount, 0)
    }

    func testReliableCompletionCheckWithoutFinalRecordReconcilesWithoutRepeatingIO() async throws {
        let prepared = try await StageCTestSupport.prepare()
        defer { prepared.cleanup() }
        let provider = StageCScriptedProvider([
            .decision(.toolCalls(
                ProviderTurnMessage(
                    role: .assistant,
                    toolCalls: [StageCTestSupport.editCall(id: "completion-window")]
                ),
                [StageCTestSupport.editCall(id: "completion-window")]
            )),
            .decision(.finish(ProviderTurnMessage(role: .assistant, content: "done")))
        ])
        let editor = StageCMockEditExecutor(
            targetURL: prepared.targetURL,
            taskStore: prepared.taskStore,
            taskID: prepared.task.id,
            outcome: .applied
        )
        let setupOutcome = await makeAgent(
            prepared,
            provider: provider,
            editor: editor,
            approval: .approve
        ).run()
        guard case .completed = setupOutcome else {
            let snapshot = try await prepared.taskStore.snapshot(taskID: prepared.task.id)
            return XCTFail("setup did not complete: outcome=\(setupOutcome) \(diagnostic(snapshot))")
        }
        var interrupted = try await prepared.taskStore.snapshot(taskID: prepared.task.id)
        interrupted.phase = .running
        interrupted.completion = nil
        try await prepared.taskStore.record(interrupted)
        let coldProvider = StageCScriptedProvider([])
        let coldEditor = StageCMockEditExecutor(
            targetURL: prepared.targetURL,
            taskStore: prepared.taskStore,
            taskID: prepared.task.id,
            outcome: .applied
        )
        let beforeAttempts = interrupted.attempts.count
        let outcome = await StageCEditingAgent(
            provider: coldProvider,
            readExecutor: StageCMockReadExecutor(),
            editExecutor: coldEditor,
            approvalAuthorizer: StageCImmediateApproval(.approve),
            taskStore: prepared.taskStore,
            task: interrupted,
            session: prepared.session,
            workspace: prepared.workspace,
            ruleSet: prepared.ruleSet,
            limits: prepared.limits,
            readLimits: prepared.readLimits
        ).run()
        XCTAssertEqual(outcome, .reconciliationRequired)
        let providerCount = await coldProvider.callCount()
        let editCount = await coldEditor.callCount()
        XCTAssertEqual(providerCount, 0)
        XCTAssertEqual(editCount, 0)
        let after = try await prepared.taskStore.snapshot(taskID: prepared.task.id)
        XCTAssertEqual(after.attempts.count, beforeAttempts)
    }

    private func makeAgent(
        _ prepared: StageCTestPrepared,
        provider: StageCScriptedProvider,
        editor: StageCMockEditExecutor,
        approval: StageCImmediateApproval.Mode,
        now: @escaping @Sendable () -> Date = Date.init
    ) -> StageCEditingAgent {
        StageCEditingAgent(
            provider: provider, readExecutor: StageCMockReadExecutor(),
            editExecutor: editor, approvalAuthorizer: StageCImmediateApproval(approval),
            taskStore: prepared.taskStore, task: prepared.task, session: prepared.session,
            workspace: prepared.workspace, ruleSet: prepared.ruleSet,
            limits: prepared.limits, readLimits: prepared.readLimits, now: now
        )
    }

    private func diagnostic(_ record: StageCTaskRecord) -> String {
        let attempts = Dictionary(grouping: record.attempts, by: { $0.ioKind.rawValue })
            .mapValues(\.count)
        return "phase=\(record.phase.rawValue) finish=\(record.providerFinishObserved) "
            + "approvals=\(record.approvals.map { $0.state.rawValue }) attempts=\(attempts)"
    }
}

actor StageCScriptedProvider: AgentInferenceProvider {
    nonisolated let providerID = "stage-c-test"
    private var outcomes: [ProviderInferenceOutcome]
    private var captured: [ProviderInferenceRequest] = []

    init(_ outcomes: [ProviderInferenceOutcome]) { self.outcomes = outcomes }

    func infer(request: ProviderInferenceRequest, requestID: UUID) async -> ProviderInferenceOutcome {
        captured.append(request)
        guard !outcomes.isEmpty else { return .unknown(.reconciliationRequired) }
        return outcomes.removeFirst()
    }

    func callCount() -> Int { captured.count }
    func requests() -> [ProviderInferenceRequest] { captured }
}

struct StageCMockReadExecutor: StageBReadOnlyExecuting, Sendable {
    func execute(_ tool: StageBAuthorizedTool) async -> StageBExecutorOutcome { .failure(.rejected) }
}

struct StageCImmediateApproval: StageCApprovalAuthorizing, Sendable {
    enum Mode: Sendable { case approve, reject, cancel, expire }
    let mode: Mode
    init(_ mode: Mode) { self.mode = mode }

    func requestApproval(_ request: StageCApprovalRequest) async -> StageCApprovalDecision {
        switch mode {
        case .approve:
            return .approved(.init(
                requestID: request.requestID,
                requestBindingSHA256: request.bindingSHA256,
                nonce: request.nonce,
                approvedAt: request.createdAt
            ))
        case .reject: return .rejected
        case .cancel: return .cancelled
        case .expire: return .expired
        }
    }
}

actor StageCMockEditExecutor: StageCEditExecuting {
    enum Mode { case applied, failure, unknown }
    private let targetURL: URL
    private let taskStore: StageCTaskStore
    private let taskID: UUID
    private let outcome: Mode
    private var calls = 0
    private var sawIntent = false

    init(targetURL: URL, taskStore: StageCTaskStore, taskID: UUID, outcome: Mode) {
        self.targetURL = targetURL
        self.taskStore = taskStore
        self.taskID = taskID
        self.outcome = outcome
    }

    func execute(_ proposal: StageCEditProposal) async -> StageCExecutorOutcome {
        calls += 1
        if let snapshot = try? await taskStore.snapshot(taskID: taskID) {
            sawIntent = snapshot.attempts.contains {
                $0.ioKind == .mutationExecutor && $0.phase == .intentRecorded
                    && $0.inputSHA256 == proposal.proposalSHA256
            }
        }
        let facts = StageCExecutorFacts(
            rootExitObserved: true, stdoutEOFObserved: true, stderrEOFObserved: true,
            finalStateKind: "exited", finalStateValue: 0, truncated: false
        )
        switch outcome {
        case .applied:
            do { try StageCTestSupport.applyProposal(proposal, targetURL: targetURL) }
            catch { return .failure(facts) }
            return .applied(facts)
        case .failure: return .failure(facts)
        case .unknown: return .unknown(nil)
        }
    }

    func callCount() -> Int { calls }
    func intentWasVisible() -> Bool { sawIntent }
}
