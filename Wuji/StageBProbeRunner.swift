import Foundation

private struct StageBProbeSummary: Codable {
    let resultCategory: String
    let sessionID: String
    let importID: String
    let workspaceIdentitySHA256: String
    let goalBindingSHA256: String
    let ruleSetBindingSHA256: String
    let ruleSources: [String]
    let relativePath: String
    let providerRequestCount: Int
    let toolExecutionCount: Int
    let toolSequence: [String]
    let evidenceChainSHA256: String
    let externalAttemptCountBeforeColdRestore: Int
    let externalAttemptCountAfterColdRestore: Int
    let coldRestoreCategory: String

    enum CodingKeys: String, CodingKey {
        case resultCategory = "result_category"
        case sessionID = "session_id"
        case importID = "import_id"
        case workspaceIdentitySHA256 = "workspace_identity_sha256"
        case goalBindingSHA256 = "goal_binding_sha256"
        case ruleSetBindingSHA256 = "rule_set_binding_sha256"
        case ruleSources = "rule_sources"
        case relativePath = "relative_path"
        case providerRequestCount = "provider_request_count"
        case toolExecutionCount = "tool_execution_count"
        case toolSequence = "tool_sequence"
        case evidenceChainSHA256 = "evidence_chain_sha256"
        case externalAttemptCountBeforeColdRestore = "external_attempt_count_before_cold_restore"
        case externalAttemptCountAfterColdRestore = "external_attempt_count_after_cold_restore"
        case coldRestoreCategory = "cold_restore_category"
    }
}

enum StageBProbeContract {
    static let goalText = "Find the declaration whose value is WujiStageBReadySignal and report its normalized relative path."
    static let query = "WujiStageBReadySignal"
    static let expectedPath = "Sources/Telemetry/StatusCatalog.swift"
}

