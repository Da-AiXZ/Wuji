import Foundation

private struct StageCProbeSummary: Codable {
    let resultCategory: String
    let importID: String
    let sessionID: String
    let taskID: String
    let workspaceIdentitySHA256: String
    let goalBindingSHA256: String
    let ruleSetBindingSHA256: String
    let ruleSources: [String]
    let relativePath: String
    let beforeSHA256: String
    let afterSHA256: String
    let proposalSHA256: String
    let diffSHA256: String
    let finalTreeSHA256: String
    let approvalState: String
    let externalAttemptCountBeforeColdRestore: Int
    let externalAttemptCountAfterColdRestore: Int
    let coldRestoreCategory: String

    enum CodingKeys: String, CodingKey {
        case resultCategory = "result_category"
        case importID = "import_id"
        case sessionID = "session_id"
        case taskID = "task_id"
        case workspaceIdentitySHA256 = "workspace_identity_sha256"
        case goalBindingSHA256 = "goal_binding_sha256"
        case ruleSetBindingSHA256 = "rule_set_binding_sha256"
        case ruleSources = "rule_sources"
        case relativePath = "relative_path"
        case beforeSHA256 = "before_sha256"
        case afterSHA256 = "after_sha256"
        case proposalSHA256 = "proposal_sha256"
        case diffSHA256 = "diff_sha256"
        case finalTreeSHA256 = "final_tree_sha256"
        case approvalState = "approval_state"
        case externalAttemptCountBeforeColdRestore = "external_attempt_count_before_cold_restore"
        case externalAttemptCountAfterColdRestore = "external_attempt_count_after_cold_restore"
        case coldRestoreCategory = "cold_restore_category"
    }
}

enum StageCProbeContract {
    static let goalText = "Inspect the exact release_channel = preview setting, then propose replacing that one line with release_channel = stable through the approved bounded edit."
    static let query = "release_channel = preview"
    static let expectedPath = "Sources/Configuration/AppProfile.txt"
    static let expectedOld = "release_channel = preview"
    static let replacement = "release_channel = stable"
}

