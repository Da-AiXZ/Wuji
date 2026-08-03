import Foundation
import XCTest
@testable import Wuji

final class WujiStageBTests: XCTestCase {
    func testProductionDefaultsAreExactInjectableImplementationValues() {
        let limits = StageBLimits.production
        XCTAssertEqual(limits.maximumProviderTurns, 12)
        XCTAssertEqual(limits.maximumToolExecutions, 24)
        XCTAssertEqual(limits.maximumToolCallsPerBatch, 8)
        XCTAssertEqual(limits.maximumGoalBytes, 4 * 1_024)
        XCTAssertEqual(limits.maximumPathBytes, 1_024)
        XCTAssertEqual(limits.maximumQueryBytes, 512)
        XCTAssertEqual(limits.maximumRuleFiles, 16)
        XCTAssertEqual(limits.maximumRuleFileBytes, 16 * 1_024)
        XCTAssertEqual(limits.maximumRuleAggregateBytes, 48 * 1_024)
        XCTAssertEqual(limits.maximumContextBytes, 48 * 1_024)
        XCTAssertEqual(limits.maximumListEntries, 128)
        XCTAssertEqual(limits.maximumSearchMatches, 64)
        XCTAssertEqual(limits.maximumReadBytes, 24 * 1_024)
        XCTAssertEqual(limits.maximumLineBytes, 2 * 1_024)
        XCTAssertEqual(limits.maximumExecutorStreamBytes, 32 * 1_024)
        XCTAssertEqual(limits.maximumModelObservationBytes, 8 * 1_024)
        XCTAssertEqual(limits.maximumDurableEvidenceBytes, 2 * 1_024 * 1_024)
        XCTAssertEqual(limits.maximumDiagnosticBytes, 64 * 1_024)
        XCTAssertNotEqual(smallLimits(), limits)
    }

    func testStageAReadyMarkerCreatesExactSessionBindingAndColdOpenPreservesIt() async throws {
        let fixture = try makeFixture(
            nestedDirectory: "Modules/Parser",
            fileName: "TokenCatalog.swift",
            query: "ParserReadyToken"
        )
        defer { fixture.cleanup() }
        let prepared = try await prepare(fixture: fixture)
        let snapshot = try await prepared.store.snapshot(sessionID: prepared.context.session.id)

        XCTAssertEqual(prepared.context.session.importID, fixture.importRecordID)
        XCTAssertEqual(prepared.context.session.workspaceID, prepared.context.workspace.workspaceID)
        XCTAssertEqual(
            prepared.context.session.workspaceIdentitySHA256,
            prepared.context.workspace.identitySHA256
        )
        XCTAssertEqual(prepared.context.session.markerSHA256, prepared.context.workspace.markerSHA256)
        XCTAssertEqual(snapshot.session.phase, .rulesReady)

        let restored = try await prepared.coordinator.restore(sessionID: prepared.context.session.id)
        XCTAssertEqual(restored.session.workspaceIdentitySHA256, prepared.context.session.workspaceIdentitySHA256)
        XCTAssertEqual(restored.session.goal, prepared.context.session.goal)
        XCTAssertEqual(restored.ruleSet.bindingSHA256, prepared.context.ruleSet.bindingSHA256)
        let restoredSnapshot = try await prepared.store.snapshot(
            sessionID: prepared.context.session.id
        )
        XCTAssertTrue(
            restoredSnapshot.attempts
                .filter { $0.kind == .provider || $0.kind == .executor }.isEmpty
        )
    }

