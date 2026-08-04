import Foundation
import XCTest
@testable import Wuji

final class WujiStageDRecoveryTests: XCTestCase {
    func testApprovalBindsTaskOperationAttemptCommandArgvCwdRiskAndExpiry() async throws {
        let prepared = try await StageDTestSupport.prepare()
        defer { prepared.cleanup() }
        let approval = StageDImmediateApproval(.approve)
        let executor = StageDMockExecutor(store: prepared.store, taskID: prepared.task.id, mode: .success)
        guard case .completed = await prepared.agent(executor: executor, approval: approval).run(
            command: prepared.writeCommand,
            cwd: "."
        ) else { return XCTFail("approved command did not complete") }
        let snapshot = try await prepared.store.snapshot(taskID: prepared.task.id)
        let consumed = try XCTUnwrap(snapshot.approvals.last { $0.state == .consumed })
        let command = try XCTUnwrap(snapshot.attempts.last { $0.kind == .command }?.command)
        XCTAssertEqual(consumed.request.taskID, prepared.task.id)
        XCTAssertEqual(consumed.request.commandBindingSHA256, command.bindingSHA256)
        XCTAssertEqual(consumed.request.cwd, "")
        XCTAssertEqual(consumed.request.risk, .workspaceWrite)
        XCTAssertEqual(consumed.request.argumentsSHA256, ProviderDigest.sha256Hex(
            command.parsed.arguments.joined(separator: "\u{0}")
        ))
        XCTAssertLessThanOrEqual(consumed.grant?.approvedAt ?? .distantFuture, consumed.request.expiresAt)
    }

    func testRejectedAndTamperedApprovalPerformZeroExecutorIO() async throws {
        for mode in [StageDImmediateApproval.Mode.reject, .tamper] {
            let prepared = try await StageDTestSupport.prepare()
            defer { prepared.cleanup() }
            let executor = StageDMockExecutor(store: prepared.store, taskID: prepared.task.id, mode: .success)
            let outcome = await prepared.agent(
                executor: executor,
                approval: StageDImmediateApproval(mode)
            ).run(command: prepared.writeCommand, cwd: ".")
            guard case .rejected = outcome else { return XCTFail("approval denial not preserved") }
            let calls = await executor.callCount()
            let attempts = try await prepared.store.snapshot(taskID: prepared.task.id).attempts
            XCTAssertEqual(calls, 0)
            XCTAssertTrue(attempts.isEmpty)
        }
    }

    func testDurableIntentPrecedesISHIOAndSameWorkspaceGateSerializes() async throws {
        let prepared = try await StageDTestSupport.prepare()
        defer { prepared.cleanup() }
        let executor = StageDMockExecutor(store: prepared.store, taskID: prepared.task.id, mode: .success)
        guard case .completed = await prepared.agent(
            executor: executor,
            approval: StageDImmediateApproval(.approve)
        ).run(command: prepared.writeCommand, cwd: ".") else {
            return XCTFail("command did not complete")
        }
        let intentVisible = await executor.intentWasVisible()
        XCTAssertTrue(intentVisible)
        let first = await StageDWorkspaceGate.shared.acquire(prepared.task.workspaceIdentitySHA256)
        XCTAssertNotNil(first)
        let second = await StageDWorkspaceGate.shared.acquire(prepared.task.workspaceIdentitySHA256)
        XCTAssertNil(second)
        if let first {
            await StageDWorkspaceGate.shared.release(prepared.task.workspaceIdentitySHA256, token: first)
        }
        let next = await StageDWorkspaceGate.shared.acquire(prepared.task.workspaceIdentitySHA256)
        XCTAssertNotNil(next)
        if let next {
            await StageDWorkspaceGate.shared.release(prepared.task.workspaceIdentitySHA256, token: next)
        }
    }

