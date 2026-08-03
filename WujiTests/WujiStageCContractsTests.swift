import Foundation
import XCTest
@testable import Wuji

final class WujiStageCContractsTests: XCTestCase {
    func testProductionDefaultsAreExactInjectableImplementationValues() {
        let limits = StageCLimits.production
        XCTAssertEqual(limits.maximumProviderTurns, 12)
        XCTAssertEqual(limits.maximumReadExecutions, 24)
        XCTAssertEqual(limits.maximumReadCallsPerBatch, 8)
        XCTAssertEqual(limits.maximumEditProposals, 4)
        XCTAssertEqual(limits.maximumMutations, 1)
        XCTAssertEqual(limits.maximumGoalBytes, 4 * 1_024)
        XCTAssertEqual(limits.maximumPathBytes, 1_024)
        XCTAssertEqual(limits.maximumEditableFileBytes, 1 * 1_024 * 1_024)
        XCTAssertEqual(limits.maximumDiffBytes, 16 * 1_024)
        XCTAssertEqual(limits.maximumProposalRecordBytes, 128 * 1_024)
        XCTAssertEqual(limits.maximumApprovalSeconds, 300)
        XCTAssertEqual(limits.maximumExecutorStreamBytes, 32 * 1_024)
        XCTAssertEqual(limits.maximumDurableEvidenceBytes, 2 * 1_024 * 1_024)
        XCTAssertEqual(limits.maximumDiagnosticBytes, 64 * 1_024)
        XCTAssertEqual(limits.maximumWorkspaceEntries, 50_000)
        XCTAssertEqual(limits.maximumWorkspaceBytes, 2 * 1_024 * 1_024 * 1_024)
    }

