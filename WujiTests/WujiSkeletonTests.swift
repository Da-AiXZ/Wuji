import XCTest
@testable import Wuji

@MainActor
final class WujiSkeletonTests: XCTestCase {
    func testEmptyTaskStateHasApprovedStatus() {
        XCTAssertEqual(WujiTaskState.empty.statusText, "尚未开始任务")
    }

    func testRootViewCanBeConstructed() {
        _ = ContentView()
    }
}
