import XCTest
@testable import Wuji

final class WujiStageCISHIntegrationTests: XCTestCase {
    func testRealISHExecutesTypedBoundedEditOnStageAImportedWorkspace() async throws {
        let prepared = try await StageCTestSupport.prepare()
        defer { prepared.cleanup() }
        let proposal = try prepared.policy.proposeEdit([
            StageCTestSupport.editCall(id: "real-ish-edit")
        ], previouslyUsedIDs: [], baseline: try prepared.policy.captureWorkspaceBaseline())
        let executor = try ISHStageCEditExecutor.bundled(
            workspace: prepared.workspace,
            limits: prepared.limits
        )
        guard case let .applied(facts) = await executor.execute(proposal) else {
            return XCTFail("real iSH Stage C edit failed")
        }
        XCTAssertTrue(facts.terminalBarrierSatisfied)
        XCTAssertFalse(facts.truncated)
        XCTAssertEqual(facts.finalStateKind, "exited")
        XCTAssertEqual(facts.finalStateValue, 0)
        XCTAssertNoThrow(try prepared.policy.verifyApplied(proposal))
        let content = try String(contentsOf: prepared.targetURL, encoding: .utf8)
        XCTAssertTrue(content.contains(StageCTestSupport.newLine))
        XCTAssertFalse(content.contains(StageCTestSupport.oldLine))
    }
}