    func testUnknownCommandColdRestoreNeverResendsWriteNetworkInstallOrProvider() async throws {
        let prepared = try await StageDTestSupport.prepare()
        defer { prepared.cleanup() }
        let unknown = StageDMockExecutor(store: prepared.store, taskID: prepared.task.id, mode: .unknown)
        let first = await prepared.agent(
            executor: unknown,
            approval: StageDImmediateApproval(.approve)
        ).run(command: prepared.writeCommand, cwd: ".")
        XCTAssertEqual(first, .reconciliationRequired)
        let firstCalls = await unknown.callCount()
        XCTAssertEqual(firstCalls, 1)

        let coldTask = try await prepared.store.snapshot(taskID: prepared.task.id)
        let cold = StageDMockExecutor(store: prepared.store, taskID: prepared.task.id, mode: .success)
        let coldAgent = prepared.agent(
            task: coldTask,
            executor: cold,
            approval: StageDImmediateApproval(.approve)
        )
        let coldOutcome = await coldAgent.run(command: prepared.writeCommand, cwd: ".")
        let coldCalls = await cold.callCount()
        XCTAssertEqual(coldOutcome, .reconciliationRequired)
        XCTAssertEqual(coldCalls, 0)
        let snapshot = try await prepared.store.snapshot(taskID: prepared.task.id)
        XCTAssertEqual(snapshot.attempts.filter { $0.phase == .intentRecorded }.count, 1)
    }

    func testCancelledDrainedOrTruncatedUnknownRemainsReconciliationRequired() async throws {
        let prepared = try await StageDTestSupport.prepare()
        defer { prepared.cleanup() }
        let executor = StageDMockExecutor(
            store: prepared.store,
            taskID: prepared.task.id,
            mode: .unknownCancelled
        )
        let outcome = await prepared.agent(
            executor: executor,
            approval: StageDImmediateApproval(.approve)
        ).run(command: prepared.writeCommand, cwd: ".")
        XCTAssertEqual(outcome, .reconciliationRequired)
        let snapshot = try await prepared.store.snapshot(taskID: prepared.task.id)
        let result = try XCTUnwrap(snapshot.attempts.last?.result)
        XCTAssertTrue(result.facts[0].cancellationRequested)
        XCTAssertTrue(result.facts[0].truncated)
        XCTAssertEqual(result.facts[0].processTreeState, .descendantsRemain)
        XCTAssertNil(snapshot.completion)
    }

    func testReliableProviderDecisionResumesWithoutProviderResend() async throws {
        let prepared = try await StageDTestSupport.prepare()
        defer { prepared.cleanup() }
        let task = try await prepared.store.snapshot(taskID: prepared.task.id)
        let operationID = UUID(), attemptID = UUID()
        let input = StageDProviderContract.inputSHA256(task: task)
        let intent = StageDAttemptEvidence(
            taskID: task.id, operationID: operationID, attemptID: attemptID,
            kind: .provider, phase: .intentRecorded, inputSHA256: input,
            recordedAt: Date(), command: nil, approvalBindingSHA256: nil,
            providerDecision: nil, result: nil, resultSHA256: nil
        )
        _ = try await prepared.store.appendAttempt(taskID: task.id, evidence: intent, phase: .ready)
        let decision = StageDProviderDecision(
            toolCallID: "durable-stage-d",
            command: prepared.writeCommand,
            cwd: ".",
            assistantSHA256: ProviderDigest.sha256Hex("assistant")
        )
        let terminal = StageDAttemptEvidence(
            taskID: task.id, operationID: operationID, attemptID: attemptID,
            kind: .provider, phase: .succeeded, inputSHA256: input,
            recordedAt: Date().addingTimeInterval(1), command: nil,
            approvalBindingSHA256: nil, providerDecision: decision, result: nil,
            resultSHA256: try XCTUnwrap(StageDTaskStore.digest(decision))
        )
        _ = try await prepared.store.appendAttempt(taskID: task.id, evidence: terminal, phase: .ready)
        let provider = StageDScriptedProvider([])
        let executor = StageDMockExecutor(store: prepared.store, taskID: task.id, mode: .success)
        let agent = StageDCommandAgent(
            provider: provider,
            executor: executor,
            approvalAuthorizer: StageDImmediateApproval(.approve),
            store: prepared.store,
            task: try await prepared.store.snapshot(taskID: task.id),
            policy: prepared.policy,
            requireProvider: true
        )
        guard case .completed = await agent.runModelCommand() else {
            return XCTFail("durable provider decision did not resume")
        }
        let providerCalls = await provider.callCount()
        let executorCalls = await executor.callCount()
        XCTAssertEqual(providerCalls, 0)
        XCTAssertEqual(executorCalls, 1)
    }

