import XCTest
@testable import Wuji

final class WujiISHGuestIntegrationTests: XCTestCase {
    private let executor = ISHExecutor.shared

    func testRealGuestSuccessSeparatesOutputAndExit() async {
        let result = await executor.execute(.success, outputLimit: 4_096)
        XCTAssertEqual(result.stdout, "WUJI_STDOUT_OK")
        XCTAssertEqual(result.stderr, "WUJI_STDERR_OK")
        XCTAssertEqual(result.finalState, .exited(0))
        XCTAssertTrue(result.completionBarrierSatisfied)
    }

    func testRealGuestPreservesNonzeroExit() async {
        let result = await executor.execute(.nonzero, outputLimit: 4_096)
        XCTAssertEqual(result.stdout, "WUJI_NONZERO_STDOUT")
        XCTAssertEqual(result.stderr, "WUJI_NONZERO_STDERR")
        XCTAssertEqual(result.finalState, .exited(7))
        XCTAssertTrue(result.completionBarrierSatisfied)
    }

    func testRealGuestBoundsOutputAndStillDrains() async {
        let result = await executor.execute(.truncation, outputLimit: 1_024)
        XCTAssertEqual(result.stdout.utf8.count, 1_024)
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.finalState, .exited(0))
        XCTAssertTrue(result.completionBarrierSatisfied)
    }

    func testRealGuestCancellationRecordsSignalAndFinalObservation() async throws {
        let warmup = await executor.execute(.success, outputLimit: 4_096)
        XCTAssertTrue(warmup.completionBarrierSatisfied)

        let execution = Task { await executor.execute(.cancellation, outputLimit: 4_096) }
        try await Task.sleep(nanoseconds: 50_000_000)
        let receipt = executor.requestCancellation()
        let result = await execution.value

        XCTAssertTrue(receipt.requested)
        XCTAssertEqual(receipt.delivery, .signalSent)
        XCTAssertTrue(result.cancellationRequested)
        XCTAssertEqual(result.cancellationDelivery, .signalSent)
        XCTAssertTrue(result.rootExitObserved)
        XCTAssertTrue(result.stdoutEOFObserved)
        XCTAssertTrue(result.stderrEOFObserved)
        if case .unknown(let reason) = result.finalState {
            XCTFail("Cancellation outcome remained unknown: \(reason)")
        }
    }
}