    func testProposalComputesBoundedDiffAndExpectedTreeWithoutMutation() async throws {
        let prepared = try await StageCTestSupport.prepare()
        defer { prepared.cleanup() }
        let before = try Data(contentsOf: prepared.targetURL)
        let baseline = try prepared.policy.captureWorkspaceBaseline()
        try FileManager.default.removeItem(at: prepared.targetURL)
        let proposal = try prepared.policy.proposeEdit([
            StageCTestSupport.editCall(id: "proposal-zero-write")
        ], previouslyUsedIDs: [], baseline: baseline)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.targetURL.path))
        XCTAssertEqual(proposal.relativePath, StageCTestSupport.targetPath)
        XCTAssertEqual(proposal.beforeSHA256, ProviderDigest.sha256Hex(before))
        XCTAssertNotEqual(proposal.beforeSHA256, proposal.afterSHA256)
        XCTAssertNotEqual(proposal.beforeTreeSHA256, proposal.expectedAfterTreeSHA256)
        XCTAssertLessThanOrEqual(proposal.diff.utf8.count, prepared.limits.maximumDiffBytes)
        XCTAssertEqual(proposal.diffSHA256, ProviderDigest.sha256Hex(proposal.diff))
    }

    func testContextChunksRulesAndProvesWireBodyBeforeProviderIO() async throws {
        let prepared = try await StageCTestSupport.prepare(
            rootRule: String(repeating: "r", count: 8 * 1_024)
        )
        defer { prepared.cleanup() }
        let context = StageCContextWindow(
            limits: prepared.limits,
            maximumContextBytes: prepared.readLimits.maximumContextBytes
        )
        let messages = try context.baseMessages(
            task: prepared.task,
            session: prepared.session,
            ruleSet: prepared.ruleSet
        )
        let rootRuleMessages = messages.filter {
            $0.content?.contains("source=AGENTS.md") == true
        }
        XCTAssertEqual(rootRuleMessages.count, 2)
        XCTAssertTrue(messages.allSatisfy {
            ($0.content?.utf8.count ?? 0) <= ProviderLimits.maximumTurnMessageBytes
        })
        let material = try context.request(messages: messages, requireTool: true)
        let upperBound = try DeepSeekRequestBodyBounds.maximumEncodedByteCount(for: material.request)
        XCTAssertLessThanOrEqual(upperBound, ProviderLimits.maximumRequestBodyBytes)
        XCTAssertEqual(material.inputSHA256.count, 64)
    }

    func testEditMustBeSingleAndCannotMixWithReadBatch() async throws {
        let prepared = try await StageCTestSupport.prepare()
        defer { prepared.cleanup() }
        let edit = StageCTestSupport.editCall(id: "edit-mixed")
        let read = StageCTestSupport.call(
            id: "read-mixed", name: "read", arguments: ["path": StageCTestSupport.targetPath]
        )
        XCTAssertThrowsError(try prepared.policy.proposeEdit(
            [edit, read],
            previouslyUsedIDs: [],
            baseline: try prepared.policy.captureWorkspaceBaseline()
        )) {
            XCTAssertEqual($0 as? StageCError, .editBatchCount)
        }
        XCTAssertThrowsError(try prepared.policy.authorizeReadBatch([edit], previouslyUsedIDs: [])) {
            XCTAssertEqual($0 as? StageCError, .mixedBatch)
        }
    }

    func testUnknownWriteShellNetworkGitCreateRenameDeleteAndOverwriteFailClosed() async throws {
        let prepared = try await StageCTestSupport.prepare()
        defer { prepared.cleanup() }
        for (index, name) in ["write", "shell", "network", "git", "create", "rename", "delete"].enumerated() {
            let call = StageCTestSupport.call(id: "forbidden-\(index)", name: name, arguments: [:])
            XCTAssertThrowsError(try prepared.policy.authorizeReadBatch([call], previouslyUsedIDs: []))
        }
        let overwrite = StageCTestSupport.call(
            id: "overwrite",
            name: "edit",
            arguments: [
                "path": StageCTestSupport.targetPath,
                "expected_before": StageCTestSupport.beforeContent,
                "replacement": "replacement"
            ]
        )
        XCTAssertThrowsError(try prepared.policy.proposeEdit(
            [overwrite],
            previouslyUsedIDs: [],
            baseline: try prepared.policy.captureWorkspaceBaseline()
        )) {
            XCTAssertEqual($0 as? StageCError, .invalidArguments)
        }

        let singleLinePath = "SingleLine.txt"
        let singleLineURL = prepared.workspace.canonicalRootURL.appendingPathComponent(singleLinePath)
        try Data("whole-file".utf8).write(to: singleLineURL)
        let overwriteTask = try await prepared.taskStore.create(
            session: prepared.session,
            workspace: prepared.workspace,
            ruleSet: prepared.ruleSet,
            targetRelativePath: singleLinePath
        )
        let overwritePolicy = StageCEditPolicy(
            task: overwriteTask,
            workspace: prepared.workspace,
            ruleSet: prepared.ruleSet,
            readLimits: prepared.readLimits,
            limits: prepared.limits
        )
        XCTAssertThrowsError(try overwritePolicy.proposeEdit([
            StageCTestSupport.editCall(
                id: "whole-file-overwrite",
                path: singleLinePath,
                old: "whole-file",
                new: "replacement"
            )
        ], previouslyUsedIDs: [], baseline: try overwritePolicy.captureWorkspaceBaseline())) {
            XCTAssertEqual($0 as? StageCError, .overwriteRejected)
        }

        let binaryPath = "Binary.txt"
        try Data([0x61, 0x00, 0x62]).write(
            to: prepared.workspace.canonicalRootURL.appendingPathComponent(binaryPath)
        )
        let binaryTask = try await prepared.taskStore.create(
            session: prepared.session,
            workspace: prepared.workspace,
            ruleSet: prepared.ruleSet,
            targetRelativePath: binaryPath
        )
        let binaryPolicy = StageCEditPolicy(
            task: binaryTask,
            workspace: prepared.workspace,
            ruleSet: prepared.ruleSet,
            readLimits: prepared.readLimits,
            limits: prepared.limits
        )
        XCTAssertThrowsError(try binaryPolicy.proposeEdit([
            StageCTestSupport.editCall(
                id: "binary-rejected",
                path: binaryPath,
                old: "a",
                new: "b"
            )
        ], previouslyUsedIDs: [], baseline: try binaryPolicy.captureWorkspaceBaseline())) {
            XCTAssertEqual($0 as? StageCError, .unsupportedFile)
        }
    }

    func testParentAbsoluteOtherTargetMarkerGitAndSymlinkAreRejected() async throws {
        let prepared = try await StageCTestSupport.prepare()
        defer { prepared.cleanup() }
        for (index, path) in ["../outside.txt", "/absolute.txt", "README.md", StageAWorkspaceMarker.fileName].enumerated() {
            let call = StageCTestSupport.editCall(id: "path-\(index)", path: path)
            XCTAssertThrowsError(try prepared.policy.proposeEdit(
                [call],
                previouslyUsedIDs: [],
                baseline: try prepared.policy.captureWorkspaceBaseline()
            ))
        }
        let gitURL = prepared.workspace.canonicalRootURL.appendingPathComponent(".git/config")
        try FileManager.default.createDirectory(
            at: gitURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("secret = no\n".utf8).write(to: gitURL)
        let gitTask = try await prepared.taskStore.create(
            session: prepared.session,
            workspace: prepared.workspace,
            ruleSet: prepared.ruleSet,
            targetRelativePath: ".git/config"
        )
        let gitPolicy = StageCEditPolicy(
            task: gitTask, workspace: prepared.workspace, ruleSet: prepared.ruleSet,
            readLimits: prepared.readLimits, limits: prepared.limits
        )
        XCTAssertThrowsError(try gitPolicy.proposeEdit([
            StageCTestSupport.editCall(id: "git-path", path: ".git/config", old: "secret = no", new: "secret = yes")
        ], previouslyUsedIDs: [], baseline: try gitPolicy.captureWorkspaceBaseline())) {
            XCTAssertEqual($0 as? StageCError, .protectedPath)
        }

        let linkURL = prepared.workspace.canonicalRootURL.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: prepared.targetURL)
        let linkTask = try await prepared.taskStore.create(
            session: prepared.session,
            workspace: prepared.workspace,
            ruleSet: prepared.ruleSet,
            targetRelativePath: "link.txt"
        )
        let linkPolicy = StageCEditPolicy(
            task: linkTask, workspace: prepared.workspace, ruleSet: prepared.ruleSet,
            readLimits: prepared.readLimits, limits: prepared.limits
        )
        XCTAssertThrowsError(try linkPolicy.proposeEdit([
            StageCTestSupport.editCall(id: "symlink", path: "link.txt")
        ], previouslyUsedIDs: [], baseline: try linkPolicy.captureWorkspaceBaseline())) {
            XCTAssertEqual($0 as? StageCError, .symlinkRejected)
        }

        let ordinaryName = prepared.workspace.canonicalRootURL
            .appendingPathComponent("notes.gitignore.txt")
        try Data(StageCTestSupport.beforeContent.utf8).write(to: ordinaryName)
        let ordinaryTask = try await prepared.taskStore.create(
            session: prepared.session,
            workspace: prepared.workspace,
            ruleSet: prepared.ruleSet,
            targetRelativePath: "notes.gitignore.txt"
        )
        let ordinaryPolicy = StageCEditPolicy(
            task: ordinaryTask,
            workspace: prepared.workspace,
            ruleSet: prepared.ruleSet,
            readLimits: prepared.readLimits,
            limits: prepared.limits
        )
        XCTAssertNoThrow(try ordinaryPolicy.proposeEdit([
            StageCTestSupport.editCall(
                id: "ordinary-git-substring",
                path: "notes.gitignore.txt"
            )
        ], previouslyUsedIDs: [], baseline: try ordinaryPolicy.captureWorkspaceBaseline()))

        let other = try await StageCTestSupport.prepare()
        defer { other.cleanup() }
        let otherWorkspacePolicy = StageCEditPolicy(
            task: prepared.task,
            workspace: other.workspace,
            ruleSet: prepared.ruleSet,
            readLimits: prepared.readLimits,
            limits: prepared.limits
        )
        XCTAssertThrowsError(try otherWorkspacePolicy.captureWorkspaceBaseline()) {
            XCTAssertEqual($0 as? StageCError, .invalidBinding)
        }
    }

    func testPostWriteVerifierRejectsAnyAdditionalWorkspaceChange() async throws {
        let prepared = try await StageCTestSupport.prepare()
        defer { prepared.cleanup() }
        let proposal = try prepared.policy.proposeEdit([
            StageCTestSupport.editCall(id: "extra-file")
        ], previouslyUsedIDs: [], baseline: try prepared.policy.captureWorkspaceBaseline())
        try StageCTestSupport.applyProposal(proposal, targetURL: prepared.targetURL)
        try Data("unexpected\n".utf8).write(
            to: prepared.workspace.canonicalRootURL.appendingPathComponent("unexpected.txt")
        )
        XCTAssertThrowsError(try prepared.policy.verifyApplied(proposal)) {
            XCTAssertEqual($0 as? StageCError, .verificationFailed)
        }
    }
}