    func testCompletedColdRestoreCreatesZeroProviderCommandCloneInstallOrWriteAttempts() async throws {
        let prepared = try await StageDTestSupport.prepare()
        defer { prepared.cleanup() }
        let executor = StageDMockExecutor(store: prepared.store, taskID: prepared.task.id, mode: .success)
        let firstAgent = prepared.agent(executor: executor, approval: StageDImmediateApproval(.approve))
        guard case let .completed(first) = await firstAgent.run(command: prepared.writeCommand, cwd: ".") else {
            return XCTFail("initial command did not complete")
        }
        let before = try await prepared.store.snapshot(taskID: prepared.task.id)
        let coldExecutor = StageDMockExecutor(store: prepared.store, taskID: prepared.task.id, mode: .success)
        let coldProvider = StageDScriptedProvider([])
        let coldAgent = StageDCommandAgent(
            provider: coldProvider, executor: coldExecutor,
            approvalAuthorizer: StageDImmediateApproval(.approve),
            store: prepared.store, task: before, policy: prepared.policy,
            requireProvider: false
        )
        let coldOutcome = await coldAgent.runModelCommand()
        let coldProviderCalls = await coldProvider.callCount()
        let coldExecutorCalls = await coldExecutor.callCount()
        XCTAssertEqual(coldOutcome, .completed(first))
        XCTAssertEqual(coldProviderCalls, 0)
        XCTAssertEqual(coldExecutorCalls, 0)
        XCTAssertEqual(
            try await prepared.store.snapshot(taskID: prepared.task.id).attempts.count,
            before.attempts.count
        )
    }

    func testModelFinishClaimCannotCompleteWithoutCommandEvidence() async throws {
        let prepared = try await StageDTestSupport.prepare()
        defer { prepared.cleanup() }
        let provider = StageDScriptedProvider([
            .decision(.finish(.init(role: .assistant, content: "completed")))
        ])
        let executor = StageDMockExecutor(store: prepared.store, taskID: prepared.task.id, mode: .success)
        let agent = StageDCommandAgent(
            provider: provider, executor: executor,
            approvalAuthorizer: StageDImmediateApproval(.approve),
            store: prepared.store, task: prepared.task, policy: prepared.policy,
            requireProvider: true
        )
        guard case .rejected(.providerPolicy) = await agent.runModelCommand() else {
            return XCTFail("model claim established completion")
        }
        let calls = await executor.callCount()
        let completion = try await prepared.store.snapshot(taskID: prepared.task.id).completion
        XCTAssertEqual(calls, 0)
        XCTAssertNil(completion)
    }

    func testCodeOwnedCompletionRejectsWrongCloneHeadAndIncompleteProcessFacts() throws {
        var record = StageDTestSupport.emptyRecord(expectation: .init(
            kind: .exactClone, relativePath: nil, expectedSHA256: nil,
            cloneTarget: StageDEnvironmentLock.cloneTarget,
            cloneRemote: StageDEnvironmentLock.cloneURL,
            cloneHEAD: StageDEnvironmentLock.acceptedStageCCommit
        ))
        let command = StageDTestSupport.cloneCommand(identity: record.workspaceIdentitySHA256)
        let result = StageDTestSupport.result(
            command: command,
            facts: StageDTestSupport.facts(stdoutEOF: false),
            cloneRemote: StageDEnvironmentLock.cloneURL,
            cloneHEAD: String(repeating: "0", count: 40)
        )
        let op = UUID(), attempt = UUID()
        record.attempts = [
            StageDTestSupport.attempt(record: record, command: command, op: op, attempt: attempt, phase: .intentRecorded),
            StageDTestSupport.attempt(record: record, command: command, op: op, attempt: attempt, phase: .succeeded, result: result)
        ]
        XCTAssertNil(StageDCompletionVerifier.verify(
            record: record, result: result, command: command,
            operationID: op, attemptID: attempt, approvalBindingSHA256: nil,
            requireProvider: false, now: Date()
        ))
    }
}

final class StageDTestPrepared {
    let base: StageCTestPrepared
    let store: StageDTaskStore
    let task: StageDTaskRecord
    let write: StageDBoundedWrite
    let policy: StageDCommandPolicy

    var writeCommand: String { "sed -i \(write.sedExpression) \(write.relativePath)" }

