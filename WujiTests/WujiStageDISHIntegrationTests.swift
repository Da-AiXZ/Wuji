import Foundation
import XCTest
@testable import Wuji

final class WujiStageDISHIntegrationTests: XCTestCase {
    func testRealARM64ISHStageDSystemResolverCommandMatrixInstallVersionsCloneWriteAndProcessTruth() async throws {
        let prepared = try await StageDTestSupport.prepare()
        defer { prepared.cleanup() }
        let cloneRootURL = await prepared.store.cloneRootURL
        let failedResolverExecutor = try ISHStageDCommandExecutor.bundled(
            workspace: prepared.base.workspace,
            cloneRootURL: cloneRootURL,
            resolverConfigurator: { nil }
        )
        let readPolicy = StageDCommandPolicy(
            workspaceIdentitySHA256: prepared.task.workspaceIdentitySHA256,
            write: nil
        )
        guard case let .authorized(pwd) = readPolicy.decide(command: "pwd", cwd: ".") else {
            return XCTFail("pwd policy setup failed")
        }
        let attemptsBeforeResolverFailure = wuji_ish_stage_d_command_attempt_count()
        guard case .failed = await failedResolverExecutor.execute(pwd, policy: readPolicy) else {
            return XCTFail("resolver failure did not fail closed")
        }
        XCTAssertEqual(wuji_ish_stage_d_command_attempt_count(), attemptsBeforeResolverFailure)

        let executor = try ISHStageDCommandExecutor.bundled(
            workspace: prepared.base.workspace,
            cloneRootURL: cloneRootURL
        )

        let transientTree = try processTreeEvidence(
            WUJI_ISH_CASE_PROCESS_TREE_TRANSIENT_NONZERO
        )
        XCTAssertTrue(transientTree.rootExitObserved)
        XCTAssertTrue(transientTree.stdoutEOFObserved)
        XCTAssertTrue(transientTree.stderrEOFObserved)
        XCTAssertEqual(transientTree.finalValue, 128)
        XCTAssertGreaterThan(transientTree.initialActiveDescendantCount, 0)
        XCTAssertEqual(transientTree.finalActiveDescendantCount, 0)
        XCTAssertGreaterThanOrEqual(transientTree.observationCount, 2)
        XCTAssertLessThanOrEqual(transientTree.observationCount, 11)
        XCTAssertEqual(transientTree.processTreeState, WUJI_ISH_PROCESS_TREE_QUIESCENT)

        let persistentTree = try processTreeEvidence(
            WUJI_ISH_CASE_PROCESS_TREE_PERSISTENT_NONZERO
        )
        XCTAssertEqual(persistentTree.finalValue, 128)
        XCTAssertEqual(persistentTree.stderrSHA256, transientTree.stderrSHA256)
        XCTAssertGreaterThan(persistentTree.initialActiveDescendantCount, 0)
        XCTAssertGreaterThan(persistentTree.finalActiveDescendantCount, 0)
        XCTAssertEqual(persistentTree.observationCount, 11)
        XCTAssertEqual(persistentTree.processTreeState, WUJI_ISH_PROCESS_TREE_DESCENDANTS_REMAIN)

        let cleanContext = try processTreeEvidence(WUJI_ISH_CASE_PROCESS_TREE_CONTEXT_CLEAN)
        XCTAssertEqual(cleanContext.initialActiveDescendantCount, 0)
        XCTAssertEqual(cleanContext.finalActiveDescendantCount, 0)
        XCTAssertEqual(cleanContext.observationCount, 1)
        XCTAssertEqual(cleanContext.processTreeState, WUJI_ISH_PROCESS_TREE_QUIESCENT)
        print(
            "STAGE_D_PROCESS_TREE_QUIESCENCE=initial=\(transientTree.initialActiveDescendantCount)," +
            "final=\(transientTree.finalActiveDescendantCount)," +
            "observations=\(transientTree.observationCount),bounded=1"
        )
        let forged = StageDAuthorizedCommand(
            parsed: pwd.parsed,
            risk: .installation,
            executionRoot: .rootfs,
            workspaceIdentitySHA256: pwd.workspaceIdentitySHA256,
            write: nil,
            cloneTarget: nil
        )
        let attemptsBeforeForgedCommand = wuji_ish_stage_d_command_attempt_count()
        guard case let .failed(forgedResult) = await executor.execute(forged, policy: readPolicy) else {
            return XCTFail("forged authorized command was not rejected")
        }
        XCTAssertEqual(forgedResult?.failureCategory, .authorizationRejected)
        XCTAssertEqual(wuji_ish_stage_d_command_attempt_count(), attemptsBeforeForgedCommand)

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
        let resolver = try XCTUnwrap(executor.systemResolverEvidence())
        XCTAssertGreaterThan(resolver.nameserverCount, 0)
        XCTAssertLessThanOrEqual(resolver.nameserverCount, 32)
        XCTAssertLessThanOrEqual(resolver.searchDomainCount, 7)
        XCTAssertGreaterThan(resolver.configurationBytes, 0)
        XCTAssertLessThan(resolver.configurationBytes, 4_096)
        XCTAssertGreaterThan(resolver.configurationCount, 0)

        var repeatedNameservers: UInt32 = 0
        var repeatedSearchDomains: UInt32 = 0
        var repeatedBytes = 0
        var repeatedCount: UInt32 = 0
        var resolverError = [CChar](repeating: 0, count: 256)
        XCTAssertEqual(
            wuji_ish_configure_stage_d_system_resolver(
                &repeatedNameservers,
                &repeatedSearchDomains,
                &repeatedBytes,
                &repeatedCount,
                &resolverError,
                resolverError.count
            ),
            0
        )
        XCTAssertEqual(repeatedNameservers, resolver.nameserverCount)
        XCTAssertEqual(repeatedSearchDomains, resolver.searchDomainCount)
        XCTAssertEqual(repeatedBytes, resolver.configurationBytes)
        XCTAssertEqual(repeatedCount, resolver.configurationCount + 1)
        print(
            "STAGE_D_SYSTEM_RESOLVER=system,nameservers=\(resolver.nameserverCount)," +
            "search=\(resolver.searchDomainCount),bytes=\(resolver.configurationBytes)," +
            "configurations=\(repeatedCount)"
        )
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
        let cloneOutcome = await cloneAgent.run(
            command: "git clone --depth 8 --no-tags --single-branch https://github.com/Da-AiXZ/Wuji.git Wuji-StageC",
            cwd: "."
        )
        guard case .completed = cloneOutcome else {
            let failedSnapshot = try await prepared.store.snapshot(taskID: cloneTask.id)
            let summary = try failedSnapshot.attempts.last?.result?.safeDiagnosticSummaryString()
                ?? StageDSafeDiagnosticSummary.forLoopOutcome(cloneOutcome).encodedString()
            return XCTFail(summary)
        }
        let cloneSnapshot = try await prepared.store.snapshot(taskID: cloneTask.id)
        let cloneResult = try XCTUnwrap(cloneSnapshot.attempts.last?.result)
        XCTAssertEqual(cloneResult.cloneStages.map(\.stage), StageDCloneStage.allCases)
        XCTAssertTrue(cloneResult.cloneStages.allSatisfy { $0.category == .succeeded })
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
        XCTAssertTrue(writeFacts.processTreeObservedAfterTerminalBarrier)
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

    func testClonePipelineShortCircuitsEveryFailureAndUnknownStageWithSafeStructuredOutcome() async throws {
        let command = StageDTestSupport.cloneCommand(identity: String(repeating: "a", count: 64))
        let failures: [(StageDCloneStage, StageDCloneStageCategory, StageDRuntimeFailureCategory)] = [
            (.cloneProcess, .processNonzero, .cloneProcessNonzero),
            (.cloneProcess, .resolverNetworkFailure, .resolverNetworkFailure),
            (.cloneProcess, .remoteAccessFailure, .cloneProcessNonzero),
            (.cloneProcess, .filesystemFailure, .cloneProcessNonzero),
            (.cloneProcess, .checkoutWorktreeFailure, .cloneProcessNonzero),
            (.cloneProcess, .protocolFailure, .cloneProcessNonzero),
            (.cloneProcess, .capabilityUnavailable, .cloneProcessNonzero),
            (.cloneProcess, .timeoutUnknown, .cloneTimeoutUnknown),
            (.cloneProcess, .adapterError, .adapterFixedError),
            (.checkoutExactCommit, .targetUnavailable, .checkoutTargetUnavailable),
            (.remoteVerify, .valueMismatch, .remoteMismatch),
            (.headVerify, .valueMismatch, .headMismatch),
            (.boundedTreeVerify, .treeOverflow, .treeOverflow),
            (.boundedTreeVerify, .treeEscape, .treeEscape),
        ]
        for (failedStage, category, failureCategory) in failures {
            let script = StageDClonePipelineScript(failureStage: failedStage, category: category)
            let outcome = await StageDClonePipeline.run(
                command: command,
                limits: .production,
                step: { await script.run($0) },
                inspectTree: { await script.inspectTree() }
            )
            XCTAssertEqual(outcome.failureCategory, failureCategory)
            XCTAssertEqual(outcome.stages.map(\.stage), StageDCloneStage.allCases)
            XCTAssertEqual(outcome.stages.first { $0.stage == failedStage }?.category, category)
            let failedIndex = try XCTUnwrap(StageDCloneStage.allCases.firstIndex(of: failedStage))
            for later in StageDCloneStage.allCases.dropFirst(failedIndex + 1) {
                XCTAssertEqual(outcome.stages.first { $0.stage == later }?.category, .notRun)
            }
            let calls = await script.calls()
            XCTAssertEqual(calls, Array(StageDCloneStage.allCases.prefix(failedIndex + 1)))
        }
    }

    func testCPIDTableTaskStateFilterExcludesZombieExitingAndMismatchedContext() {
        XCTAssertTrue(wuji_ish_process_tree_task_state_is_active(7, 7, false, false))
        XCTAssertFalse(wuji_ish_process_tree_task_state_is_active(7, 7, true, false))
        XCTAssertFalse(wuji_ish_process_tree_task_state_is_active(7, 7, false, true))
        XCTAssertFalse(wuji_ish_process_tree_task_state_is_active(7, 8, false, false))
        XCTAssertFalse(wuji_ish_process_tree_task_state_is_active(0, 0, false, false))
    }

    func testExit128AndDescendantBarrierPreservesCapturedProcessCategoryAndShortCircuits() async throws {
        let command = StageDTestSupport.cloneCommand(identity: String(repeating: "a", count: 64))
        let quiescent = StageDClonePipelineScript(
            failureStage: .cloneProcess,
            category: .processNonzero
        )
        let quiescentOutcome = await StageDClonePipeline.run(
            command: command,
            limits: .production,
            step: { await quiescent.run($0) },
            inspectTree: { await quiescent.inspectTree() }
        )
        let quiescentStage = try XCTUnwrap(quiescentOutcome.stages.first)
        XCTAssertEqual(quiescentStage.category, .processNonzero)

        let descendant = StageDClonePipelineScript(
            failureStage: .cloneProcess,
            category: .terminalBarrierFailure
        )
        let descendantOutcome = await StageDClonePipeline.run(
            command: command,
            limits: .production,
            step: { await descendant.run($0) },
            inspectTree: { await descendant.inspectTree() }
        )
        let descendantStage = try XCTUnwrap(descendantOutcome.stages.first)
        XCTAssertEqual(descendantStage.category, .terminalBarrierFailure)
        XCTAssertEqual(descendantStage.capturedProcessCategory, quiescentStage.category)
        XCTAssertEqual(descendantStage.facts.finalStateValue, 128)
        XCTAssertEqual(descendantOutcome.failureCategory, .eofTruncationProcessTreeFailure)
        XCTAssertEqual(
            descendantOutcome.stages.dropFirst().map(\.category),
            Array(repeating: .notRun, count: StageDCloneStage.allCases.count - 1)
        )
        let descendantCalls = await descendant.calls()
        XCTAssertEqual(descendantCalls, [.cloneProcess])
    }

    func testCrossWorkspaceWaiterCannotStartWatchdogOrCancelActiveExecution() async throws {
        let gate = StageDGlobalExecutionGate()
        let first = UUID(), second = UUID()
        await gate.acquire(first)
        let secondAcquired = StageDAsyncFlag()
        let waiter = Task {
            await gate.acquire(second)
            await secondAcquired.mark()
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let beforeAcquired = await secondAcquired.value()
        let firstWasActive = await gate.isActive(first)
        let secondWasActive = await gate.isActive(second)
        XCTAssertFalse(beforeAcquired)
        XCTAssertTrue(firstWasActive)
        XCTAssertFalse(secondWasActive)
        await gate.release(first)
        _ = await waiter.value
        let afterAcquired = await secondAcquired.value()
        let secondIsActive = await gate.isActive(second)
        XCTAssertTrue(afterAcquired)
        XCTAssertTrue(secondIsActive)
        await gate.release(second)
    }
}

private actor StageDClonePipelineScript {
    private let failureStage: StageDCloneStage
    private let category: StageDCloneStageCategory
    private var invoked: [StageDCloneStage] = []

    init(failureStage: StageDCloneStage, category: StageDCloneStageCategory) {
        self.failureStage = failureStage
        self.category = category
    }

    func run(_ stage: StageDCloneStage) -> StageDCloneStepResult {
        invoked.append(stage)
        let facts: StageDProcessFacts
        if stage == failureStage {
            switch category {
            case .processNonzero, .resolverNetworkFailure, .remoteAccessFailure,
                    .filesystemFailure, .checkoutWorktreeFailure, .protocolFailure,
                    .capabilityUnavailable, .targetUnavailable:
                facts = StageDTestSupport.facts()
                    .replacingFinalState(kind: "exited", value: 1)
            case .timeoutUnknown:
                facts = StageDTestSupport.facts(cancelled: true)
                    .replacingFinalState(kind: "unknown", value: 0)
            case .adapterError:
                return .failed(nil, fixedError: .guestExec)
            case .terminalBarrierFailure:
                facts = StageDTestSupport.facts()
                    .replacingFinalState(kind: "exited", value: 128)
                    .replacingProcessTree(state: .descendantsRemain, descendants: 1)
            default:
                facts = StageDTestSupport.facts()
            }
        } else {
            facts = StageDTestSupport.facts()
        }
        if stage == failureStage {
            switch category {
            case .processNonzero, .resolverNetworkFailure, .remoteAccessFailure,
                    .filesystemFailure, .checkoutWorktreeFailure, .protocolFailure,
                    .capabilityUnavailable:
                let stderr: String
                switch category {
                case .processNonzero: stderr = "fixed generic clone failure"
                case .resolverNetworkFailure: stderr = "fixed getaddrinfo failure"
                case .remoteAccessFailure: stderr = "fixed repository not found"
                case .filesystemFailure: stderr = "fixed operation not permitted"
                case .checkoutWorktreeFailure: stderr = "fixed unable to checkout working tree"
                case .protocolFailure: stderr = "fixed invalid index-pack"
                case .capabilityUnavailable: stderr = "fixed unable to find remote helper"
                default: stderr = ""
                }
                return .succeeded(.init(facts: facts, stdout: "", stderr: stderr))
            case .targetUnavailable:
                return .failed(.init(facts: facts, stdout: "", stderr: ""), fixedError: .none)
            case .timeoutUnknown:
                return .unknown(.init(facts: facts, stdout: "", stderr: ""), fixedError: .none)
            case .adapterError:
                return .failed(nil, fixedError: .guestExec)
            case .terminalBarrierFailure:
                return .succeeded(.init(
                    facts: facts,
                    stdout: "",
                    stderr: "fixed generic clone failure"
                ))
            case .valueMismatch:
                return .succeeded(.init(facts: facts, stdout: "wrong\n", stderr: ""))
            case .treeOverflow, .treeEscape, .notRun, .succeeded:
                break
            }
        }
        let output: String
        switch stage {
        case .remoteVerify: output = StageDEnvironmentLock.cloneURL + "\n"
        case .headVerify: output = StageDEnvironmentLock.acceptedStageCCommit + "\n"
        default: output = ""
        }
        return .succeeded(.init(facts: facts, stdout: output, stderr: ""))
    }

    func inspectTree() -> StageDCloneTreeResult {
        invoked.append(.boundedTreeVerify)
        guard failureStage == .boundedTreeVerify else {
            return .succeeded(entries: 1, bytes: 1)
        }
        switch category {
        case .treeOverflow: return .overflow(entries: StageDLimits.production.maximumCloneEntries + 1)
        case .treeEscape: return .escape
        default: return .succeeded(entries: 1, bytes: 1)
        }
    }

    func calls() -> [StageDCloneStage] { invoked }
}

private actor StageDAsyncFlag {
    private var marked = false
    func mark() { marked = true }
    func value() -> Bool { marked }
}

private extension StageDProcessFacts {
    func replacingFinalState(kind: String, value: Int32) -> StageDProcessFacts {
        .init(
            rootExitObserved: rootExitObserved,
            finalStateKind: kind,
            finalStateValue: value,
            stdoutEOFObserved: stdoutEOFObserved,
            stderrEOFObserved: stderrEOFObserved,
            stdoutByteCount: stdoutByteCount,
            stderrByteCount: stderrByteCount,
            stdoutSHA256: stdoutSHA256,
            stderrSHA256: stderrSHA256,
            truncated: truncated,
            cancellationRequested: cancellationRequested,
            cancelDelivery: cancelDelivery,
            processTreeState: processTreeState,
            activeDescendantCount: activeDescendantCount,
            processTreeObservedAfterTerminalBarrier: processTreeObservedAfterTerminalBarrier
        )
    }

    func replacingProcessTree(
        state: StageDProcessTreeState,
        descendants: Int
    ) -> StageDProcessFacts {
        .init(
            rootExitObserved: rootExitObserved,
            finalStateKind: finalStateKind,
            finalStateValue: finalStateValue,
            stdoutEOFObserved: stdoutEOFObserved,
            stderrEOFObserved: stderrEOFObserved,
            stdoutByteCount: stdoutByteCount,
            stderrByteCount: stderrByteCount,
            stdoutSHA256: stdoutSHA256,
            stderrSHA256: stderrSHA256,
            truncated: truncated,
            cancellationRequested: cancellationRequested,
            cancelDelivery: cancelDelivery,
            processTreeState: state,
            activeDescendantCount: descendants,
            processTreeObservedAfterTerminalBarrier: processTreeObservedAfterTerminalBarrier
        )
    }
}

private struct StageDCProcessTreeEvidence {
    let rootExitObserved: Bool
    let stdoutEOFObserved: Bool
    let stderrEOFObserved: Bool
    let finalValue: Int32
    let stderrSHA256: String
    let initialActiveDescendantCount: Int32
    let finalActiveDescendantCount: Int32
    let observationCount: UInt32
    let processTreeState: WujiISHProcessTreeKind
}

private func processTreeEvidence(
    _ testCase: WujiISHSelfTestCase
) throws -> StageDCProcessTreeEvidence {
    let raw = try XCTUnwrap(wuji_ish_run_self_test(testCase, 4_096))
    defer { wuji_ish_result_free(raw) }
    let stderrCount = wuji_ish_result_stderr_length(raw)
    let stderr = Data(bytes: wuji_ish_result_stderr(raw), count: stderrCount)
    return .init(
        rootExitObserved: wuji_ish_result_root_exited(raw),
        stdoutEOFObserved: wuji_ish_result_stdout_eof(raw),
        stderrEOFObserved: wuji_ish_result_stderr_eof(raw),
        finalValue: wuji_ish_result_final_value(raw),
        stderrSHA256: ProviderDigest.sha256Hex(stderr),
        initialActiveDescendantCount:
            wuji_ish_result_initial_active_descendant_count(raw),
        finalActiveDescendantCount: wuji_ish_result_active_descendant_count(raw),
        observationCount: wuji_ish_result_process_tree_observation_count(raw),
        processTreeState: wuji_ish_result_process_tree_kind(raw)
    )
}