    func testRootAndNestedAgentsRulesAreScopedAndBoundToAdmission() async throws {
        let fixture = try makeFixture(
            nestedDirectory: "Sources/Feature",
            fileName: "FeatureFlag.swift",
            query: "NestedFeatureReady"
        )
        defer { fixture.cleanup() }
        let prepared = try await prepare(fixture: fixture)
        XCTAssertEqual(
            prepared.context.ruleSet.descriptors.map(\.relativePath),
            ["AGENTS.md", "Sources/AGENTS.md"]
        )

        let policy = StageBReadOnlyPolicy(
            workspace: prepared.context.workspace,
            ruleSet: prepared.context.ruleSet,
            limits: smallLimits()
        )
        let rootRead = try policy.authorizeBatch([
            call(id: "root", name: "read", arguments: ["path": "README.md"])
        ])[0].tool
        let nestedRead = try policy.authorizeBatch([
            call(id: "nested", name: "read", arguments: ["path": "Sources/Feature/FeatureFlag.swift"])
        ])[0].tool
        XCTAssertNotEqual(rootRead.ruleSetSHA256, nestedRead.ruleSetSHA256)
        XCTAssertEqual(policy.applicableRules(for: rootRead).map(\.relativePath), ["AGENTS.md"])
        XCTAssertEqual(
            policy.applicableRules(for: nestedRead).map(\.relativePath),
            ["AGENTS.md", "Sources/AGENTS.md"]
        )
    }

    func testGeneralDifferentDirectoryFileGoalAndQueryCompletesWithoutS3FixtureContract() async throws {
        let fixture = try makeFixture(
            nestedDirectory: "Modules/Parser",
            fileName: "TokenCatalog.swift",
            query: "ParserReadyToken"
        )
        defer { fixture.cleanup() }
        let prepared = try await prepare(fixture: fixture)
        let calls = [
            call(id: "list-a", name: "list", arguments: ["path": ""]),
            call(id: "search-a", name: "search", arguments: [
                "path": "Modules", "query": fixture.query
            ]),
            call(id: "read-a", name: "read", arguments: ["path": fixture.relativeFilePath])
        ]
        let provider = StageBScriptedProvider(outcomes: [
            .decision(.toolCalls(
                ProviderTurnMessage(role: .assistant, toolCalls: calls),
                calls
            )),
            .decision(.finish(ProviderTurnMessage(role: .assistant, content: "done")))
        ])
        let executor = StageBMockExecutor(
            query: fixture.query,
            relativePath: fixture.relativeFilePath,
            topLevelEntry: "Modules"
        )
        let agent = makeAgent(prepared, provider: provider, executor: executor)

        guard case let .completed(completion) = await agent.run(
            sessionID: prepared.context.session.id
        ) else { return XCTFail("general Stage B project did not complete") }
        XCTAssertEqual(completion.relativePath, fixture.relativeFilePath)
        XCTAssertEqual(completion.query, fixture.query)
        let executedNames = await executor.executedNames()
        XCTAssertEqual(executedNames, [.list, .search, .read])
        XCTAssertFalse(fixture.query.contains("WUJI_S3_TARGET"))
        let snapshot = try await prepared.store.snapshot(sessionID: prepared.context.session.id)
        let externalGroups = Dictionary(
            grouping: snapshot.attempts.filter { $0.kind == .provider || $0.kind == .executor },
            by: \.operationID
        )
        XCTAssertFalse(externalGroups.isEmpty)
        XCTAssertTrue(externalGroups.values.allSatisfy {
            $0.map(\.phase) == [.intentRecorded, .succeeded]
                && Set($0.map(\.attemptID)).count == 1
        })

        let coldStore = StageBSessionStore(
            rootURL: prepared.store.rootURL,
            limits: prepared.limits
        )
        let unusedProvider = StageBScriptedProvider(outcomes: [.failure(.emptyResponse)])
        let unusedExecutor = StageBMockExecutor(
            query: fixture.query,
            relativePath: fixture.relativeFilePath,
            topLevelEntry: "Modules"
        )
        let coldAgent = StageBReadOnlyAgent(
            provider: unusedProvider,
            executor: unusedExecutor,
            policy: StageBReadOnlyPolicy(
                workspace: prepared.context.workspace,
                ruleSet: prepared.context.ruleSet,
                limits: prepared.limits
            ),
            sessionStore: coldStore,
            workspace: prepared.context.workspace,
            ruleSet: prepared.context.ruleSet,
            limits: prepared.limits
        )
        let coldOutcome = await coldAgent.run(sessionID: prepared.context.session.id)
        let coldProviderCalls = await unusedProvider.callCount()
        let coldExecutorCalls = await unusedExecutor.executedNames()
        XCTAssertEqual(coldOutcome, .completed(completion))
        XCTAssertEqual(coldProviderCalls, 0)
        XCTAssertEqual(coldExecutorCalls, [])
    }