    init(base: StageCTestPrepared, store: StageDTaskStore, task: StageDTaskRecord, write: StageDBoundedWrite) {
        self.base = base
        self.store = store
        self.task = task
        self.write = write
        policy = StageDCommandPolicy(
            workspaceIdentitySHA256: task.workspaceIdentitySHA256,
            write: write
        )
    }

    func cleanup() { base.cleanup() }

    func agent(
        task: StageDTaskRecord? = nil,
        executor: StageDCommandExecuting,
        approval: StageDApprovalAuthorizing
    ) -> StageDCommandAgent {
        StageDCommandAgent(
            provider: nil, executor: executor, approvalAuthorizer: approval,
            store: store, task: task ?? self.task, policy: policy,
            requireProvider: false
        )
    }
}

enum StageDTestSupport {
    static func prepare() async throws -> StageDTestPrepared {
        let base = try await StageCTestSupport.prepare()
        let path = "Sources/StageD.txt"
        let before = Data("channel=preview\ntoolset=base\n".utf8)
        let after = Data("channel=stable\ntoolset=base\n".utf8)
        try before.write(to: base.workspace.canonicalRootURL.appendingPathComponent(path))
        let write = StageDBoundedWrite(
            relativePath: path,
            expectedBeforeLine: "channel=preview",
            replacementLine: "channel=stable",
            expectedBeforeSHA256: ProviderDigest.sha256Hex(before),
            expectedAfterSHA256: ProviderDigest.sha256Hex(after)
        )
        let store = try StageDTaskStore(
            rootURL: base.container.appendingPathComponent("StageD"),
            cloneRootURL: base.container.appendingPathComponent("StageDClones")
        )
        let task = try await store.create(
            session: base.session,
            workspace: base.workspace,
            ruleSet: base.ruleSet,
            write: write,
            expectation: .init(
                kind: .exactFile, relativePath: path,
                expectedSHA256: write.expectedAfterSHA256,
                cloneTarget: nil, cloneRemote: nil, cloneHEAD: nil
            )
        )
        return .init(base: base, store: store, task: task, write: write)
    }

    static func facts(
        stdoutEOF: Bool = true,
        truncated: Bool = false,
        cancelled: Bool = false,
        tree: StageDProcessTreeState = .quiescent
    ) -> StageDProcessFacts {
        .init(
            rootExitObserved: true, finalStateKind: "exited", finalStateValue: 0,
            stdoutEOFObserved: stdoutEOF, stderrEOFObserved: true,
            stdoutByteCount: 0, stderrByteCount: 0,
            stdoutSHA256: ProviderDigest.sha256Hex(Data()),
            stderrSHA256: ProviderDigest.sha256Hex(Data()),
            truncated: truncated, cancellationRequested: cancelled,
            processTreeState: tree,
            activeDescendantCount: tree == .descendantsRemain ? 1 : 0
        )
    }

    static func result(
        command: StageDAuthorizedCommand,
        facts: StageDProcessFacts = StageDTestSupport.facts(),
        cloneRemote: String? = nil,
        cloneHEAD: String? = nil
    ) -> StageDCommandResult {
        let verification = "stage-d-test-verification"
        return .init(
            commandBindingSHA256: command.bindingSHA256,
            facts: [facts], stdout: "", stderr: "",
            outputProjectionTruncated: false,
            verification: verification,
            verificationSHA256: ProviderDigest.sha256Hex(verification),
            cloneRemote: cloneRemote, cloneHEAD: cloneHEAD,
            cloneEntryCount: cloneRemote == nil ? nil : 1,
            cloneByteCount: cloneRemote == nil ? nil : 1,
            toolVersions: [:]
        )
    }

    static func emptyRecord(expectation: StageDCompletionExpectation) -> StageDTaskRecord {
        .init(
            id: UUID(), sessionID: UUID(), importID: UUID(), workspaceID: UUID(),
            workspaceIdentitySHA256: String(repeating: "a", count: 64),
            workspaceRootSHA256: String(repeating: "b", count: 64),
            goalBindingSHA256: String(repeating: "c", count: 64),
            ruleSetBindingSHA256: String(repeating: "d", count: 64),
            cloneRootSHA256: String(repeating: "e", count: 64),
            write: nil, expectation: expectation,
            createdAt: Date(), updatedAt: Date(), phase: .verifying,
            approvals: [], attempts: [], completion: nil
        )
    }

