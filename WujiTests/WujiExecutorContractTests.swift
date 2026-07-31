import XCTest
@testable import Wuji

final class WujiExecutorContractTests: XCTestCase {
    func testCompletionRequiresRootExitAndBothEOFs() {
        let incomplete = observation(root: true, stdoutEOF: true, stderrEOF: false)
        XCTAssertFalse(incomplete.completionBarrierSatisfied)

        let complete = observation(root: true, stdoutEOF: true, stderrEOF: true)
        XCTAssertTrue(complete.completionBarrierSatisfied)
    }

    func testNonzeroExitIsNotRelabeledAsTaskCompletion() {
        let result = observation(
            root: true,
            stdoutEOF: true,
            stderrEOF: true,
            finalState: .exited(7)
        )
        XCTAssertEqual(result.finalState, .exited(7))
        XCTAssertTrue(result.completionBarrierSatisfied)
    }

    func testTruncationRemainsExplicit() {
        var result = observation(root: true, stdoutEOF: true, stderrEOF: true)
        result = ExecutorObservation(
            stdout: result.stdout,
            stderr: result.stderr,
            rootExitObserved: result.rootExitObserved,
            stdoutEOFObserved: result.stdoutEOFObserved,
            stderrEOFObserved: result.stderrEOFObserved,
            truncated: true,
            cancellationRequested: false,
            cancellationDelivery: nil,
            finalState: result.finalState
        )
        XCTAssertTrue(result.truncated)
    }

    func testCancellationHasTypedUnknownBoundary() {
        let result = observation(
            root: false,
            stdoutEOF: false,
            stderrEOF: false,
            finalState: .unknown("guest outcome unavailable")
        )
        XCTAssertEqual(result.finalState, .unknown("guest outcome unavailable"))
        XCTAssertFalse(result.completionBarrierSatisfied)
    }

    private func observation(
        root: Bool,
        stdoutEOF: Bool,
        stderrEOF: Bool,
        finalState: ExecutorFinalState = .exited(0)
    ) -> ExecutorObservation {
        ExecutorObservation(
            stdout: "",
            stderr: "",
            rootExitObserved: root,
            stdoutEOFObserved: stdoutEOF,
            stderrEOFObserved: stderrEOF,
            truncated: false,
            cancellationRequested: false,
            cancellationDelivery: nil,
            finalState: finalState
        )
    }
}