    func testWholeBatchRejectionReturnsEveryOriginalIDAndPerformsZeroExecutorIO() async throws {
        let fixture = try makeFixture(
            nestedDirectory: "Sources/Feature",
            fileName: "FeatureFlag.swift",
            query: "NestedFeatureReady"
        )
        defer { fixture.cleanup() }
        let prepared = try await prepare(fixture: fixture)
        let rejected = [
            call(id: "bad-list", name: "list", arguments: ["path": ""]),
            call(id: "bad-read", name: "read", arguments: ["path": "../outside.txt"])
        ]
        let provider = StageBScriptedProvider(outcomes: [
            .decision(.toolCalls(
                ProviderTurnMessage(role: .assistant, toolCalls: rejected),
                rejected
            )),
            .unknown(.reconciliationRequired)
        ])
        let executor = StageBMockExecutor(
            query: fixture.query,
            relativePath: fixture.relativeFilePath,
            topLevelEntry: "Sources"
        )
        let agent = makeAgent(prepared, provider: provider, executor: executor)
        let rejectedOutcome = await agent.run(sessionID: prepared.context.session.id)
        let rejectedExecutions = await executor.executedNames()
        XCTAssertEqual(rejectedOutcome, .reconciliationRequired)
        XCTAssertEqual(rejectedExecutions, [])

        let requests = await provider.requests()
        XCTAssertEqual(requests.count, 2)
        let feedback = requests[1].messages.filter { $0.role == .tool }
        XCTAssertEqual(feedback.map(\.toolCallID), ["bad-list", "bad-read"])
        XCTAssertTrue(feedback.allSatisfy { $0.content?.contains("not_executed") == true })
        let rejectedSnapshot = try await prepared.store.snapshot(
            sessionID: prepared.context.session.id
        )
        let evidence = rejectedSnapshot.attempts.filter { $0.category == .policyNotExecuted }
        XCTAssertEqual(evidence.count, 2)
        let rejectedGroups = Dictionary(
            grouping: rejectedSnapshot.attempts.filter {
                $0.kind == .executor && ($0.category == .policyNotExecuted || $0.phase == .intentRecorded)
            },
            by: \.operationID
        )
        XCTAssertEqual(rejectedGroups.count, 2)
        XCTAssertTrue(rejectedGroups.values.allSatisfy {
            $0.map(\.phase) == [.intentRecorded, .failed]
                && Set($0.map(\.attemptID)).count == 1
        })
    }

    func testProviderUnknownColdRecoveryDoesNotCreateSecondAttempt() async throws {
        let fixture = try makeFixture(
            nestedDirectory: "Sources/Feature",
            fileName: "FeatureFlag.swift",
            query: "NestedFeatureReady"
        )
        defer { fixture.cleanup() }
        let prepared = try await prepare(fixture: fixture)
        let provider = StageBScriptedProvider(outcomes: [.unknown(.reconciliationRequired)])
        let executor = StageBMockExecutor(
            query: fixture.query,
            relativePath: fixture.relativeFilePath,
            topLevelEntry: "Sources"
        )
        let first = makeAgent(prepared, provider: provider, executor: executor)
        let firstOutcome = await first.run(sessionID: prepared.context.session.id)
        let firstCallCount = await provider.callCount()
        XCTAssertEqual(firstOutcome, .reconciliationRequired)
        XCTAssertEqual(firstCallCount, 1)

        let second = makeAgent(prepared, provider: provider, executor: executor)
        let secondOutcome = await second.run(sessionID: prepared.context.session.id)
        let secondCallCount = await provider.callCount()
        let providerUnknownExecutions = await executor.executedNames()
        XCTAssertEqual(secondOutcome, .reconciliationRequired)
        XCTAssertEqual(secondCallCount, 1)
        XCTAssertEqual(providerUnknownExecutions, [])
    }