    static func cloneCommand(identity: String) -> StageDAuthorizedCommand {
        let original = "git clone --depth 8 --no-tags --single-branch \(StageDEnvironmentLock.cloneURL) \(StageDEnvironmentLock.cloneTarget)"
        return .init(
            parsed: .init(
                original: original, executable: "git",
                arguments: ["clone", "--depth", "8", "--no-tags", "--single-branch",
                            StageDEnvironmentLock.cloneURL, StageDEnvironmentLock.cloneTarget],
                cwd: ""
            ),
            risk: .network, executionRoot: .cloneRoot,
            workspaceIdentitySHA256: identity, write: nil,
            cloneTarget: StageDEnvironmentLock.cloneTarget
        )
    }

    static func attempt(
        record: StageDTaskRecord,
        command: StageDAuthorizedCommand,
        op: UUID,
        attempt: UUID,
        phase: StageDAttemptPhase,
        result: StageDCommandResult? = nil
    ) -> StageDAttemptEvidence {
        .init(
            taskID: record.id, operationID: op, attemptID: attempt,
            kind: .command, phase: phase, inputSHA256: command.bindingSHA256,
            recordedAt: Date(), command: command, approvalBindingSHA256: nil,
            providerDecision: nil, result: result,
            resultSHA256: result.flatMap { StageDTaskStore.digest($0) }
        )
    }
}

actor StageDMockExecutor: StageDCommandExecuting {
    enum Mode { case success, failure, unknown, unknownCancelled }
    private let store: StageDTaskStore
    private let taskID: UUID
    private let mode: Mode
    private var calls = 0
    private var sawIntent = false

    init(store: StageDTaskStore, taskID: UUID, mode: Mode) {
        self.store = store
        self.taskID = taskID
        self.mode = mode
    }

    func execute(_ command: StageDAuthorizedCommand) async -> StageDExecutorOutcome {
        calls += 1
        if let snapshot = try? await store.snapshot(taskID: taskID) {
            sawIntent = snapshot.attempts.contains {
                $0.kind == .command && $0.phase == .intentRecorded && $0.command == command
            }
        }
        switch mode {
        case .success:
            return .succeeded(StageDTestSupport.result(command: command))
        case .failure:
            return .failed(StageDTestSupport.result(command: command, facts: StageDTestSupport.facts(stdoutEOF: false)))
        case .unknown:
            return .unknown(nil)
        case .unknownCancelled:
            return .unknown(StageDTestSupport.result(
                command: command,
                facts: StageDTestSupport.facts(
                    truncated: true, cancelled: true, tree: .descendantsRemain
                )
            ))
        }
    }

    func callCount() -> Int { calls }
    func intentWasVisible() -> Bool { sawIntent }
}

struct StageDImmediateApproval: StageDApprovalAuthorizing, Sendable {
    enum Mode { case approve, reject, tamper }
    let mode: Mode
    init(_ mode: Mode) { self.mode = mode }

    func requestApproval(_ request: StageDApprovalRequest) async -> StageDApprovalDecision {
        switch mode {
        case .approve:
            return .approved(.init(
                requestID: request.requestID,
                requestBindingSHA256: request.bindingSHA256,
                nonce: request.nonce,
                approvedAt: request.createdAt
            ))
        case .reject:
            return .rejected
        case .tamper:
            return .approved(.init(
                requestID: request.requestID,
                requestBindingSHA256: String(repeating: "0", count: 64),
                nonce: request.nonce,
                approvedAt: request.createdAt
            ))
        }
    }
}

actor StageDScriptedProvider: AgentInferenceProvider {
    let providerID = "stage-d-scripted"
    private var outcomes: [ProviderInferenceOutcome]
    private var calls = 0

    init(_ outcomes: [ProviderInferenceOutcome]) { self.outcomes = outcomes }

    func infer(request: ProviderInferenceRequest, requestID: UUID) async -> ProviderInferenceOutcome {
        calls += 1
        guard !outcomes.isEmpty else { return .failure(.emptyResponse) }
        return outcomes.removeFirst()
    }

    func callCount() -> Int { calls }
}
