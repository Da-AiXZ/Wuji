import Foundation

private struct StageDProbeSummary: Codable {
    let resultCategory: String
    let candidate: String
    let runID: String
    let importID: String
    let sessionID: String
    let taskID: String
    let workspaceIdentitySHA256: String
    let command: String
    let commandBindingSHA256: String
    let risk: String
    let approvalState: String
    let rootExitObserved: Bool
    let stdoutEOFObserved: Bool
    let stderrEOFObserved: Bool
    let truncated: Bool
    let processTreeState: String
    let verificationSHA256: String
    let finalFileSHA256: String
    let externalAttemptsBeforeColdRestore: Int
    let externalAttemptsAfterColdRestore: Int
    let coldRestoreCategory: String

    enum CodingKeys: String, CodingKey {
        case resultCategory = "result_category"
        case candidate
        case runID = "run_id"
        case importID = "import_id"
        case sessionID = "session_id"
        case taskID = "task_id"
        case workspaceIdentitySHA256 = "workspace_identity_sha256"
        case command
        case commandBindingSHA256 = "command_binding_sha256"
        case risk
        case approvalState = "approval_state"
        case rootExitObserved = "root_exit_observed"
        case stdoutEOFObserved = "stdout_eof_observed"
        case stderrEOFObserved = "stderr_eof_observed"
        case truncated
        case processTreeState = "process_tree_state"
        case verificationSHA256 = "verification_sha256"
        case finalFileSHA256 = "final_file_sha256"
        case externalAttemptsBeforeColdRestore = "external_attempts_before_cold_restore"
        case externalAttemptsAfterColdRestore = "external_attempts_after_cold_restore"
        case coldRestoreCategory = "cold_restore_category"
    }
}

enum StageDProbeContract {
    static let goal = "Find channel=preview in Sources/Environment.txt so a later approved Stage D command can change exactly that setting."
    static let query = "channel=preview"
    static let path = "Sources/Environment.txt"
    static let beforeLine = "channel=preview"
    static let afterLine = "channel=stable"
}

