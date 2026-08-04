import Foundation
import XCTest
@testable import Wuji

final class WujiStageDISHIntegrationTests: XCTestCase {
    func testRealARM64ISHStageDCommandMatrixInstallVersionsCloneWriteAndProcessTruth() async throws {
        let prepared = try await StageDTestSupport.prepare()
        defer { prepared.cleanup() }
        let cloneRootURL = await prepared.store.cloneRootURL
        let executor = try ISHStageDCommandExecutor.bundled(
            workspace: prepared.base.workspace,
            cloneRootURL: cloneRootURL
        )

        let installTask = try await makeTask(
            prepared,
            write: nil,
            expectation: .init(
                kind: .successfulCommand, relativePath: nil, expectedSHA256: nil,
                cloneTarget: nil, cloneRemote: nil, cloneHEAD: nil
            )
        )
        let installAgent = StageDCommandAgent(
            provider: nil, executor: executor,
            approvalAuthorizer: StageDValidationApprovalAuthorizer(
                enabledRisks: [.installation], now: Date.init
            ), store: prepared.store, task: installTask,
            policy: StageDCommandPolicy(
                workspaceIdentitySHA256: installTask.workspaceIdentitySHA256, write: nil
            ), requireProvider: false
        )
        guard case .completed = await installAgent.run(command: "apk add git python3 nodejs npm", cwd: ".") else {
            return XCTFail("fixed package installation did not complete")
        }
        let installSnapshot = try await prepared.store.snapshot(taskID: installTask.id)
        let installResult = try XCTUnwrap(installSnapshot.attempts.last?.result)
        XCTAssertEqual(Set(installResult.toolVersions.keys), Set(StageDEnvironmentLock.packages))
        XCTAssertTrue(installResult.facts.allSatisfy(\.verifiedSuccessBarrier))
        print("STAGE_D_ROOTFS_ARCHITECTURE=aarch64")
        print("STAGE_D_PACKAGE_REPOSITORIES=\(StageDEnvironmentLock.repositories.joined(separator: ","))")
        let versions = installResult.toolVersions.keys.sorted().map { key in
            "\(key)=\(installResult.toolVersions[key] ?? "")"
        }.joined(separator: ",")
        print("STAGE_D_PACKAGE_VERSIONS=\(versions)")

        for (executable, command) in [
            ("git", "git --version"),
            ("python3", "python3 --version"),
            ("node", "node --version"),
            ("npm", "npm --version"),
            ("python3-use", "python3 -c pass"),
            ("node-use", "node -e 0")
        ] {
            let task = try await makeTask(
                prepared,
                write: nil,
                expectation: .init(
                    kind: .successfulCommand, relativePath: nil, expectedSHA256: nil,
                    cloneTarget: nil, cloneRemote: nil, cloneHEAD: nil
                )
            )
            let agent = StageDCommandAgent(
                provider: nil, executor: executor,
                approvalAuthorizer: StageDValidationApprovalAuthorizer(
                    enabledRisks: [], now: Date.init
                ), store: prepared.store, task: task,
                policy: StageDCommandPolicy(
                    workspaceIdentitySHA256: task.workspaceIdentitySHA256, write: nil
                ), requireProvider: false
            )
            guard case .completed = await agent.run(command: command, cwd: ".") else {
                return XCTFail("tool check failed: \(executable)")
            }
            let snapshot = try await prepared.store.snapshot(taskID: task.id)
            let result = try XCTUnwrap(snapshot.attempts.last?.result)
            XCTAssertTrue(result.facts.allSatisfy(\.verifiedSuccessBarrier))
            if executable == "git" || executable == "python3" || executable == "node" || executable == "npm" {
                XCTAssertEqual(result.toolVersions.count, 1)
            }
        }

        let cloneTask = try await makeTask(
            prepared,
            write: nil,
            expectation: .init(
                kind: .exactClone, relativePath: nil, expectedSHA256: nil,
                cloneTarget: StageDEnvironmentLock.cloneTarget,
                cloneRemote: StageDEnvironmentLock.cloneURL,
                cloneHEAD: StageDEnvironmentLock.acceptedStageCCommit
            )
        )
        let cloneAgent = StageDCommandAgent(
            provider: nil, executor: executor,
            approvalAuthorizer: StageDValidationApprovalAuthorizer(
                enabledRisks: [.network], now: Date.init
            ), store: prepared.store, task: cloneTask,
            policy: StageDCommandPolicy(
                workspaceIdentitySHA256: cloneTask.workspaceIdentitySHA256, write: nil
            ), requireProvider: false
        )
        guard case .completed = await cloneAgent.run(
            command: "git clone --depth 8 --no-tags --single-branch https://github.com/Da-AiXZ/Wuji.git Wuji-StageC",
            cwd: "."
        ) else { return XCTFail("exact public clone did not complete") }
        let cloneSnapshot = try await prepared.store.snapshot(taskID: cloneTask.id)
        let cloneResult = try XCTUnwrap(cloneSnapshot.attempts.last?.result)
        XCTAssertEqual(cloneResult.cloneRemote, StageDEnvironmentLock.cloneURL)
        XCTAssertEqual(cloneResult.cloneHEAD, StageDEnvironmentLock.acceptedStageCCommit)
        XCTAssertLessThanOrEqual(cloneResult.cloneEntryCount ?? Int.max, StageDLimits.production.maximumCloneEntries)
        XCTAssertLessThanOrEqual(cloneResult.cloneByteCount ?? UInt64.max, StageDLimits.production.maximumCloneBytes)

        let writeTask = prepared.task
        let writeAgent = StageDCommandAgent(
            provider: nil, executor: executor,
            approvalAuthorizer: StageDValidationApprovalAuthorizer(
                enabledRisks: [.workspaceWrite], now: Date.init
            ), store: prepared.store, task: writeTask,
            policy: prepared.policy, requireProvider: false
        )
        guard case .completed = await writeAgent.run(command: prepared.writeCommand, cwd: ".") else {
            return XCTFail("approved bounded write did not complete")
        }
        XCTAssertEqual(
            ProviderDigest.sha256Hex(try Data(contentsOf: prepared.base.workspace.canonicalRootURL
                .appendingPathComponent(prepared.write.relativePath))),
            prepared.write.expectedAfterSHA256
        )
        let writeSnapshot = try await prepared.store.snapshot(taskID: writeTask.id)
        let writeFacts = try XCTUnwrap(writeSnapshot.attempts.last?.result?.facts.last)
        XCTAssertTrue(writeFacts.rootExitObserved)
        XCTAssertTrue(writeFacts.stdoutEOFObserved)
        XCTAssertTrue(writeFacts.stderrEOFObserved)
        XCTAssertFalse(writeFacts.truncated)
        XCTAssertEqual(writeFacts.processTreeState, .quiescent)
    }

    private func makeTask(
        _ prepared: StageDTestPrepared,
        write: StageDBoundedWrite?,
        expectation: StageDCompletionExpectation
    ) async throws -> StageDTaskRecord {
        try await prepared.store.create(
            session: prepared.base.session,
            workspace: prepared.base.workspace,
            ruleSet: prepared.base.ruleSet,
            write: write,
            expectation: expectation
        )
    }
}