enum StageBProbeRunner {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["WUJI_STAGE_B_PROBE_MODE"] == "1"
    }

    static func startIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard isRequested else { return }
        Task.detached(priority: .userInitiated) {
            await run(environment: environment)
        }
    }

    private static func run(environment: [String: String]) async {
        guard let baseURL = environment["DEEPSEEK_BASE_URL"],
              let model = environment["DEEPSEEK_MODEL"],
              let apiKey = environment["DEEPSEEK_API_KEY"],
              !baseURL.isEmpty,
              !model.isEmpty,
              !apiKey.isEmpty,
              !CommandLine.arguments.contains(where: { $0.contains(apiKey) }) else {
            writeFailure("configuration_rejected")
            return
        }

        do {
            let limits = StageBLimits.production
            guard let fixtureURL = Bundle.main.url(
                forResource: "StageBRealImportedProject",
                withExtension: nil
            ) else { throw StageBError.workspaceUnavailable }

            let stageAStore = try StageAWorkspaceStore.applicationStore()
            let importer = StageAWorkspaceImporter(store: stageAStore)
            let imported = await importer.importItem(at: fixtureURL, expectedKind: .folder)
            guard imported.phase == .ready,
                  (try await importer.recover()).filter({
                      $0.id == imported.id && $0.phase == .ready
                  }).count == 1 else {
                throw StageBError.workspaceNotReady
            }

            let sessionStore = try StageBSessionStore.applicationStore(limits: limits)
            let goal = try StageBGoal(
                text: StageBProbeContract.goalText,
                exactQuery: StageBProbeContract.query,
                expectedRelativePath: StageBProbeContract.expectedPath,
                limits: limits
            )
            let coordinator = StageBSessionCoordinator(
                stageAStore: stageAStore,
                sessionStore: sessionStore,
                limits: limits
            )
            let prepared = try await coordinator.create(importID: imported.id, goal: goal)

            let configurationStore = DeepSeekSecureConfigurationStore()
            try configurationStore.save(baseURL: baseURL, model: model, apiKey: apiKey)
            let evidenceDirectory = sessionStore.rootURL
                .appendingPathComponent("Sessions", isDirectory: true)
                .appendingPathComponent(prepared.session.id.uuidString.lowercased(), isDirectory: true)
            let providerStore = try FileProviderAttemptStore(directoryURL: evidenceDirectory)
            let provider = try configurationStore.makeProvider(
                transport: URLSessionProviderTransport(),
                attemptStore: providerStore
            )
            let executor = try ISHStageBReadOnlyExecutor.bundled(
                workspace: prepared.workspace,
                limits: limits
            )
            let agent = StageBReadOnlyAgent(
                provider: provider,
                executor: executor,
                policy: StageBReadOnlyPolicy(
                    workspace: prepared.workspace,
                    ruleSet: prepared.ruleSet,
                    limits: limits
                ),
                sessionStore: sessionStore,
                workspace: prepared.workspace,
                ruleSet: prepared.ruleSet,
                limits: limits
            )
            guard case let .completed(completion) = await agent.run(sessionID: prepared.session.id),
                  completion.relativePath == StageBProbeContract.expectedPath else {
                writeFailure("real_loop_failed")
                return
            }

            let before = try await sessionStore.snapshot(sessionID: prepared.session.id)
            let beforeCount = externalAttemptCount(before.attempts)
            let coldStore = try StageBSessionStore.applicationStore(limits: limits)
            let coldCoordinator = StageBSessionCoordinator(
                stageAStore: stageAStore,
                sessionStore: coldStore,
                limits: limits
            )
            let coldPrepared = try await coldCoordinator.restore(sessionID: prepared.session.id)
            let coldAgent = StageBReadOnlyAgent(
                provider: provider,
                executor: executor,
                policy: StageBReadOnlyPolicy(
                    workspace: coldPrepared.workspace,
                    ruleSet: coldPrepared.ruleSet,
                    limits: limits
                ),
                sessionStore: coldStore,
                workspace: coldPrepared.workspace,
                ruleSet: coldPrepared.ruleSet,
                limits: limits
            )
            guard case let .completed(coldCompletion) = await coldAgent.run(sessionID: prepared.session.id),
                  coldCompletion == completion else {
                writeFailure("cold_restore_failed")
                return
            }
            let after = try await coldStore.snapshot(sessionID: prepared.session.id)
            let afterCount = externalAttemptCount(after.attempts)
            guard beforeCount == afterCount else {
                writeFailure("cold_restore_retried_external_io")
                return
            }
            let toolSequence = after.attempts.compactMap {
                $0.observation?.tool.rawValue
            }
            write(StageBProbeSummary(
                resultCategory: "completed",
                sessionID: completion.sessionID.uuidString.lowercased(),
                importID: imported.id.uuidString.lowercased(),
                workspaceIdentitySHA256: completion.workspaceIdentitySHA256,
                goalBindingSHA256: completion.goalBindingSHA256,
                ruleSetBindingSHA256: completion.ruleSetBindingSHA256,
                ruleSources: coldPrepared.ruleSet.descriptors.map(\.relativePath),
                relativePath: completion.relativePath,
                providerRequestCount: completion.providerRequestCount,
                toolExecutionCount: completion.toolExecutionCount,
                toolSequence: toolSequence,
                evidenceChainSHA256: completion.evidenceChainSHA256,
                externalAttemptCountBeforeColdRestore: beforeCount,
                externalAttemptCountAfterColdRestore: afterCount,
                coldRestoreCategory: "durable_completed"
            ))
        } catch {
            writeFailure("probe_failed")
        }
    }

    private static func externalAttemptCount(_ attempts: [StageBAttemptEvidence]) -> Int {
        attempts.filter {
            ($0.kind == .provider || $0.kind == .executor) && $0.phase == .intentRecorded
        }.count
    }

    private static func writeFailure(_ category: String) {
        write(StageBProbeSummary(
            resultCategory: category,
            sessionID: "",
            importID: "",
            workspaceIdentitySHA256: String(repeating: "0", count: 64),
            goalBindingSHA256: String(repeating: "0", count: 64),
            ruleSetBindingSHA256: String(repeating: "0", count: 64),
            ruleSources: [],
            relativePath: "",
            providerRequestCount: 0,
            toolExecutionCount: 0,
            toolSequence: [],
            evidenceChainSHA256: String(repeating: "0", count: 64),
            externalAttemptCountBeforeColdRestore: 0,
            externalAttemptCountAfterColdRestore: 0,
            coldRestoreCategory: ""
        ))
    }

    private static func write(_ summary: StageBProbeSummary) {
        do {
            let documents = try FileManager.default.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(summary)
            try data.write(
                to: documents.appendingPathComponent("wuji-stage-b-summary.json"),
                options: .atomic
            )
        } catch {
            return
        }
    }
}