final class StageCTestPrepared {
    let container: URL
    let workspace: StageBReadyWorkspace
    let ruleSet: StageBRuleSet
    let session: StageBSessionRecord
    let taskStore: StageCTaskStore
    let task: StageCTaskRecord
    let policy: StageCEditPolicy
    let limits: StageCLimits
    let readLimits: StageBLimits

    var targetURL: URL { workspace.canonicalRootURL.appendingPathComponent(StageCTestSupport.targetPath) }

    init(
        container: URL,
        workspace: StageBReadyWorkspace,
        ruleSet: StageBRuleSet,
        session: StageBSessionRecord,
        taskStore: StageCTaskStore,
        task: StageCTaskRecord,
        limits: StageCLimits,
        readLimits: StageBLimits
    ) {
        self.container = container
        self.workspace = workspace
        self.ruleSet = ruleSet
        self.session = session
        self.taskStore = taskStore
        self.task = task
        self.limits = limits
        self.readLimits = readLimits
        policy = StageCEditPolicy(
            task: task, workspace: workspace, ruleSet: ruleSet,
            readLimits: readLimits, limits: limits
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: container) }
}

enum StageCTestSupport {
    static let targetPath = "Sources/Configuration/AppProfile.txt"
    static let oldLine = "release_channel = preview"
    static let newLine = "release_channel = stable"
    static let beforeContent = "application_name = Wuji\n\(oldLine)\ntelemetry_mode = bounded\n"

