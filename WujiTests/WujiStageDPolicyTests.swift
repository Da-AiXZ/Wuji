import Foundation
import XCTest
@testable import Wuji

final class WujiStageDPolicyTests: XCTestCase {
    func testParserClassifiesStrictSingleCommandGrammar() throws {
        let parsed = try StageDCommandParser.parse(command: "git --version", cwd: ".")
        XCTAssertEqual(parsed.executable, "git")
        XCTAssertEqual(parsed.arguments, ["--version"])
        XCTAssertEqual(parsed.cwd, "")
        for command in [
            "pwd | cat", "pwd;cat", "echo $(pwd)", "pwd &", "pwd > out",
            "git 'status'", "git \"status\"", "pwd  pwd", "pwd\tpwd", "pwd\npwd"
        ] {
            XCTAssertThrowsError(try StageDCommandParser.parse(command: command, cwd: "."))
        }
    }

    func testClassifierAllowsOnlyNamedSafeReadCommandsWithoutApproval() {
        let policy = makePolicy()
        for command in [
            "pwd", "ls -1A", "cat -- README.md", "git --version",
            "python3 --version", "python3 -c pass", "node --version", "node -e 0", "npm --version"
        ] {
            guard case let .authorized(value) = policy.decide(command: command, cwd: ".") else {
                return XCTFail("safe command rejected: \(command)")
            }
            XCTAssertEqual(value.risk, .safeReadOnly)
            XCTAssertFalse(value.risk.requiresApproval)
        }
    }

    func testWriteNetworkAndInstallationRequireExactBoundApprovalClass() {
        let policy = makePolicy()
        let write = "sed -i s/channel=preview/channel=stable/ Sources/Environment.txt"
        let clone = "git clone --depth 8 --no-tags --single-branch https://github.com/Da-AiXZ/Wuji.git Wuji-StageC"
        let install = "apk add git python3 nodejs npm"
        let cases: [(String, StageDCommandRisk)] = [
            (write, .workspaceWrite), (clone, .network), (install, .installation)
        ]
        for (command, risk) in cases {
            guard case let .authorized(value) = policy.decide(command: command, cwd: ".") else {
                return XCTFail("approved class rejected: \(command)")
            }
            XCTAssertEqual(value.risk, risk)
            XCTAssertTrue(value.risk.requiresApproval)
        }
    }

    func testDeleteOverwriteBoundaryAndUnknownFailClosedBeforeExecutorIO() {
        let policy = makePolicy()
        for (command, expectedRisk) in [
            ("rm README.md", StageDCommandRisk.delete),
            ("cp README.md README.copy", .overwrite),
            ("cat -- /etc/passwd", .boundaryCrossing),
            ("curl https://example.com", .unsupported)
        ] {
            guard case let .rejected(risk, _) = policy.decide(command: command, cwd: ".") else {
                return XCTFail("denied command admitted: \(command)")
            }
            XCTAssertEqual(risk, expectedRisk)
        }
        guard case let .rejected(risk, _) = policy.decide(command: "pwd", cwd: "../outside") else {
            return XCTFail("boundary cwd admitted")
        }
        XCTAssertEqual(risk, .boundaryCrossing)
    }

    func testCloneRequiresExactCredentialFreeURLFlagsTargetAndCWD() {
        let policy = makePolicy()
        let exact = "git clone --depth 8 --no-tags --single-branch https://github.com/Da-AiXZ/Wuji.git Wuji-StageC"
        guard case let .authorized(value) = policy.decide(command: exact, cwd: ".") else {
            return XCTFail("exact clone rejected")
        }
        XCTAssertEqual(value.executionRoot, .cloneRoot)
        XCTAssertEqual(value.cloneTarget, StageDEnvironmentLock.cloneTarget)
        for command in [
            "git clone https://github.com/Da-AiXZ/Wuji.git Wuji-StageC",
            "git clone --depth 8 --no-tags --single-branch https://example.com/Wuji.git Wuji-StageC",
            "git clone --depth 8 --no-tags --single-branch https://github.com/Da-AiXZ/Wuji.git existing"
        ] {
            guard case .rejected = policy.decide(command: command, cwd: ".") else {
                return XCTFail("non-exact clone admitted")
            }
        }
        XCTAssertThrowsError(try StageDCommandParser.parse(
            command: "git clone --depth 8 --no-tags --single-branch https://token@github.com/Da-AiXZ/Wuji.git Wuji-StageC",
            cwd: "."
        ))
    }

    func testInstallationAcceptsOnlyFixedPackageSetAndExistingRepositoryPolicy() {
        let policy = makePolicy()
        guard case let .authorized(install) = policy.decide(
            command: "apk add git python3 nodejs npm", cwd: "."
        ) else { return XCTFail("fixed install rejected") }
        XCTAssertEqual(install.executionRoot, .rootfs)
        guard case let .authorized(inspect) = policy.decide(
            command: "apk policy git python3 nodejs npm", cwd: "."
        ) else { return XCTFail("policy inspection rejected") }
        XCTAssertEqual(inspect.risk, .safeReadOnly)
        for command in ["apk add git", "apk add git python3 nodejs npm ruby", "apk update"] {
            guard case .rejected = policy.decide(command: command, cwd: ".") else {
                return XCTFail("non-fixed install admitted")
            }
        }
        XCTAssertEqual(StageDEnvironmentLock.repositories.count, 2)
    }

    func testUnsupportedLanguagesReportUnavailableWithoutSilentInstall() {
        let policy = makePolicy()
        for executable in ["swift", "go", "rustc", "ruby", "pip", "cargo"] {
            guard case let .unavailable(name) = policy.decide(command: "\(executable) --version", cwd: ".") else {
                return XCTFail("unsupported language did not report unavailable")
            }
            XCTAssertEqual(name, executable)
        }
    }