    func testExecutorUnknownColdRecoveryDoesNotCreateSecondAttempt() async throws {
        let fixture = try makeFixture(
            nestedDirectory: "Sources/Feature",
            fileName: "FeatureFlag.swift",
            query: "NestedFeatureReady"
        )
        defer { fixture.cleanup() }
        let prepared = try await prepare(fixture: fixture)
        let calls = [call(id: "unknown-list", name: "list", arguments: ["path": ""])]
        let provider = StageBScriptedProvider(outcomes: [
            .decision(.toolCalls(ProviderTurnMessage(role: .assistant, toolCalls: calls), calls))
        ])
        let executor = StageBMockExecutor(
            query: fixture.query,
            relativePath: fixture.relativeFilePath,
            topLevelEntry: "Sources",
            unknownOnFirstCall: true
        )
        let first = makeAgent(prepared, provider: provider, executor: executor)
        let firstOutcome = await first.run(sessionID: prepared.context.session.id)
        let firstExecutions = await executor.executedNames()
        XCTAssertEqual(firstOutcome, .reconciliationRequired)
        XCTAssertEqual(firstExecutions, [.list])

        let second = makeAgent(prepared, provider: provider, executor: executor)
        let secondOutcome = await second.run(sessionID: prepared.context.session.id)
        let secondExecutions = await executor.executedNames()
        XCTAssertEqual(secondOutcome, .reconciliationRequired)
        XCTAssertEqual(secondExecutions, [.list])
    }

    func testExecutorIntentIsDurableBeforeExecuteBoundary() async throws {
        let fixture = try makeFixture(
            nestedDirectory: "Sources/Feature",
            fileName: "FeatureFlag.swift",
            query: "NestedFeatureReady"
        )
        defer { fixture.cleanup() }
        let prepared = try await prepare(fixture: fixture)
        let calls = [call(id: "intent-list", name: "list", arguments: ["path": ""])]
        let provider = StageBScriptedProvider(outcomes: [
            .decision(.toolCalls(ProviderTurnMessage(role: .assistant, toolCalls: calls), calls))
        ])
        let executor = StageBIntentInspectingExecutor(
            store: prepared.store,
            sessionID: prepared.context.session.id
        )
        let agent = StageBReadOnlyAgent(
            provider: provider,
            executor: executor,
            policy: StageBReadOnlyPolicy(
                workspace: prepared.context.workspace,
                ruleSet: prepared.context.ruleSet,
                limits: prepared.limits
            ),
            sessionStore: prepared.store,
            workspace: prepared.context.workspace,
            ruleSet: prepared.context.ruleSet,
            limits: prepared.limits
        )

        let outcome = await agent.run(sessionID: prepared.context.session.id)
        let intentWasVisible = await executor.intentWasVisibleAtBoundary()
        XCTAssertEqual(outcome, .reconciliationRequired)
        XCTAssertTrue(intentWasVisible)
    }

    func testWriteShellGitNetworkInstallAndMalformedToolsFailWholeBatchBeforeIO() async throws {
        let fixture = try makeFixture(
            nestedDirectory: "Sources/Feature",
            fileName: "FeatureFlag.swift",
            query: "NestedFeatureReady"
        )
        defer { fixture.cleanup() }
        let prepared = try await prepare(fixture: fixture)
        let policy = StageBReadOnlyPolicy(
            workspace: prepared.context.workspace,
            ruleSet: prepared.context.ruleSet,
            limits: smallLimits()
        )
        for name in ["write", "edit", "rename", "delete", "shell", "git", "network", "install"] {
            XCTAssertThrowsError(try policy.authorizeBatch([
                call(id: "id-\(name)", name: name, arguments: ["path": "README.md"])
            ]))
        }
        XCTAssertEqual(Set(StageBToolName.allCases.map(\.rawValue)), Set(["list", "search", "read"]))
    }