    static func prepare(rootRule: String = "Root Stage C test rules\n") async throws -> StageCTestPrepared {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("WujiStageCTests-\(UUID().uuidString)", isDirectory: true)
        let source = container.appendingPathComponent("ExternalProject", isDirectory: true)
        let configuration = source.appendingPathComponent("Sources/Configuration", isDirectory: true)
        try FileManager.default.createDirectory(at: configuration, withIntermediateDirectories: true)
        try Data(rootRule.utf8).write(to: source.appendingPathComponent("AGENTS.md"))
        try Data("Nested Stage C test rules\n".utf8).write(to: source.appendingPathComponent("Sources/AGENTS.md"))
        try Data(beforeContent.utf8).write(to: source.appendingPathComponent(targetPath))
        try Data("preserve\n".utf8).write(to: source.appendingPathComponent("README.md"))

        let stageAPolicy = StageAImportPolicy(
            maximumEntryCount: 64, maximumFileBytes: 32 * 1_024,
            maximumTotalBytes: 256 * 1_024, maximumCompressionRatio: 20,
            maximumPathBytes: 1_024, maximumDirectoryDepth: 16,
            minimumRemainingCapacityBytes: 0, maximumDiagnosticBytes: 8 * 1_024
        )
        let stageAStore = StageAWorkspaceStore(
            rootURL: container.appendingPathComponent("StageA"), policy: stageAPolicy
        )
        let importer = StageAWorkspaceImporter(
            store: stageAStore,
            policy: stageAPolicy,
            coordinator: StageCTestPassThroughCoordinator()
        )
        let imported = await importer.importItem(at: source, expectedKind: .folder)
        guard imported.phase == .ready else { throw StageCError.invalidBinding }
        let readLimits = smallReadLimits()
        let sessionStore = StageBSessionStore(
            rootURL: container.appendingPathComponent("StageB"), limits: readLimits
        )
        let prepared = try await StageBSessionCoordinator(
            stageAStore: stageAStore,
            sessionStore: sessionStore,
            limits: readLimits
        ).create(
            importID: imported.id,
            goal: StageBGoal(
                text: "Inspect and propose the bounded release channel edit",
                exactQuery: oldLine,
                expectedRelativePath: targetPath,
                limits: readLimits
            )
        )
        let completion = StageBCompletion(
            sessionID: prepared.session.id,
            workspaceIdentitySHA256: prepared.session.workspaceIdentitySHA256,
            goalBindingSHA256: prepared.session.goal.bindingSHA256,
            ruleSetBindingSHA256: prepared.ruleSet.bindingSHA256,
            relativePath: targetPath,
            query: oldLine,
            providerRequestCount: 1,
            toolExecutionCount: 3,
            evidenceChainSHA256: ProviderDigest.sha256Hex("stage-c-test-chain")
        )
        let completed = try await sessionStore.transition(
            prepared.session, to: .completed, completion: completion
        )
        let limits = smallLimits()
        let taskStore = try StageCTaskStore(
            rootURL: container.appendingPathComponent("StageC"), limits: limits
        )
        let task = try await taskStore.create(
            session: completed,
            workspace: prepared.workspace,
            ruleSet: prepared.ruleSet,
            targetRelativePath: targetPath
        )
        return StageCTestPrepared(
            container: container, workspace: prepared.workspace, ruleSet: prepared.ruleSet,
            session: completed, taskStore: taskStore, task: task,
            limits: limits, readLimits: readLimits
        )
    }

