import XCTest
@testable import Wuji

final class WujiS4ExecutorContractTests: XCTestCase {
    func testEditRequiresExitZeroBothEOFNoTruncationAndExactObservation() {
        let edit = authorizedEdit()
        guard case let .observation(observation) = S4ExecutorClassifier.edit(
            facts: facts(),
            stdout: "WUJI_S4_EDIT_OK\n",
            stderr: "",
            edit: edit
        ) else {
            return XCTFail("valid edit facts were not accepted")
        }
        XCTAssertTrue(observation.facts.completionBarrierSatisfied)
        XCTAssertEqual(observation.beforeSHA256, S4TaskContract.beforeHash)
        XCTAssertEqual(observation.afterSHA256, S4TaskContract.afterHash)
    }

    func testEditClassifiesPreconditionTempReplacementHashAndNonzeroSeparately() {
        let edit = authorizedEdit()
        let cases: [(Int32, S4ExecutorFailure)] = [
            (42, .preconditionMismatch),
            (43, .temporaryFilePresent),
            (44, .replacementCount),
            (45, .hashMismatch),
            (46, .hashMismatch),
            (7, .nonzeroExit)
        ]
        for (exit, expected) in cases {
            XCTAssertEqual(S4ExecutorClassifier.edit(
                facts: facts(finalState: .exited(exit)),
                stdout: "",
                stderr: "",
                edit: edit
            ), .failure(expected))
        }
    }

    func testEditTruncationAndMalformedOutputAreFailures() {
        let edit = authorizedEdit()
        XCTAssertEqual(S4ExecutorClassifier.edit(
            facts: facts(truncated: true),
            stdout: "WUJI_S4_EDIT_OK\n",
            stderr: "",
            edit: edit
        ), .failure(.observationLimit))
        XCTAssertEqual(S4ExecutorClassifier.edit(
            facts: facts(),
            stdout: "unexpected\n",
            stderr: "",
            edit: edit
        ), .failure(.malformedObservation))
        XCTAssertEqual(S4ExecutorClassifier.edit(
            facts: facts(),
            stdout: "WUJI_S4_EDIT_OK\n",
            stderr: "error",
            edit: edit
        ), .failure(.malformedObservation))
    }

    func testEditUnknownWhenRootExitOrEitherEOFIsMissingOrSignalObserved() {
        let edit = authorizedEdit()
        let incomplete = [
            facts(rootExit: false),
            facts(stdoutEOF: false),
            facts(stderrEOF: false),
            facts(finalState: .signaled(9))
        ]
        for value in incomplete {
            XCTAssertEqual(S4ExecutorClassifier.edit(
                facts: value,
                stdout: "WUJI_S4_EDIT_OK\n",
                stderr: "",
                edit: edit
            ), .unknown)
        }
    }

    func testInterruptedEditRemainsUnknownAndCannotBeCompleted() {
        let outcome = S4ExecutorClassifier.edit(
            facts: facts(
                rootExit: false,
                stdoutEOF: false,
                stderrEOF: false,
                finalState: .unknown("interrupted")
            ),
            stdout: "",
            stderr: "",
            edit: authorizedEdit()
        )
        XCTAssertEqual(outcome, .unknown)
    }

    func testVerifyExitZeroAloneCannotPassWithoutBothEOFAndExactObservation() {
        for value in [facts(rootExit: false), facts(stdoutEOF: false), facts(stderrEOF: false)] {
            XCTAssertEqual(S4ExecutorClassifier.verify(
                facts: value,
                stdout: "WUJI_S4_VERIFY_OK\n",
                stderr: "",
                profile: .s4StatusVerified
            ), .unknown)
        }
        XCTAssertEqual(S4ExecutorClassifier.verify(
            facts: facts(),
            stdout: "wrong\n",
            stderr: "",
            profile: .s4StatusVerified
        ), .failure(.malformedObservation))
    }

    func testVerifySuccessCarriesFixedProfileAndSeparateExecutionFacts() {
        guard case let .observation(observation) = S4ExecutorClassifier.verify(
            facts: facts(),
            stdout: "WUJI_S4_VERIFY_OK\n",
            stderr: "",
            profile: .s4StatusVerified
        ) else {
            return XCTFail("valid verification facts were not accepted")
        }
        XCTAssertEqual(observation.profile, .s4StatusVerified)
        XCTAssertTrue(observation.facts.rootExitObserved)
        XCTAssertTrue(observation.facts.stdoutEOFObserved)
        XCTAssertTrue(observation.facts.stderrEOFObserved)
        XCTAssertFalse(observation.facts.truncated)
    }

    private func authorizedEdit() -> S4AuthorizedEdit {
        S4AuthorizedEdit(
            relativePath: S4TaskContract.authorizedPath,
            beforeHash: S4TaskContract.beforeHash,
            afterHash: S4TaskContract.afterHash
        )
    }

    private func facts(
        rootExit: Bool = true,
        stdoutEOF: Bool = true,
        stderrEOF: Bool = true,
        finalState: ExecutorFinalState = .exited(0),
        truncated: Bool = false
    ) -> S3ExecutorFacts {
        S3ExecutorFacts(
            rootExitObserved: rootExit,
            stdoutEOFObserved: stdoutEOF,
            stderrEOFObserved: stderrEOF,
            finalState: finalState,
            stdoutByteCount: 16,
            stderrByteCount: 0,
            stdoutSHA256: String(repeating: "a", count: 64),
            stderrSHA256: String(repeating: "b", count: 64),
            truncated: truncated
        )
    }
}
