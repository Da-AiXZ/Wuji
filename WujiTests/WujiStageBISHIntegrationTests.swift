import Foundation
import XCTest
@testable import Wuji

final class WujiStageBISHIntegrationTests: XCTestCase {
    func testRealISHReadsActualStageAImportedProject() async throws {
        guard let fixtureURL = Bundle.main.url(
            forResource: "StageBRealImportedProject",
            withExtension: nil
        ) else { return XCTFail("Stage B fixture missing") }
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("WujiStageBISH-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let policy = StageAImportPolicy(
            maximumEntryCount: 64,
            maximumFileBytes: 32 * 1_024,
            maximumTotalBytes: 256 * 1_024,
            maximumCompressionRatio: 20,
            maximumPathBytes: 1_024,
            maximumDirectoryDepth: 16,
            minimumRemainingCapacityBytes: 0,
            maximumDiagnosticBytes: 8 * 1_024
        )
        let store = StageAWorkspaceStore(
            rootURL: container.appendingPathComponent("StageA"),
            policy: policy
        )
        let importer = StageAWorkspaceImporter(
            store: store,
            policy: policy,
            coordinator: StageBISHPassThroughCoordinator()
        )
        let imported = await importer.importItem(at: fixtureURL, expectedKind: .folder)
        XCTAssertEqual(imported.phase, .ready)
        let workspace = try StageBWorkspaceResolver(store: store).openReadyWorkspace(
            importID: imported.id
        )
        let rules = try StageBRuleDiscovery().discover(in: workspace)
        let readPolicy = StageBReadOnlyPolicy(workspace: workspace, ruleSet: rules)
        let executor = try ISHStageBReadOnlyExecutor.bundled(workspace: workspace)

        let authorized = try readPolicy.authorizeBatch([
            call(id: "real-b-list", name: "list", arguments: ["path": ""]),
            call(id: "real-b-search", name: "search", arguments: [
                "path": "Sources", "query": StageBProbeContract.query
            ]),
            call(id: "real-b-read", name: "read", arguments: [
                "path": StageBProbeContract.expectedPath
            ])
        ])
        var observations: [StageBToolObservation] = []
        for call in authorized {
            guard case let .observation(observation) = await executor.execute(call.tool) else {
                return XCTFail("real Stage B iSH call failed: \(call.tool.name)")
            }
            observations.append(observation)
            XCTAssertTrue(observation.facts.completionBarrierSatisfied)
            XCTAssertTrue(observation.facts.exitedSuccessfully)
            XCTAssertFalse(observation.facts.truncated)
        }
        guard case let .list(entries) = observations[0].payload else {
            return XCTFail("list payload missing")
        }
        XCTAssertFalse(entries.contains(StageAWorkspaceMarker.fileName))
        guard case let .search(matches) = observations[1].payload else {
            return XCTFail("search payload missing")
        }
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].path, StageBProbeContract.expectedPath)
        guard case let .read(path, content) = observations[2].payload else {
            return XCTFail("read payload missing")
        }
        XCTAssertEqual(path, StageBProbeContract.expectedPath)
        XCTAssertTrue(content.contains(StageBProbeContract.query))
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
}

private struct StageBISHPassThroughCoordinator: StageAExternalFileCoordinating, @unchecked Sendable {
    func coordinateRead<T>(at url: URL, _ body: (URL) throws -> T) throws -> T {
        try body(url)
    }
}
