import XCTest
@testable import Wuji

final class WujiS4ISHIntegrationTests: XCTestCase {
    func testRealISHExecutesTypedReadEditAndFixedVerify() async throws {
        guard let rootFSURL = Bundle(for: Self.self).url(forResource: "rootfs", withExtension: "tar.gz") else {
            throw XCTSkip("rootfs is supplied by the S4 workflow")
        }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let records = temp.appendingPathComponent("records", isDirectory: true)
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        try Data(S4TaskContract.expectedBeforeContent.utf8).write(
            to: temp.appendingPathComponent(S4TaskContract.authorizedPath)
        )
        try Data(S4TaskContract.expectedContextContent.utf8).write(
            to: temp.appendingPathComponent(S4TaskContract.contextPath)
        )
        defer { try? FileManager.default.removeItem(at: temp) }

        let workspace = try S4ApprovedWorkspace(
            taskID: UUID(),
            rootURL: temp,
            requireInitialSeed: true
        )
        let executor = ISHS4Executor(rootFSURL: rootFSURL, workspace: workspace)
        let policy = try S4ToolPolicy(workspace: workspace)

        let readCalls = [
            ProviderTurnToolCall(id: "list", name: "list", arguments: #"{"path":""}"#),
            ProviderTurnToolCall(id: "search", name: "search", arguments: #"{"path":"","query":"STATUS=pending"}"#),
            ProviderTurnToolCall(id: "read", name: "read", arguments: #"{"path":"records/draft.txt"}"#)
        ]
        let reads = try policy.authorizeBatch(readCalls, phase: .inspecting)
        for call in reads {
            guard case let .readOnly(tool) = call.tool,
                  case let .observation(observation) = await executor.execute(tool) else {
                return XCTFail("real iSH read operation failed")
            }
            XCTAssertTrue(observation.facts.completionBarrierSatisfied)
            XCTAssertFalse(observation.facts.truncated)
        }

        let editCall = ProviderTurnToolCall(
            id: "edit",
            name: "edit",
            arguments: #"{"path":"records/draft.txt","expected_old":"STATUS=pending","replacement":"STATUS=verified"}"#
        )
        let admittedEdit = try policy.authorizeBatch([editCall], phase: .inspected)
        guard case let .edit(edit) = admittedEdit[0].tool,
              case let .observation(editObservation) = await executor.edit(edit) else {
            return XCTFail("real iSH edit failed")
        }
        XCTAssertTrue(editObservation.facts.completionBarrierSatisfied)
        XCTAssertFalse(editObservation.facts.truncated)

        let verifyCall = ProviderTurnToolCall(
            id: "verify",
            name: "verify",
            arguments: #"{"profile":"s4_status_verified"}"#
        )
        let admittedVerify = try policy.authorizeBatch([verifyCall], phase: .edited)
        guard case let .verify(profile) = admittedVerify[0].tool,
              case let .observation(verifyObservation) = await executor.verify(profile) else {
            return XCTFail("real iSH fixed verification failed")
        }
        XCTAssertTrue(verifyObservation.facts.completionBarrierSatisfied)
        XCTAssertFalse(verifyObservation.facts.truncated)

        let inspection = try workspace.inspect()
        XCTAssertEqual(inspection.contentState, .after)
        XCTAssertTrue(inspection.exactFileSet)
        XCTAssertTrue(inspection.contextUnchanged)
        XCTAssertFalse(inspection.temporaryFilePresent)
    }
}