    func testSecretEnvironmentAndCredentialSyntaxCannotBecomeCommandOrCloneEvidence() {
        let secret = "stage-d-secret-sentinel"
        let policy = makePolicy()
        guard case .rejected = policy.decide(command: "DEEPSEEK_API_KEY=\(secret) git --version", cwd: ".") else {
            return XCTFail("environment assignment admitted")
        }
        XCTAssertThrowsError(try StageDCommandParser.parse(
            command: "git clone --depth 8 --no-tags --single-branch https://\(secret)@github.com/Da-AiXZ/Wuji.git Wuji-StageC",
            cwd: "."
        ))
    }

    func testProcessDrainTruncationAndProcessTreeRemainSeparateCompletionFacts() {
        let base = facts()
        XCTAssertTrue(base.verifiedSuccessBarrier)
        XCTAssertFalse(facts(stdoutEOF: false).verifiedSuccessBarrier)
        XCTAssertFalse(facts(stderrEOF: false).verifiedSuccessBarrier)
        XCTAssertFalse(facts(truncated: true).verifiedSuccessBarrier)
        XCTAssertFalse(facts(tree: .descendantsRemain, descendants: 1).verifiedSuccessBarrier)
        XCTAssertFalse(facts(cancelled: true).verifiedSuccessBarrier)
    }

    func testUIProjectionCannotAuthorApprovalExecutionOrCompletionTruth() {
        let record = makeRecord()
        let fakeRequest = StageDApprovalRequest(
            requestID: UUID(), taskID: record.id, operationID: UUID(), attemptID: UUID(),
            workspaceIdentitySHA256: record.workspaceIdentitySHA256,
            commandBindingSHA256: String(repeating: "b", count: 64),
            command: "apk add git python3 nodejs npm",
            argumentsSHA256: String(repeating: "c", count: 64), cwd: "",
            risk: .installation, executionRoot: .rootfs,
            nonce: UUID(), createdAt: Date(), expiresAt: Date().addingTimeInterval(60)
        )
        let projection = StageDCommandProjection.make(
            record: record,
            approval: .init(state: .approved, request: fakeRequest)
        )
        XCTAssertEqual(projection.phase, StageDTaskPhase.ready.rawValue)
        XCTAssertFalse(projection.completed)
        XCTAssertNil(projection.command)
        XCTAssertNil(record.completion)
        XCTAssertTrue(record.attempts.isEmpty)
    }

    func testProductionResourceDefaultsAreExactAndInjectable() {
        let limits = StageDLimits.production
        XCTAssertEqual(limits.maximumCommandBytes, 2 * 1_024)
        XCTAssertEqual(limits.maximumArgumentCount, 16)
        XCTAssertEqual(limits.maximumStdoutBytes, 64 * 1_024)
        XCTAssertEqual(limits.maximumStderrBytes, 64 * 1_024)
        XCTAssertEqual(limits.commandTimeoutSeconds, 120)
        XCTAssertEqual(limits.maximumCloneSeconds, 300)
        XCTAssertEqual(limits.maximumCloneEntries, 20_000)
        XCTAssertEqual(limits.maximumCloneBytes, 512 * 1_024 * 1_024)
        XCTAssertEqual(limits.maximumWorkspaceBytes, 2 * 1_024 * 1_024 * 1_024)
    }

    private func makePolicy() -> StageDCommandPolicy {
        let before = Data("channel=preview\ntoolset=base\n".utf8)
        let after = Data("channel=stable\ntoolset=base\n".utf8)
        return .init(
            workspaceIdentitySHA256: String(repeating: "a", count: 64),
            write: .init(
                relativePath: "Sources/Environment.txt",
                expectedBeforeLine: "channel=preview",
                replacementLine: "channel=stable",
                expectedBeforeSHA256: ProviderDigest.sha256Hex(before),
                expectedAfterSHA256: ProviderDigest.sha256Hex(after)
            )
        )
    }

    private func facts(
        stdoutEOF: Bool = true,
        stderrEOF: Bool = true,
        truncated: Bool = false,
        tree: StageDProcessTreeState = .quiescent,
        descendants: Int = 0,
        cancelled: Bool = false
    ) -> StageDProcessFacts {
        .init(
            rootExitObserved: true, finalStateKind: "exited", finalStateValue: 0,
            stdoutEOFObserved: stdoutEOF, stderrEOFObserved: stderrEOF,
            stdoutByteCount: 0, stderrByteCount: 0,
            stdoutSHA256: ProviderDigest.sha256Hex(Data()),
            stderrSHA256: ProviderDigest.sha256Hex(Data()),
            truncated: truncated, cancellationRequested: cancelled,
            processTreeState: tree, activeDescendantCount: descendants
        )
    }

    private func makeRecord() -> StageDTaskRecord {
        .init(
            id: UUID(), sessionID: UUID(), importID: UUID(), workspaceID: UUID(),
            workspaceIdentitySHA256: String(repeating: "a", count: 64),
            workspaceRootSHA256: String(repeating: "b", count: 64),
            goalBindingSHA256: String(repeating: "c", count: 64),
            ruleSetBindingSHA256: String(repeating: "d", count: 64),
            cloneRootSHA256: String(repeating: "e", count: 64),
            write: nil,
            expectation: .init(
                kind: .successfulCommand, relativePath: nil, expectedSHA256: nil,
                cloneTarget: nil, cloneRemote: nil, cloneHEAD: nil
            ),
            createdAt: Date(), updatedAt: Date(), phase: .ready,
            approvals: [], attempts: [], completion: nil
        )
    }
}
