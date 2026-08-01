import XCTest
@testable import Wuji

final class WujiS4ContractsTests: XCTestCase {
    func testReadBatchesAcceptFourCallsAndRejectEmptyBatch() throws {
        let fixture = try makeWorkspace()
        let policy = try S4ToolPolicy(workspace: fixture.workspace)

        XCTAssertThrowsError(try policy.authorizeBatch([], phase: .inspecting))
        for count in 1...4 {
            let calls = (0..<count).map {
                call(id: "read-\($0)", name: "list", arguments: #"{"path":""}"#)
            }
            let admitted = try policy.authorizeBatch(calls, phase: .inspecting)
            XCTAssertEqual(admitted.count, count)
            XCTAssertTrue(admitted.allSatisfy { $0.tool.name == .list })
        }
    }

    func testEditAndVerifyRequireExactSingleCallContracts() throws {
        let fixture = try makeWorkspace()
        let policy = try S4ToolPolicy(workspace: fixture.workspace)
        let edit = call(
            id: "edit-1",
            name: "edit",
            arguments: #"{"path":"records/draft.txt","expected_old":"STATUS=pending","replacement":"STATUS=verified"}"#
        )
        let verify = call(
            id: "verify-1",
            name: "verify",
            arguments: #"{"profile":"s4_status_verified"}"#
        )

        let admittedEdit = try policy.authorizeBatch([edit], phase: .inspected)
        XCTAssertEqual(admittedEdit.map(\.tool.name), [.edit])
        let admittedVerify = try policy.authorizeBatch([verify], phase: .edited)
        XCTAssertEqual(admittedVerify.map(\.tool.name), [.verify])

        for batch in [
            [edit, call(id: "read-2", name: "read", arguments: #"{"path":"records/draft.txt"}"#)],
            [verify, call(id: "read-3", name: "list", arguments: #"{"path":""}"#)],
            [edit, call(id: "edit-2", name: "edit", arguments: edit.arguments)]
        ] {
            XCTAssertThrowsError(try policy.authorizeBatch(batch, phase: .inspected)) { error in
                XCTAssertEqual((error as? S4BatchPolicyError)?.reason, .sideEffectIsolation)
            }
        }
    }

    func testPhaseScopedCatalogCannotBeExpandedByPromptOrModel() throws {
        XCTAssertEqual(
            S4ToolPolicy.toolDefinitions(for: .inspecting).map(\.name),
            ["list", "search", "read"]
        )
        XCTAssertEqual(S4ToolPolicy.toolDefinitions(for: .inspected).map(\.name), ["edit"])
        XCTAssertEqual(S4ToolPolicy.toolDefinitions(for: .edited).map(\.name), ["verify"])
        XCTAssertTrue(S4ToolPolicy.toolDefinitions(for: .verified).isEmpty)

        let fixture = try makeWorkspace()
        let policy = try S4ToolPolicy(workspace: fixture.workspace)
        let lateRead = call(id: "late-read", name: "read", arguments: #"{"path":"records/draft.txt"}"#)
        for phase in [S4PolicyPhase.inspected, .edited, .verified] {
            XCTAssertThrowsError(try policy.authorizeBatch([lateRead], phase: phase)) { error in
                XCTAssertEqual((error as? S4BatchPolicyError)?.reason, .stalePhase)
            }
        }
    }

    func testInvalidNameArgumentsPathProfileAndPhaseFailClosed() throws {
        let fixture = try makeWorkspace()
        let policy = try S4ToolPolicy(workspace: fixture.workspace)
        let cases: [(ProviderTurnToolCall, S4PolicyPhase, S4PolicyError)] = [
            (call(id: "x1", name: "shell", arguments: "{}"), .inspected, .unknownTool),
            (call(id: "x2", name: "edit", arguments: #"{"path":"../draft.txt","expected_old":"STATUS=pending","replacement":"STATUS=verified"}"#), .inspected, .invalidArguments),
            (call(id: "x3", name: "edit", arguments: #"{"path":"records/draft.txt","expected_old":"STATUS=other","replacement":"STATUS=verified"}"#), .inspected, .invalidArguments),
            (call(id: "x4", name: "edit", arguments: #"{"path":"records/draft.txt","expected_old":"STATUS=pending","replacement":"STATUS=verified","extra":"x"}"#), .inspected, .invalidArguments),
            (call(id: "x5", name: "edit", arguments: #"{"path":"records/draft.txt","expected_old":"STATUS=pending","replacement":"STATUS=verified"}"#), .inspecting, .stalePhase),
            (call(id: "x6", name: "verify", arguments: #"{"profile":"model-command"}"#), .edited, .verificationProfile),
            (call(id: "x7", name: "verify", arguments: #"{"profile":"s4_status_verified"}"#), .inspected, .stalePhase)
        ]
        for (toolCall, phase, reason) in cases {
            XCTAssertThrowsError(try policy.authorizeBatch([toolCall], phase: phase)) { error in
                XCTAssertEqual((error as? S4BatchPolicyError)?.reason, reason)
            }
        }
    }

    func testDuplicateReusedEmptyAndOversizedIDsFailBeforeAdmission() throws {
        let fixture = try makeWorkspace()
        let policy = try S4ToolPolicy(workspace: fixture.workspace)
        let list = #"{"path":""}"#
        let cases = [
            [call(id: "same", name: "list", arguments: list), call(id: "same", name: "list", arguments: list)],
            [call(id: "same", name: "shell", arguments: "{}"), call(id: "same", name: "shell", arguments: "{}")],
            [call(id: "", name: "list", arguments: list)],
            [call(id: String(repeating: "i", count: ProviderLimits.maximumToolCallIDBytes + 1), name: "list", arguments: list)]
        ]
        for batch in cases {
            XCTAssertThrowsError(try policy.authorizeBatch(batch, phase: .inspecting)) { error in
                XCTAssertEqual((error as? S4BatchPolicyError)?.reason, .toolCallID)
            }
        }
        XCTAssertThrowsError(try policy.authorizeBatch(
            [call(id: "used", name: "list", arguments: list)],
            phase: .inspecting,
            previouslyUsedIDs: ["used"]
        ))
    }

    func testWorkspaceRequiresExactSeedAndDetectsOnlyAuthorizedAfterState() throws {
        let fixture = try makeWorkspace()
        let before = try fixture.workspace.inspect()
        XCTAssertEqual(before.contentState, .before)
        XCTAssertTrue(before.exactFileSet)
        XCTAssertTrue(before.contextUnchanged)
        XCTAssertFalse(before.temporaryFilePresent)

        try Data(S4TaskContract.expectedAfterContent.utf8).write(
            to: fixture.root.appendingPathComponent(S4TaskContract.authorizedPath),
            options: .atomic
        )
        let after = try fixture.workspace.inspect()
        XCTAssertEqual(after.contentState, .after)
        XCTAssertTrue(after.exactFileSet)
        XCTAssertTrue(after.contextUnchanged)

        try Data("extra\n".utf8).write(to: fixture.root.appendingPathComponent("records/extra.txt"))
        XCTAssertThrowsError(try fixture.workspace.inspect())
    }

    func testWorkspaceRejectsSymlinkAtAuthorizedPath() throws {
        let fixture = try makeWorkspace()
        let draft = fixture.root.appendingPathComponent(S4TaskContract.authorizedPath)
        try FileManager.default.removeItem(at: draft)
        try FileManager.default.createSymbolicLink(
            at: draft,
            withDestinationURL: fixture.root.appendingPathComponent(S4TaskContract.contextPath)
        )
        XCTAssertThrowsError(try S4ApprovedWorkspace(
            taskID: fixture.taskID,
            rootURL: fixture.root,
            requireInitialSeed: false
        ))
    }

    func testApprovalBindingRejectsWrongTaskWorkspacePathHashProfileAndExpiry() throws {
        let fixture = try makeWorkspace()
        let now = Date(timeIntervalSince1970: 1_000)
        let request = makeApproval(workspace: fixture.workspace, now: now)
        XCTAssertTrue(request.valid(for: fixture.workspace, now: now))
        XCTAssertEqual(request.bindingSHA256.count, 64)

        let wrongTask = copy(request, taskID: UUID())
        let wrongWorkspace = copy(request, workspaceID: String(repeating: "a", count: 64))
        let wrongSnapshot = copy(request, workspaceSnapshotSHA256: String(repeating: "c", count: 64))
        let wrongID = copy(request, toolCallID: "")
        let wrongPath = copy(request, relativePath: "records/context.txt")
        let wrongHash = copy(request, beforeSHA256: String(repeating: "b", count: 64))
        let expired = copy(request, expiresAt: now.addingTimeInterval(-1))
        for invalid in [wrongTask, wrongWorkspace, wrongSnapshot, wrongID, wrongPath, wrongHash, expired] {
            XCTAssertFalse(invalid.valid(for: fixture.workspace, now: now))
        }
        let encoded = try JSONEncoder().encode(request)
        let raw = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        let wrongProfileJSON = raw.replacingOccurrences(
            of: S4VerificationProfile.s4StatusVerified.rawValue,
            with: "model_command"
        )
        XCTAssertThrowsError(try JSONDecoder().decode(
            S4ApprovalRequest.self,
            from: Data(wrongProfileJSON.utf8)
        ))
    }

    func testValidationApprovalRequiresExplicitProbeModeAndExactPackage() async throws {
        let fixture = try makeWorkspace()
        let now = Date(timeIntervalSince1970: 2_000)
        let request = makeApproval(workspace: fixture.workspace, now: now)
        let allowed = S4ValidationApprovalAuthorizer(
            probeMode: true,
            taskPackageID: S4TaskContract.packageID,
            workspace: fixture.workspace,
            now: { now }
        )
        guard case let .approved(grant) = await allowed.requestApproval(request) else {
            return XCTFail("exact validation grant was not issued")
        }
        XCTAssertEqual(grant.requestID, request.requestID)
        XCTAssertEqual(grant.requestBindingSHA256, request.bindingSHA256)
        XCTAssertEqual(grant.nonce, request.nonce)

        let disabled = S4ValidationApprovalAuthorizer(
            probeMode: false,
            taskPackageID: S4TaskContract.packageID,
            workspace: fixture.workspace,
            now: { now }
        )
        let wrongPackage = S4ValidationApprovalAuthorizer(
            probeMode: true,
            taskPackageID: "wrong",
            workspace: fixture.workspace,
            now: { now }
        )
        let disabledDecision = await disabled.requestApproval(request)
        let wrongPackageDecision = await wrongPackage.requestApproval(request)
        XCTAssertEqual(disabledDecision, .rejected(.unavailable))
        XCTAssertEqual(wrongPackageDecision, .rejected(.unavailable))
    }

    func testWorkspaceWriterGateRejectsReentryUntilExactTokenReleases() async throws {
        let gate = S4WorkspaceWriterGate()
        let workspaceID = String(repeating: "a", count: 64)
        let acquired = await gate.acquire(workspaceID: workspaceID)
        let first = try XCTUnwrap(acquired)
        let reentry = await gate.acquire(workspaceID: workspaceID)
        XCTAssertNil(reentry)
        await gate.release(workspaceID: workspaceID, token: UUID())
        let afterWrongRelease = await gate.acquire(workspaceID: workspaceID)
        XCTAssertNil(afterWrongRelease)
        await gate.release(workspaceID: workspaceID, token: first)
        let afterRelease = await gate.acquire(workspaceID: workspaceID)
        XCTAssertNotNil(afterRelease)
    }

    func testNormalBrokerDoesNotAutoApproveAndSupportsExplicitApproveAndReject() async throws {
        let fixture = try makeWorkspace()
        let now = Date(timeIntervalSince1970: 3_000)
        let request = makeApproval(workspace: fixture.workspace, now: now)
        let broker = S4ApprovalBroker()

        let decisionTask = Task { await broker.requestApproval(request) }
        for _ in 0..<20 {
            if (await broker.snapshot()).state == .pendingApproval { break }
            await Task.yield()
        }
        let pending = await broker.snapshot()
        XCTAssertEqual(pending.state, .pendingApproval)
        XCTAssertEqual(pending.request?.requestID, request.requestID)
        await broker.approve(requestID: request.requestID, nonce: request.nonce, at: now)
        guard case let .approved(grant) = await decisionTask.value else {
            return XCTFail("explicit approve did not produce a grant")
        }
        XCTAssertEqual(grant.requestBindingSHA256, request.bindingSHA256)

        let second = copy(request, requestID: UUID(), nonce: UUID())
        let rejectTask = Task { await broker.requestApproval(second) }
        for _ in 0..<20 {
            if (await broker.snapshot()).state == .pendingApproval { break }
            await Task.yield()
        }
        await broker.reject(requestID: second.requestID, nonce: second.nonce)
        let rejection = await rejectTask.value
        XCTAssertEqual(rejection, .rejected(.rejected))
    }

    func testDurableApprovalContainsOnlyBoundedBindingEvidence() async throws {
        let fixture = try makeWorkspace()
        let now = Date(timeIntervalSince1970: 4_000)
        let request = makeApproval(workspace: fixture.workspace, now: now)
        let directory = fixture.temp.appendingPathComponent("evidence", isDirectory: true)
        let store = try FileS4DurableStore(directoryURL: directory)
        try await store.recordApproval(S4ApprovalEvidence(
            request: request,
            phase: .pending,
            recordedAt: now,
            grant: nil,
            rejection: nil
        ))
        let snapshot = try await store.snapshot(taskID: fixture.taskID)
        XCTAssertEqual(snapshot.approvals.count, 1)
        let raw = try String(contentsOf: directory.appendingPathComponent("s4-approvals.jsonl"), encoding: .utf8)
        XCTAssertFalse(raw.contains(S4TaskContract.expectedBeforeContent))
        XCTAssertFalse(raw.contains(S4TaskContract.expectedAfterContent))
        XCTAssertFalse(raw.contains("DEEPSEEK_API_KEY"))
        XCTAssertLessThanOrEqual(raw.utf8.count, S4Limits.maximumDurableFileBytes)
    }

    private struct Fixture {
        let temp: URL
        let root: URL
        let taskID: UUID
        let workspace: S4ApprovedWorkspace
    }

    private func makeWorkspace() throws -> Fixture {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = temp.appendingPathComponent("workspace", isDirectory: true)
        let records = root.appendingPathComponent("records", isDirectory: true)
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        try Data(S4TaskContract.expectedBeforeContent.utf8).write(
            to: root.appendingPathComponent(S4TaskContract.authorizedPath)
        )
        try Data(S4TaskContract.expectedContextContent.utf8).write(
            to: root.appendingPathComponent(S4TaskContract.contextPath)
        )
        let taskID = UUID()
        let workspace = try S4ApprovedWorkspace(
            taskID: taskID,
            rootURL: root,
            requireInitialSeed: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: temp) }
        return Fixture(temp: temp, root: root, taskID: taskID, workspace: workspace)
    }

    private func call(id: String, name: String, arguments: String) -> ProviderTurnToolCall {
        ProviderTurnToolCall(id: id, name: name, arguments: arguments)
    }

    private func makeApproval(workspace: S4ApprovedWorkspace, now: Date) -> S4ApprovalRequest {
        S4ApprovalRequest(
            requestID: UUID(),
            taskID: workspace.taskID,
            workspaceID: workspace.workspaceID,
            workspaceSnapshotSHA256: workspace.seedSnapshotSHA256,
            toolCallID: "edit-call",
            relativePath: S4TaskContract.authorizedPath,
            beforeSHA256: S4TaskContract.beforeHash,
            afterSHA256: S4TaskContract.afterHash,
            changeSummarySHA256: S4TaskContract.changeSummaryHash,
            verificationProfile: S4TaskContract.verificationProfile,
            nonce: UUID(),
            createdAt: now,
            expiresAt: now.addingTimeInterval(60)
        )
    }

    private func copy(
        _ request: S4ApprovalRequest,
        requestID: UUID? = nil,
        taskID: UUID? = nil,
        workspaceID: String? = nil,
        workspaceSnapshotSHA256: String? = nil,
        toolCallID: String? = nil,
        relativePath: String? = nil,
        beforeSHA256: String? = nil,
        nonce: UUID? = nil,
        expiresAt: Date? = nil
    ) -> S4ApprovalRequest {
        S4ApprovalRequest(
            requestID: requestID ?? request.requestID,
            taskID: taskID ?? request.taskID,
            workspaceID: workspaceID ?? request.workspaceID,
            workspaceSnapshotSHA256: workspaceSnapshotSHA256 ?? request.workspaceSnapshotSHA256,
            toolCallID: toolCallID ?? request.toolCallID,
            relativePath: relativePath ?? request.relativePath,
            beforeSHA256: beforeSHA256 ?? request.beforeSHA256,
            afterSHA256: request.afterSHA256,
            changeSummarySHA256: request.changeSummarySHA256,
            verificationProfile: request.verificationProfile,
            nonce: nonce ?? request.nonce,
            createdAt: request.createdAt,
            expiresAt: expiresAt ?? request.expiresAt
        )
    }
}
