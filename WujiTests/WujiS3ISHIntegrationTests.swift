import Foundation
import XCTest
@testable import Wuji

final class WujiS3ISHIntegrationTests: XCTestCase {
    func testRealISHExecutesBoundedListSearchAndRead() async throws {
        let workspace = try S3ApprovedWorkspace.bundled()
        let policy = S3ToolPolicy(workspace: workspace)
        let executor = try ISHReadOnlyExecutor.bundled()

        let list = await executor.execute(try policy.authorize(call(
            id: "real-list",
            name: "list",
            arguments: ["path": ""]
        )))
        guard case let .observation(listObservation) = list,
              case let .list(entries) = listObservation.payload else {
            return XCTFail("real iSH list failed: \(list)")
        }
        XCTAssertTrue(entries.contains("records"))
        assertSuccessfulFacts(listObservation.facts)

        let search = await executor.execute(try policy.authorize(call(
            id: "real-search",
            name: "search",
            arguments: ["path": "", "query": S3TaskContract.marker]
        )))
        guard case let .observation(searchObservation) = search,
              case let .search(matches) = searchObservation.payload else {
            return XCTFail("real iSH search failed: \(search)")
        }
        XCTAssertEqual(matches, [S3SearchMatch(
            path: "records/target.txt",
            line: 2,
            text: S3TaskContract.marker
        )])
        assertSuccessfulFacts(searchObservation.facts)

        let read = await executor.execute(try policy.authorize(call(
            id: "real-read",
            name: "read",
            arguments: ["path": "records/target.txt"]
        )))
        guard case let .observation(readObservation) = read,
              case let .read(path, content) = readObservation.payload else {
            return XCTFail("real iSH read failed: \(read)")
        }
        XCTAssertEqual(path, "records/target.txt")
        XCTAssertEqual(
            content.split(separator: "\n").filter { String($0) == S3TaskContract.marker }.count,
            1
        )
        assertSuccessfulFacts(readObservation.facts)
    }

    private func assertSuccessfulFacts(
        _ facts: S3ExecutorFacts,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(facts.rootExitObserved, file: file, line: line)
        XCTAssertTrue(facts.stdoutEOFObserved, file: file, line: line)
        XCTAssertTrue(facts.stderrEOFObserved, file: file, line: line)
        XCTAssertTrue(facts.completionBarrierSatisfied, file: file, line: line)
        XCTAssertEqual(facts.finalState, .exited(0), file: file, line: line)
        XCTAssertEqual(facts.stderrByteCount, 0, file: file, line: line)
        XCTAssertFalse(facts.truncated, file: file, line: line)
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