    func testAbsoluteParentMarkerOtherWorkspaceAndSymlinkEscapeFailClosed() async throws {
        let fixture = try makeFixture(
            nestedDirectory: "Sources/Feature",
            fileName: "FeatureFlag.swift",
            query: "NestedFeatureReady"
        )
        defer { fixture.cleanup() }
        let prepared = try await prepare(fixture: fixture)
        let policy = StageBReadOnlyPolicy(
            workspace: prepared.context.workspace,
            ruleSet: prepared.context.ruleSet,
            limits: smallLimits()
        )
        for path in [
            "/tmp/outside", "../outside", "C:/outside", StageAWorkspaceMarker.fileName,
            "../../Workspaces/other", "WujiStageB/Sessions/session.json"
        ] {
            XCTAssertThrowsError(try policy.authorizeBatch([
                call(id: "reject-\(ProviderDigest.sha256Hex(path).prefix(8))", name: "read", arguments: ["path": path])
            ]))
        }

        let nestedSameName = prepared.context.workspace.canonicalRootURL
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent(StageAWorkspaceMarker.fileName)
        try Data("ordinary nested project content\n".utf8).write(to: nestedSameName)
        let nestedOrdinaryRead = try policy.authorizeBatch([
            call(
                id: "nested-same-name",
                name: "read",
                arguments: ["path": "Sources/\(StageAWorkspaceMarker.fileName)"]
            )
        ])
        XCTAssertEqual(nestedOrdinaryRead.count, 1)

        let outside = fixture.root.deletingLastPathComponent().appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        let link = prepared.context.workspace.canonicalRootURL.appendingPathComponent("escape-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try policy.authorizeBatch([
            call(id: "symlink-read", name: "read", arguments: ["path": "escape-link"])
        ]))
        XCTAssertThrowsError(try policy.authorizeBatch([
            call(id: "symlink-search", name: "search", arguments: ["path": "", "query": fixture.query])
        ]))
    }

    func testProviderContextIsProvenBoundedBeforeSendWithoutSilentRuleTruncation() async throws {
        let fixture = try makeFixture(
            nestedDirectory: "Sources/Feature",
            fileName: "FeatureFlag.swift",
            query: "NestedFeatureReady"
        )
        defer { fixture.cleanup() }
        let prepared = try await prepare(fixture: fixture)
        let window = StageBContextWindow(limits: smallLimits())
        let messages = try window.baseMessages(
            session: prepared.context.session,
            ruleSet: prepared.context.ruleSet
        )
        XCTAssertTrue(messages.allSatisfy {
            ($0.content?.utf8.count ?? 0) <= ProviderLimits.maximumTurnMessageBytes
        })
        let injected = messages.compactMap(\.content).joined(separator: "\n")
        for rule in prepared.context.ruleSet.rules {
            XCTAssertTrue(injected.contains(rule.content))
        }
        let normalRequest = try window.request(
            baseMessages: messages,
            observations: [],
            lastExchange: [],
            requireTool: true
        )
        XCTAssertLessThanOrEqual(
            try DeepSeekRequestBodyBounds.maximumEncodedByteCount(for: normalRequest),
            ProviderLimits.maximumRequestBodyBytes
        )

        let oversizedRule = StageBRule(
            relativePath: "AGENTS.md",
            scopePath: "",
            content: String(repeating: "R", count: 49 * 1_024),
            contentSHA256: ProviderDigest.sha256Hex(String(repeating: "R", count: 49 * 1_024))
        )
        let oversizedSet = StageBRuleSet(rules: [oversizedRule], bindingSHA256: ProviderDigest.sha256Hex("oversized"))
        var session = prepared.context.session
        session.ruleSetBindingSHA256 = oversizedSet.bindingSHA256
        session.rules = oversizedSet.descriptors
        XCTAssertThrowsError(try StageBContextWindow().baseMessages(session: session, ruleSet: oversizedSet)) {
            XCTAssertEqual($0 as? StageBError, .contextLimit)
        }

        let escapedRules = (0..<3).map { index in
            let path = index == 0 ? "AGENTS.md" : "Scope\(index)/AGENTS.md"
            let scope = index == 0 ? "" : "Scope\(index)"
            let content = String(repeating: "\"", count: 15 * 1_024)
            return StageBRule(
                relativePath: path,
                scopePath: scope,
                content: content,
                contentSHA256: ProviderDigest.sha256Hex(content)
            )
        }
        let escapedSet = StageBRuleSet(
            rules: escapedRules,
            bindingSHA256: ProviderDigest.sha256Hex("escaped")
        )
        session.ruleSetBindingSHA256 = escapedSet.bindingSHA256
        session.rules = escapedSet.descriptors
        XCTAssertThrowsError(
            try StageBContextWindow().baseMessages(session: session, ruleSet: escapedSet)
        ) {
            XCTAssertEqual($0 as? StageBError, .contextLimit)
        }
    }

    func testDurableEvidenceStoresRuleHashesAndNecessaryFactsWithoutRuleOrSourceCopies() async throws {
        let fixture = try makeFixture(
            nestedDirectory: "Modules/Parser",
            fileName: "TokenCatalog.swift",
            query: "ParserReadyToken"
        )
        defer { fixture.cleanup() }
        let prepared = try await prepare(fixture: fixture)
        let sessionFile = prepared.store.rootURL
            .appendingPathComponent("Sessions")
            .appendingPathComponent(prepared.context.session.id.uuidString.lowercased())
            .appendingPathComponent("session.json")
        let durable = try String(contentsOf: sessionFile, encoding: .utf8)
        XCTAssertTrue(durable.contains("contentSHA256"))
        XCTAssertFalse(durable.contains("RootFixtureRuleContent"))
        XCTAssertFalse(durable.contains("NestedFixtureRuleContent"))
        XCTAssertFalse(durable.contains("let stageBValue"))
    }

    func testProviderFinishWithoutEvidenceCannotComplete() async throws {
        let fixture = try makeFixture(
            nestedDirectory: "Sources/Feature",
            fileName: "FeatureFlag.swift",
            query: "NestedFeatureReady"
        )
        defer { fixture.cleanup() }
        let prepared = try await prepare(fixture: fixture)
        let provider = StageBScriptedProvider(outcomes: Array(repeating:
            .decision(.finish(ProviderTurnMessage(role: .assistant, content: "done"))),
            count: smallLimits().maximumProviderTurns
        ))
        let executor = StageBMockExecutor(
            query: fixture.query,
            relativePath: fixture.relativeFilePath,
            topLevelEntry: "Sources"
        )
        let outcome = await makeAgent(prepared, provider: provider, executor: executor)
            .run(sessionID: prepared.context.session.id)
        XCTAssertEqual(outcome, .failure(.completionNotEstablished))
        let finishOnlyExecutions = await executor.executedNames()
        XCTAssertEqual(finishOnlyExecutions, [])
    }

    func testReadingSessionProjectionCannotChangeExecutionTruth() async throws {
        let fixture = try makeFixture(
            nestedDirectory: "Sources/Feature",
            fileName: "FeatureFlag.swift",
            query: "NestedFeatureReady"
        )
        defer { fixture.cleanup() }
        let prepared = try await prepare(fixture: fixture)
        let before = try await prepared.store.snapshot(sessionID: prepared.context.session.id)
        _ = try await prepared.store.records()
        let projected = try await prepared.store.snapshot(sessionID: prepared.context.session.id)
        let after = try await prepared.store.snapshot(sessionID: prepared.context.session.id)
        XCTAssertEqual(projected.session, before.session)
        XCTAssertEqual(projected.attempts, before.attempts)
        XCTAssertEqual(after.session, before.session)
        XCTAssertEqual(after.attempts, before.attempts)
    }

    private func prepare(fixture: StageBTestFixture) async throws -> StageBPreparedTest {
        let limits = smallLimits()
        let stageAStore = StageAWorkspaceStore(
            rootURL: fixture.root.deletingLastPathComponent().appendingPathComponent("StageAStore"),
            policy: stageATestPolicy()
        )
        let importer = StageAWorkspaceImporter(
            store: stageAStore,
            policy: stageATestPolicy(),
            coordinator: StageBPassThroughCoordinator()
        )
        let imported = await importer.importItem(at: fixture.root, expectedKind: .folder)
        guard imported.phase == .ready else { throw StageBError.workspaceNotReady }
        fixture.importRecordID = imported.id
        let store = StageBSessionStore(
            rootURL: fixture.root.deletingLastPathComponent().appendingPathComponent("StageBStore"),
            limits: limits
        )
        let goal = try StageBGoal(
            text: "Find \(fixture.query) in this imported project",
            exactQuery: fixture.query,
            expectedRelativePath: fixture.relativeFilePath,
            limits: limits
        )
        let coordinator = StageBSessionCoordinator(
            stageAStore: stageAStore,
            sessionStore: store,
            limits: limits
        )
        let context = try await coordinator.create(importID: imported.id, goal: goal)
        return StageBPreparedTest(
            context: context,
            store: store,
            coordinator: coordinator,
            limits: limits
        )
    }

    private func makeAgent(
        _ prepared: StageBPreparedTest,
        provider: StageBScriptedProvider,
        executor: StageBMockExecutor
    ) -> StageBReadOnlyAgent {
        StageBReadOnlyAgent(
            provider: provider,
            executor: executor,
            policy: StageBReadOnlyPolicy(
                workspace: prepared.context.workspace,
                ruleSet: prepared.context.ruleSet,
                limits: prepared.limits
            ),
            sessionStore: prepared.store,
            workspace: prepared.context.workspace,
            ruleSet: prepared.context.ruleSet,
            limits: prepared.limits
        )
    }

    private func makeFixture(
        nestedDirectory: String,
        fileName: String,
        query: String
    ) throws -> StageBTestFixture {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("WujiStageBTests-\(UUID().uuidString)", isDirectory: true)
        let root = container.appendingPathComponent("ImportedProject", isDirectory: true)
        let targetDirectory = root.appendingPathComponent(nestedDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        try Data("RootFixtureRuleContent\n".utf8).write(to: root.appendingPathComponent("AGENTS.md"))
        try Data("fixture readme\n".utf8).write(to: root.appendingPathComponent("README.md"))
        let firstScope = nestedDirectory.split(separator: "/").first.map(String.init)!
        let scopeDirectory = root.appendingPathComponent(firstScope, isDirectory: true)
        try FileManager.default.createDirectory(at: scopeDirectory, withIntermediateDirectories: true)
        try Data("NestedFixtureRuleContent\n".utf8).write(
            to: scopeDirectory.appendingPathComponent("AGENTS.md")
        )
        let relativeFilePath = nestedDirectory + "/" + fileName
        try Data("let stageBValue = \"\(query)\"\n".utf8).write(
            to: root.appendingPathComponent(relativeFilePath)
        )
        return StageBTestFixture(
            container: container,
            root: root,
            query: query,
            relativeFilePath: relativeFilePath,
            importRecordID: UUID()
        )
    }

    private func smallLimits() -> StageBLimits {
        StageBLimits(
            maximumProviderTurns: 4,
            maximumToolExecutions: 8,
            maximumToolCallsPerBatch: 4,
            maximumGoalBytes: 1_024,
            maximumPathBytes: 1_024,
            maximumQueryBytes: 256,
            maximumRuleFiles: 8,
            maximumRuleFileBytes: 8 * 1_024,
            maximumRuleAggregateBytes: 16 * 1_024,
            maximumContextBytes: 24 * 1_024,
            maximumListEntries: 16,
            maximumSearchMatches: 8,
            maximumReadBytes: 4 * 1_024,
            maximumLineBytes: 1_024,
            maximumExecutorStreamBytes: 8 * 1_024,
            maximumModelObservationBytes: 4 * 1_024,
            maximumDurableEvidenceBytes: 256 * 1_024,
            maximumDiagnosticBytes: 8 * 1_024
        )
    }

    private func stageATestPolicy() -> StageAImportPolicy {
        StageAImportPolicy(
            maximumEntryCount: 64,
            maximumFileBytes: 32 * 1_024,
            maximumTotalBytes: 256 * 1_024,
            maximumCompressionRatio: 20,
            maximumPathBytes: 1_024,
            maximumDirectoryDepth: 16,
            minimumRemainingCapacityBytes: 0,
            maximumDiagnosticBytes: 8 * 1_024
        )
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

private final class StageBTestFixture {
    let container: URL
    let root: URL
    let query: String
    let relativeFilePath: String
    var importRecordID: UUID

    init(
        container: URL,
        root: URL,
        query: String,
        relativeFilePath: String,
        importRecordID: UUID
    ) {
        self.container = container
        self.root = root
        self.query = query
        self.relativeFilePath = relativeFilePath
        self.importRecordID = importRecordID
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: container)
    }
}

private struct StageBPreparedTest {
    let context: StageBPreparedSession
    let store: StageBSessionStore
    let coordinator: StageBSessionCoordinator
    let limits: StageBLimits
}

private struct StageBPassThroughCoordinator: StageAExternalFileCoordinating, @unchecked Sendable {
    func coordinateRead<T>(at url: URL, _ body: (URL) throws -> T) throws -> T {
        try body(url)
    }
}

private actor StageBScriptedProvider: AgentInferenceProvider {
    nonisolated let providerID = "stage-b-test"
    private var outcomes: [ProviderInferenceOutcome]
    private var captured: [ProviderInferenceRequest] = []

    init(outcomes: [ProviderInferenceOutcome]) {
        self.outcomes = outcomes
    }

    func infer(request: ProviderInferenceRequest, requestID: UUID) async -> ProviderInferenceOutcome {
        captured.append(request)
        guard !outcomes.isEmpty else { return .failure(.emptyResponse) }
        return outcomes.removeFirst()
    }

    func callCount() -> Int { captured.count }
    func requests() -> [ProviderInferenceRequest] { captured }
}

private actor StageBMockExecutor: StageBReadOnlyExecuting {
    private let query: String
    private let relativePath: String
    private let topLevelEntry: String
    private let unknownOnFirstCall: Bool
    private var calls: [StageBToolName] = []

    init(
        query: String,
        relativePath: String,
        topLevelEntry: String,
        unknownOnFirstCall: Bool = false
    ) {
        self.query = query
        self.relativePath = relativePath
        self.topLevelEntry = topLevelEntry
        self.unknownOnFirstCall = unknownOnFirstCall
    }

    func execute(_ tool: StageBAuthorizedTool) async -> StageBExecutorOutcome {
        calls.append(tool.name)
        if unknownOnFirstCall, calls.count == 1 { return .unknown }
        let facts = StageBExecutorFacts(
            rootExitObserved: true,
            stdoutEOFObserved: true,
            stderrEOFObserved: true,
            finalStateKind: "exited",
            finalStateValue: 0,
            stdoutByteCount: 64,
            stderrByteCount: 0,
            stdoutSHA256: ProviderDigest.sha256Hex("stdout-\(calls.count)"),
            stderrSHA256: ProviderDigest.sha256Hex(Data()),
            truncated: false
        )
        let payload: StageBObservationPayload
        switch tool.name {
        case .list:
            payload = .list(entries: [topLevelEntry, "AGENTS.md", "README.md"])
        case .search:
            payload = .search(matches: [StageBSearchMatch(
                path: relativePath,
                line: 1,
                text: "let stageBValue = \"\(query)\""
            )])
        case .read:
            payload = .read(path: relativePath, content: "let stageBValue = \"\(query)\"\n")
        }
        return .observation(StageBToolObservation(
            tool: tool.name,
            relativePath: tool.relativePath,
            query: tool.query,
            ruleSetSHA256: tool.ruleSetSHA256,
            payload: payload,
            facts: facts
        ))
    }

    func executedNames() -> [StageBToolName] { calls }
}

private actor StageBIntentInspectingExecutor: StageBReadOnlyExecuting {
    private let store: StageBSessionStore
    private let sessionID: UUID
    private var sawIntent = false

    init(store: StageBSessionStore, sessionID: UUID) {
        self.store = store
        self.sessionID = sessionID
    }

    func execute(_ tool: StageBAuthorizedTool) async -> StageBExecutorOutcome {
        guard let snapshot = try? await store.snapshot(sessionID: sessionID) else {
            return .failure(.preparation)
        }
        sawIntent = snapshot.attempts.contains { intent in
            intent.kind == .executor
                && intent.toolName == tool.name
                && intent.phase == .intentRecorded
                && !snapshot.attempts.contains(where: { terminal in
                    terminal.attemptID == intent.attemptID
                        && terminal.phase != .intentRecorded
                })
        }
        return .unknown
    }

    func intentWasVisibleAtBoundary() -> Bool { sawIntent }
}
