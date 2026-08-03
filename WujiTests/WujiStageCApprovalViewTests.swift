import XCTest
@testable import Wuji

final class WujiStageCApprovalViewTests: XCTestCase {
    func testApprovalBrokerProjectsPendingAndApproveWithoutFileIO() async throws {
        let prepared = try await StageCTestSupport.prepare()
        defer { prepared.cleanup() }
        let proposal = try prepared.policy.proposeEdit([
            StageCTestSupport.editCall(id: "ui-approve")
        ], previouslyUsedIDs: [], baseline: try prepared.policy.captureWorkspaceBaseline())
        let request = try prepared.policy.approvalRequest(for: proposal)
        let broker = StageCApprovalBroker()
        let before = try Data(contentsOf: prepared.targetURL)
        let decisionTask = Task { await broker.requestApproval(request) }
        try await Task.sleep(nanoseconds: 10_000_000)
        let pending = await broker.snapshot()
        XCTAssertEqual(pending.state, .pending)
        await broker.approve(requestID: request.requestID, nonce: request.nonce, at: request.createdAt)
        guard case .approved = await decisionTask.value else { return XCTFail("not approved") }
        XCTAssertEqual(try Data(contentsOf: prepared.targetURL), before)
    }

    func testApprovalBrokerProjectsRejectAndCancelWithoutChangingExecutionTruth() async throws {
        let prepared = try await StageCTestSupport.prepare()
        defer { prepared.cleanup() }
        let proposal = try prepared.policy.proposeEdit([
            StageCTestSupport.editCall(id: "ui-reject")
        ], previouslyUsedIDs: [], baseline: try prepared.policy.captureWorkspaceBaseline())
        let request = try prepared.policy.approvalRequest(for: proposal)
        let broker = StageCApprovalBroker()
        let before = try Data(contentsOf: prepared.targetURL)
        let task = Task { await broker.requestApproval(request) }
        try await Task.sleep(nanoseconds: 10_000_000)
        await broker.reject(requestID: request.requestID, nonce: request.nonce)
        let decision = await task.value
        let snapshot = try await prepared.taskStore.snapshot(taskID: prepared.task.id)
        XCTAssertEqual(decision, .rejected)
        XCTAssertEqual(snapshot.phase, .ready)

        let cancelRequest = try prepared.policy.approvalRequest(for: proposal)
        let cancelTask = Task { await broker.requestApproval(cancelRequest) }
        try await Task.sleep(nanoseconds: 10_000_000)
        await broker.cancel(requestID: cancelRequest.requestID, nonce: cancelRequest.nonce)
        let cancelled = await cancelTask.value
        XCTAssertEqual(cancelled, .cancelled)
        XCTAssertEqual(try Data(contentsOf: prepared.targetURL), before)
    }

    func testReadingDurableProjectionCannotCreateCompletionOrMutationAttempt() async throws {
        let prepared = try await StageCTestSupport.prepare()
        defer { prepared.cleanup() }
        _ = try await prepared.taskStore.snapshot(taskID: prepared.task.id)
        let after = try await prepared.taskStore.snapshot(taskID: prepared.task.id)
        XCTAssertNil(after.completion)
        XCTAssertFalse(after.attempts.contains { $0.ioKind == .mutationExecutor })
    }

}