enum StageDProbeRunner {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["WUJI_STAGE_D_PROBE_MODE"] == "1"
    }

    static func startIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard isRequested else { return }
        Task.detached(priority: .userInitiated) { await run(environment: environment) }
    }

    private static func run(environment: [String: String]) async {
        guard let baseURL = environment["DEEPSEEK_BASE_URL"],
              let model = environment["DEEPSEEK_MODEL"],
              let apiKey = environment["DEEPSEEK_API_KEY"],
              !baseURL.isEmpty, !model.isEmpty, !apiKey.isEmpty,
              !CommandLine.arguments.contains(where: { $0.contains(apiKey) }) else {
            writeFailure("configuration_rejected", environment: environment)
            return
        }
        do {
            guard let fixture = Bundle.main.url(forResource: "StageDRealImportedProject", withExtension: nil) else {
                throw StageDCommandError.verificationFailure
            }
            let stageAStore = try StageAWorkspaceStore.applicationStore()
            let importer = StageAWorkspaceImporter(store: stageAStore)
            let imported = await importer.importItem(at: fixture, expectedKind: .folder)
            guard imported.phase == .ready else { throw StageDCommandError.verificationFailure }

            let stageBLimits = StageBLimits.production
            let sessionStore = try StageBSessionStore.applicationStore(limits: stageBLimits)
            let coordinator = StageBSessionCoordinator(
                stageAStore: stageAStore,
                sessionStore: sessionStore,
                limits: stageBLimits
            )
            let prepared = try await coordinator.create(
                importID: imported.id,
                goal: StageBGoal(
                    text: StageDProbeContract.goal,
                    exactQuery: StageDProbeContract.query,
                    expectedRelativePath: StageDProbeContract.path,
                    limits: stageBLimits
                )
            )
            let configuration = DeepSeekSecureConfigurationStore()
            try configuration.save(baseURL: baseURL, model: model, apiKey: apiKey)
            let stageBProvider = try configuration.makeProvider(
                transport: URLSessionProviderTransport(),
                attemptStore: FileProviderAttemptStore(directoryURL: sessionStore.rootURL
                    .appendingPathComponent("Sessions", isDirectory: true)
                    .appendingPathComponent(prepared.session.id.uuidString.lowercased(), isDirectory: true))
            )
            let stageBExecutor = try ISHStageBReadOnlyExecutor.bundled(
                workspace: prepared.workspace,
                limits: stageBLimits
            )
            let stageBAgent = StageBReadOnlyAgent(
                provider: stageBProvider,
                executor: stageBExecutor,
                policy: StageBReadOnlyPolicy(
                    workspace: prepared.workspace,
                    ruleSet: prepared.ruleSet,
                    limits: stageBLimits
                ),
                sessionStore: sessionStore,
                workspace: prepared.workspace,
                ruleSet: prepared.ruleSet,
                limits: stageBLimits
            )
            guard case let .completed(stageBCompletion) = await stageBAgent.run(
                sessionID: prepared.session.id
            ), stageBCompletion.relativePath == StageDProbeContract.path else {
                throw StageDCommandError.verificationFailure
            }
            let completedSnapshot = try await sessionStore.snapshot(sessionID: prepared.session.id)
            let completedSession = completedSnapshot.session
            let target = prepared.workspace.canonicalRootURL
                .appendingPathComponent(StageDProbeContract.path)
            let before = try Data(contentsOf: target, options: .mappedIfSafe)
            guard var content = String(data: before, encoding: .utf8),
                  content.components(separatedBy: "\n").filter({ $0 == StageDProbeContract.beforeLine }).count == 1 else {
                throw StageDCommandError.verificationFailure
            }
            content = content.replacingOccurrences(
                of: StageDProbeContract.beforeLine,
                with: StageDProbeContract.afterLine
            )
            let after = Data(content.utf8)
            let writeSpec = StageDBoundedWrite(
                relativePath: StageDProbeContract.path,
                expectedBeforeLine: StageDProbeContract.beforeLine,
                replacementLine: StageDProbeContract.afterLine,
                expectedBeforeSHA256: ProviderDigest.sha256Hex(before),
                expectedAfterSHA256: ProviderDigest.sha256Hex(after)
            )

            let limits = StageDLimits.production
            let store = try StageDTaskStore.applicationStore(limits: limits)
            let task = try await store.create(
                session: completedSession,
                workspace: prepared.workspace,
                ruleSet: prepared.ruleSet,
                write: writeSpec,
                expectation: .init(
                    kind: .exactFile,
                    relativePath: writeSpec.relativePath,
                    expectedSHA256: writeSpec.expectedAfterSHA256,
                    cloneTarget: nil,
                    cloneRemote: nil,
                    cloneHEAD: nil
                )
            )
            let provider = try configuration.makeProvider(
                transport: URLSessionProviderTransport(),
                attemptStore: FileProviderAttemptStore(directoryURL: store.rootURL
                    .appendingPathComponent("Provider", isDirectory: true)
                    .appendingPathComponent(task.id.uuidString.lowercased(), isDirectory: true))
            )
            let executor = try ISHStageDCommandExecutor.bundled(
                workspace: prepared.workspace,
                cloneRootURL: store.cloneRootURL,
                limits: limits
            )
            let agent = StageDCommandAgent(
                provider: provider,
                executor: executor,
                approvalAuthorizer: StageDValidationApprovalAuthorizer(
                    enabledRisks: [.workspaceWrite],
                    now: Date.init
                ),
                store: store,
                task: task,
                policy: StageDCommandPolicy(
                    workspaceIdentitySHA256: prepared.workspace.identitySHA256,
                    write: writeSpec,
                    limits: limits
                ),
                limits: limits,
                requireProvider: true
            )
            guard case .completed = await agent.runModelCommand() else {
                throw StageDCommandError.completionRejected
            }
            let snapshot = try await store.snapshot(taskID: task.id)
            guard let terminal = snapshot.attempts.last(where: {
                $0.kind == .command && $0.phase == .succeeded
            }),
            let command = terminal.command,
            let result = terminal.result,
            let facts = result.facts.last,
            snapshot.approvals.contains(where: { $0.state == .consumed }),
            ProviderDigest.sha256Hex(try Data(contentsOf: target, options: .mappedIfSafe))
                == writeSpec.expectedAfterSHA256 else {
                throw StageDCommandError.verificationFailure
            }
            let beforeCount = snapshot.attempts.filter { $0.phase == .intentRecorded }.count
            let coldStore = try StageDTaskStore.applicationStore(limits: limits)
            let coldTask = try await coldStore.snapshot(taskID: task.id)
            let coldAgent = StageDCommandAgent(
                provider: provider,
                executor: executor,
                approvalAuthorizer: StageDValidationApprovalAuthorizer(
                    enabledRisks: [.workspaceWrite],
                    now: Date.init
                ),
                store: coldStore,
                task: coldTask,
                policy: StageDCommandPolicy(
                    workspaceIdentitySHA256: prepared.workspace.identitySHA256,
                    write: writeSpec,
                    limits: limits
                ),
                limits: limits,
                requireProvider: true
            )
            guard case .completed = await coldAgent.runModelCommand() else {
                throw StageDCommandError.reconciliationRequired
            }
            let coldSnapshot = try await coldStore.snapshot(taskID: task.id)
            let afterCount = coldSnapshot.attempts.filter { $0.phase == .intentRecorded }.count
            guard beforeCount == afterCount else { throw StageDCommandError.reconciliationRequired }
            write(.init(
                resultCategory: "completed",
                candidate: environment["WUJI_STAGE_D_CANDIDATE"] ?? "",
                runID: environment["WUJI_STAGE_D_RUN_ID"] ?? "",
                importID: imported.id.uuidString.lowercased(),
                sessionID: completedSession.id.uuidString.lowercased(),
                taskID: task.id.uuidString.lowercased(),
                workspaceIdentitySHA256: task.workspaceIdentitySHA256,
                command: command.parsed.original,
                commandBindingSHA256: command.bindingSHA256,
                risk: command.risk.rawValue,
                approvalState: "consumed",
                rootExitObserved: facts.rootExitObserved,
                stdoutEOFObserved: facts.stdoutEOFObserved,
                stderrEOFObserved: facts.stderrEOFObserved,
                truncated: facts.truncated,
                processTreeState: facts.processTreeState.rawValue,
                verificationSHA256: result.verificationSHA256,
                finalFileSHA256: writeSpec.expectedAfterSHA256,
                externalAttemptsBeforeColdRestore: beforeCount,
                externalAttemptsAfterColdRestore: afterCount,
                coldRestoreCategory: "durable_completed"
            ), environment: environment)
        } catch {
            writeFailure("probe_failed", environment: environment)
        }
    }

    private static func write(_ summary: StageDProbeSummary, environment: [String: String]) {
        guard let path = environment["WUJI_STAGE_D_SUMMARY_FILE"] else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(summary) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: [.atomic])
    }

    private static func writeFailure(_ category: String, environment: [String: String]) {
        write(.init(
            resultCategory: category,
            candidate: environment["WUJI_STAGE_D_CANDIDATE"] ?? "",
            runID: environment["WUJI_STAGE_D_RUN_ID"] ?? "",
            importID: "", sessionID: "", taskID: "",
            workspaceIdentitySHA256: String(repeating: "0", count: 64),
            command: "", commandBindingSHA256: String(repeating: "0", count: 64),
            risk: "", approvalState: "rejected",
            rootExitObserved: false, stdoutEOFObserved: false, stderrEOFObserved: false,
            truncated: false, processTreeState: "not_observed",
            verificationSHA256: String(repeating: "0", count: 64),
            finalFileSHA256: String(repeating: "0", count: 64),
            externalAttemptsBeforeColdRestore: 0,
            externalAttemptsAfterColdRestore: 0,
            coldRestoreCategory: "failed"
        ), environment: environment)
    }
}
