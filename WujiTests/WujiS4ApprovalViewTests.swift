import XCTest
@testable import Wuji

@MainActor
final class WujiS4ApprovalViewTests: XCTestCase {
    func testViewModelProjectsExplicitApprovalAndRejection() async {
        let broker = S4ApprovalBroker()
        let model = S4ApprovalViewModel(broker: broker)
        let observation = Task { await model.observe() }
        defer { observation.cancel() }

        let request = approvalRequest()
        let decision = Task { await broker.requestApproval(request) }
        await waitUntil { model.state == .pending(request) }
        model.approve()
        guard case .approved = await decision.value else {
            return XCTFail("explicit approval was not delivered")
        }
        await waitUntil { model.state == .approved(request) }

        let second = approvalRequest()
        let rejection = Task { await broker.requestApproval(second) }
        await waitUntil { model.state == .pending(second) }
        model.reject()
        let rejectionValue = await rejection.value
        XCTAssertEqual(rejectionValue, .rejected(.rejected))
        await waitUntil { model.state == .rejected(second) }
    }

    func testViewModelProjectsExecutionOutcomeCategories() async {
        let execution = S4ExecutionProjectionBroker()
        let model = S4ApprovalViewModel(
            broker: S4ApprovalBroker(),
            executionBroker: execution
        )
        let observation = Task { await model.observeExecution() }
        defer { observation.cancel() }

        await execution.report(.running)
        await waitUntil { model.state == .running }
        XCTAssertEqual(model.state, .running)
        await execution.report(.reconciliationRequired)
        await waitUntil { model.state == .reconciliationRequired }
        XCTAssertEqual(model.state, .reconciliationRequired)
        await execution.report(.failed)
        await waitUntil { model.state == .failed }
        XCTAssertEqual(model.state, .failed)
        await execution.report(.completed)
        await waitUntil { model.state == .completed }
        XCTAssertEqual(model.state, .completed)
    }

    func testExpiredApprovalFailsClosed() async {
        let broker = S4ApprovalBroker()
        let request = approvalRequest(expiresAt: Date(timeIntervalSince1970: 200))
        let decision = Task { await broker.requestApproval(request) }
        for _ in 0..<50 {
            if (await broker.snapshot()).state == .pendingApproval { break }
            await Task.yield()
        }
        await broker.approve(
            requestID: request.requestID,
            nonce: request.nonce,
            at: Date(timeIntervalSince1970: 201)
        )
        let value = await decision.value
        XCTAssertEqual(value, .rejected(.expired))
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<100 {
            if predicate() { return }
            await Task.yield()
        }
    }

    private func approvalRequest(expiresAt: Date? = nil) -> S4ApprovalRequest {
        let createdAt = expiresAt == nil ? Date() : Date(timeIntervalSince1970: 100)
        return S4ApprovalRequest(
            requestID: UUID(),
            taskID: UUID(),
            workspaceID: String(repeating: "a", count: 64),
            workspaceSnapshotSHA256: String(repeating: "b", count: 64),
            toolCallID: "call-ui",
            relativePath: S4TaskContract.authorizedPath,
            beforeSHA256: S4TaskContract.beforeHash,
            afterSHA256: S4TaskContract.afterHash,
            changeSummarySHA256: S4TaskContract.changeSummaryHash,
            verificationProfile: .s4StatusVerified,
            nonce: UUID(),
            createdAt: createdAt,
            expiresAt: expiresAt ?? createdAt.addingTimeInterval(600)
        )
    }
}