    static func call(
        id: String,
        name: String,
        arguments: [String: String]
    ) -> ProviderTurnToolCall {
        let data = try! JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
        return .init(id: id, name: name, arguments: String(decoding: data, as: UTF8.self))
    }

    static func editCall(
        id: String,
        path: String = targetPath,
        old: String = oldLine,
        new: String = newLine
    ) -> ProviderTurnToolCall {
        call(id: id, name: "edit", arguments: [
            "path": path, "expected_before": old, "replacement": new
        ])
    }

    static func applyProposal(_ proposal: StageCEditProposal, targetURL: URL) throws {
        let before = try String(contentsOf: targetURL, encoding: .utf8)
        let after = before.replacingOccurrences(of: proposal.expectedOld, with: proposal.replacement)
        try Data(after.utf8).write(to: targetURL)
    }

    static func smallLimits() -> StageCLimits {
        StageCLimits(
            maximumProviderTurns: 6, maximumReadExecutions: 8,
            maximumReadCallsPerBatch: 4, maximumEditProposals: 3,
            maximumMutations: 1, maximumGoalBytes: 1_024,
            maximumPathBytes: 1_024, maximumEditableFileBytes: 32 * 1_024,
            maximumDiffBytes: 2 * 1_024, maximumProposalRecordBytes: 64 * 1_024,
            maximumApprovalSeconds: 60, maximumExecutorStreamBytes: 8 * 1_024,
            maximumDurableEvidenceBytes: 256 * 1_024, maximumDiagnosticBytes: 8 * 1_024,
            maximumWorkspaceEntries: 64, maximumWorkspaceBytes: 256 * 1_024
        )
    }

    static func smallReadLimits() -> StageBLimits {
        StageBLimits(
            maximumProviderTurns: 6, maximumToolExecutions: 8,
            maximumToolCallsPerBatch: 4, maximumGoalBytes: 1_024,
            maximumPathBytes: 1_024, maximumQueryBytes: 256,
            maximumRuleFiles: 8, maximumRuleFileBytes: 8 * 1_024,
            maximumRuleAggregateBytes: 16 * 1_024, maximumContextBytes: 24 * 1_024,
            maximumListEntries: 16, maximumSearchMatches: 8,
            maximumReadBytes: 4 * 1_024, maximumLineBytes: 1_024,
            maximumExecutorStreamBytes: 8 * 1_024,
            maximumModelObservationBytes: 4 * 1_024,
            maximumDurableEvidenceBytes: 256 * 1_024, maximumDiagnosticBytes: 8 * 1_024
        )
    }
}

private struct StageCTestPassThroughCoordinator: StageAExternalFileCoordinating, @unchecked Sendable {
    func coordinateRead<T>(at url: URL, _ body: (URL) throws -> T) throws -> T { try body(url) }
}
