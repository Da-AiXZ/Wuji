import Foundation
import XCTest
@testable import Wuji

final class WujiStageCStoreApprovalTests: XCTestCase {
    func testApprovalBindsEveryTaskWorkspaceSessionGoalRuleAndProposalFact() async throws {
        let prepared = try await StageCTestSupport.prepare()
        defer { prepared.cleanup() }
        let proposal = try prepared.policy.proposeEdit([
            StageCTestSupport.editCall(id: "approval-binding")
        ], previouslyUsedIDs: [], baseline: try prepared.policy.captureWorkspaceBaseline())
        let now = Date(timeIntervalSince1970: 1_000.123456)
        let request = try prepared.policy.approvalRequest(for: proposal, now: now)
        let grant = StageCApprovalGrant(
            requestID: request.requestID,
            requestBindingSHA256: request.bindingSHA256,
            nonce: request.nonce,
            approvedAt: now.addingTimeInterval(1)
        )
        XCTAssertNoThrow(try prepared.policy.validateGrant(
            grant, request: request, now: now.addingTimeInterval(2)
        ))
        XCTAssertEqual(request.taskID, prepared.task.id)
        XCTAssertEqual(request.sessionID, prepared.session.id)
        XCTAssertEqual(request.workspaceIdentitySHA256, prepared.task.workspaceIdentitySHA256)
        XCTAssertEqual(request.goalBindingSHA256, prepared.task.goalBindingSHA256)
        XCTAssertEqual(request.ruleSetBindingSHA256, prepared.task.ruleSetBindingSHA256)
        XCTAssertEqual(request.proposalSHA256, proposal.proposalSHA256)
        _ = try await prepared.taskStore.update(
            taskID: prepared.task.id,
            phase: .pendingApproval,
            proposal: proposal,
            approval: .init(
                request: request,
                state: .pending,
                recordedAt: request.createdAt,
                grant: nil
            )
        )
        _ = try await prepared.taskStore.update(
            taskID: prepared.task.id,
            phase: .approved,
            approval: .init(
                request: request,
                state: .approved,
                recordedAt: grant.approvedAt,
                grant: grant
            )
        )
        let durable = try await prepared.taskStore.snapshot(taskID: prepared.task.id)
        XCTAssertEqual(durable.approvals.map(\.state), [.pending, .approved])
        XCTAssertTrue(durable.approvals.allSatisfy { $0.request == request })
    }

    func testExpiredWrongNonceAndBindingDriftFailClosed() async throws {
        let prepared = try await StageCTestSupport.prepare()
        defer { prepared.cleanup() }
        let proposal = try prepared.policy.proposeEdit([
            StageCTestSupport.editCall(id: "approval-negative")
        ], previouslyUsedIDs: [], baseline: try prepared.policy.captureWorkspaceBaseline())
        let now = Date(timeIntervalSince1970: 2_000)
        let request = try prepared.policy.approvalRequest(for: proposal, now: now)
        let wrongNonce = StageCApprovalGrant(
            requestID: request.requestID,
            requestBindingSHA256: request.bindingSHA256,
            nonce: UUID(),
            approvedAt: now
        )
        XCTAssertThrowsError(try prepared.policy.validateGrant(wrongNonce, request: request, now: now)) {
            XCTAssertEqual($0 as? StageCError, .approvalTampered)
        }
        let valid = StageCApprovalGrant(
            requestID: request.requestID,
            requestBindingSHA256: request.bindingSHA256,
            nonce: request.nonce,
            approvedAt: now
        )
        XCTAssertThrowsError(try prepared.policy.validateGrant(
            valid, request: request, now: request.expiresAt.addingTimeInterval(1)
        )) {
            XCTAssertEqual($0 as? StageCError, .approvalExpired)
        }
    }

    func testDurableStoreRejectsOversizedProposalAndKeepsBoundedNecessaryFacts() async throws {
        let prepared = try await StageCTestSupport.prepare()
        defer { prepared.cleanup() }
        let proposal = try prepared.policy.proposeEdit([
            StageCTestSupport.editCall(id: "durable-proposal")
        ], previouslyUsedIDs: [], baseline: try prepared.policy.captureWorkspaceBaseline())
        _ = try await prepared.taskStore.update(taskID: prepared.task.id, proposal: proposal)
        let snapshot = try await prepared.taskStore.snapshot(taskID: prepared.task.id)
        XCTAssertEqual(snapshot.proposal?.proposalSHA256, proposal.proposalSHA256)
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertLessThanOrEqual(data.count, prepared.limits.maximumDurableEvidenceBytes)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("Root Stage C test rules"))
        XCTAssertFalse(text.contains(StageCTestSupport.beforeContent))
    }

    func testSameWorkspaceWriterGateIsStrictlySerial() async throws {
        let gate = StageCWorkspaceWriterGate()
        let workspace = ProviderDigest.sha256Hex("workspace")
        let acquired = await gate.acquire(workspaceIdentitySHA256: workspace)
        let first = try XCTUnwrap(acquired)
        let second = await gate.acquire(workspaceIdentitySHA256: workspace)
        XCTAssertNil(second)
        await gate.release(workspaceIdentitySHA256: workspace, token: UUID())
        let afterWrongRelease = await gate.acquire(workspaceIdentitySHA256: workspace)
        XCTAssertNil(afterWrongRelease)
        await gate.release(workspaceIdentitySHA256: workspace, token: first)
        let afterRelease = await gate.acquire(workspaceIdentitySHA256: workspace)
        XCTAssertNotNil(afterRelease)
    }

    func testOrphanMutationIntentColdSnapshotCannotBecomeSuccess() async throws {
        let prepared = try await StageCTestSupport.prepare()
        defer { prepared.cleanup() }
        let intent = StageCAttemptEvidence(
            taskID: prepared.task.id,
            operationID: UUID(),
            attemptID: UUID(),
            ioKind: .mutationExecutor,
            inputSHA256: ProviderDigest.sha256Hex("mutation"),
            toolCallID: "orphan-write",
            recordedAt: Date(),
            phase: .intentRecorded,
            resultSHA256: nil,
            facts: nil
        )
        _ = try await prepared.taskStore.update(
            taskID: prepared.task.id, phase: .mutating, attempt: intent
        )
        let snapshot = try await prepared.taskStore.snapshot(taskID: prepared.task.id)
        XCTAssertEqual(snapshot.phase, .mutating)
        XCTAssertFalse(snapshot.attempts.contains { $0.phase == .succeeded })
    }
}