enum StageCProbeRunner {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["WUJI_STAGE_C_PROBE_MODE"] == "1"
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
            guard let fixtureURL = Bundle.main.url(
                forResource: "StageCRealImportedProject",
                withExtension: nil
            ) else { throw StageCError.invalidBinding }
            let stageAStore = try StageAWorkspaceStore.applicationStore()
            let importer = StageAWorkspaceImporter(store: stageAStore)
            let imported = await importer.importItem(at: fixtureURL, expectedKind: .folder)
            guard imported.phase == .ready,
                  (try await importer.recover()).filter({
                    $0.id == imported.id && $0.phase == .ready
                  }).count == 1 else { throw StageCError.invalidBinding }

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
                    text: StageCProbeContract.goalText,
                    exactQuery: StageCProbeContract.query,
                    expectedRelativePath: StageCProbeContract.expectedPath,
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
            ), stageBCompletion.relativePath == StageCProbeContract.expectedPath else {
                throw StageCError.invalidBinding
            }
            let restoredSession = try await sessionStore.snapshot(sessionID: prepared.session.id)
            let completedSession = restoredSession.session
            let targetURL = prepared.workspace.canonicalRootURL
                .appendingPathComponent(StageCProbeContract.expectedPath)
            let beforeData = try Data(contentsOf: targetURL, options: .mappedIfSafe)
            let beforeHash = ProviderDigest.sha256Hex(beforeData)

            let stageCLimits = StageCLimits.production
            let taskStore = try StageCTaskStore.applicationStore(limits: stageCLimits)
            let task = try await taskStore.create(
                session: completedSession,
                workspace: prepared.workspace,
                ruleSet: prepared.ruleSet,
                targetRelativePath: StageCProbeContract.expectedPath
            )
            let stageCProvider = try configuration.makeProvider(
                transport: URLSessionProviderTransport(),
                attemptStore: FileProviderAttemptStore(directoryURL: taskStore.rootURL
                    .appendingPathComponent("Provider", isDirectory: true)
                    .appendingPathComponent(task.id.uuidString.lowercased(), isDirectory: true))
            )
            let stageCAgent = StageCEditingAgent(
                provider: stageCProvider,
                readExecutor: stageBExecutor,
                editExecutor: try ISHStageCEditExecutor.bundled(
                    workspace: prepared.workspace,
                    limits: stageCLimits
                ),
                approvalAuthorizer: StageCValidationApprovalAuthorizer(
                    enabled: true,
                    expectedTarget: StageCProbeContract.expectedPath,
                    now: { Date() }
                ),
                taskStore: taskStore,
                task: task,
                session: completedSession,
                workspace: prepared.workspace,
                ruleSet: prepared.ruleSet,
                limits: stageCLimits,
                readLimits: stageBLimits
            )
            guard case let .completed(completion) = await stageCAgent.run() else {
                throw StageCError.completionRejected
            }
            let completedTask = try await taskStore.snapshot(taskID: task.id)
            guard let proposal = completedTask.proposal,
                  proposal.relativePath == StageCProbeContract.expectedPath,
                  proposal.expectedOld == StageCProbeContract.expectedOld,
                  proposal.replacement == StageCProbeContract.replacement,
                  completedTask.approvals.contains(where: { $0.state == .consumed }) else {
                throw StageCError.verificationFailed
            }
            let afterHash = ProviderDigest.sha256Hex(
                try Data(contentsOf: targetURL, options: .mappedIfSafe)
            )
            guard beforeHash == proposal.beforeSHA256,
                  afterHash == proposal.afterSHA256 else {
                throw StageCError.verificationFailed
            }
            let beforeCount = externalIntentCount(completedTask)
            let coldStore = try StageCTaskStore.applicationStore(limits: stageCLimits)
            let coldTask = try await coldStore.snapshot(taskID: task.id)
            let coldAgent = StageCEditingAgent(
                provider: stageCProvider,
                readExecutor: stageBExecutor,
                editExecutor: try ISHStageCEditExecutor.bundled(
                    workspace: prepared.workspace,
                    limits: stageCLimits
                ),
                approvalAuthorizer: StageCValidationApprovalAuthorizer(
                    enabled: true,
                    expectedTarget: StageCProbeContract.expectedPath,
                    now: { Date() }
                ),
                taskStore: coldStore,
                task: coldTask,
                session: completedSession,
                workspace: prepared.workspace,
                ruleSet: prepared.ruleSet,
                limits: stageCLimits,
                readLimits: stageBLimits
            )
            guard case let .completed(coldCompletion) = await coldAgent.run(),
                  coldCompletion == completion else { throw StageCError.reconciliationRequired }
            let coldSnapshot = try await coldStore.snapshot(taskID: task.id)
            let afterCount = externalIntentCount(coldSnapshot)
            guard beforeCount == afterCount else { throw StageCError.reconciliationRequired }
            write(.init(
                resultCategory: "completed",
                importID: imported.id.uuidString.lowercased(),
                sessionID: completedSession.id.uuidString.lowercased(),
                taskID: task.id.uuidString.lowercased(),
                workspaceIdentitySHA256: task.workspaceIdentitySHA256,
                goalBindingSHA256: task.goalBindingSHA256,
                ruleSetBindingSHA256: task.ruleSetBindingSHA256,
                ruleSources: prepared.ruleSet.descriptors.map(\.relativePath),
                relativePath: proposal.relativePath,
                beforeSHA256: proposal.beforeSHA256,
                afterSHA256: proposal.afterSHA256,
                proposalSHA256: proposal.proposalSHA256,
                diffSHA256: proposal.diffSHA256,
                finalTreeSHA256: completion.finalTreeSHA256,
                approvalState: "consumed",
                externalAttemptCountBeforeColdRestore: beforeCount,
                externalAttemptCountAfterColdRestore: afterCount,
                coldRestoreCategory: "durable_completed"
            ), environment: environment)
        } catch {
            writeFailure("probe_failed", environment: environment)
        }
    }

    private static func externalIntentCount(_ task: StageCTaskRecord) -> Int {
        task.attempts.filter { $0.phase == .intentRecorded }.count
    }

    private static func write(_ summary: StageCProbeSummary, environment: [String: String]) {
        guard let path = environment["WUJI_STAGE_C_SUMMARY_FILE"] else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(summary) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: [.atomic])
    }

    private static func writeFailure(_ category: String, environment: [String: String]) {
        let zero = String(repeating: "0", count: 64)
        write(.init(
            resultCategory: category,
            importID: "", sessionID: "", taskID: "",
            workspaceIdentitySHA256: zero,
            goalBindingSHA256: zero,
            ruleSetBindingSHA256: zero,
            ruleSources: [],
            relativePath: "",
            beforeSHA256: zero,
            afterSHA256: zero,
            proposalSHA256: zero,
            diffSHA256: zero,
            finalTreeSHA256: zero,
            approvalState: "rejected",
            externalAttemptCountBeforeColdRestore: 0,
            externalAttemptCountAfterColdRestore: 0,
            coldRestoreCategory: "failed"
        ), environment: environment)
    }
}
