import Foundation

private struct S3ProbeSummary: Codable {
    let taskID: String
    let resultCategory: String
    let relativePath: String
    let value: String
    let providerRequestCount: Int
    let toolExecutionCount: Int
    let observationSHA256: String
    let loopFailureCode: String
    let policyRejectionReason: String
    let policyCallIndex: Int

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case resultCategory = "result_category"
        case relativePath = "relative_path"
        case value
        case providerRequestCount = "provider_request_count"
        case toolExecutionCount = "tool_execution_count"
        case observationSHA256 = "observation_sha256"
        case loopFailureCode = "loop_failure_code"
        case policyRejectionReason = "policy_rejection_reason"
        case policyCallIndex = "policy_call_index"
    }
}

enum S3ProbeRunner {
    static func startIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WUJI_S3_PROBE_MODE"] == "1" else { return }
        Task.detached(priority: .userInitiated) {
            await run(environment: environment)
        }
    }

    private static func run(environment: [String: String]) async {
        let taskID = UUID()
        guard let baseURL = environment["DEEPSEEK_BASE_URL"],
              let model = environment["DEEPSEEK_MODEL"],
              let apiKey = environment["DEEPSEEK_API_KEY"],
              !baseURL.isEmpty,
              !model.isEmpty,
              !apiKey.isEmpty,
              !CommandLine.arguments.contains(where: {
                  $0.contains(baseURL) || $0.contains(model) || $0.contains(apiKey)
              }) else {
            writeFailure(taskID: taskID, category: "configuration_rejected")
            return
        }

        do {
            let applicationSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let evidenceDirectory = applicationSupport.appendingPathComponent(
                "WujiS3Evidence-\(taskID.uuidString)",
                isDirectory: true
            )
            let credential = try ProviderCredential(apiKey)
            let providerStore = try FileProviderAttemptStore(directoryURL: evidenceDirectory)
            let provider = try DeepSeekProvider(
                baseURL: baseURL,
                model: model,
                credentialSource: StaticProviderCredentialSource(credential: credential),
                transport: URLSessionProviderTransport(),
                attemptStore: providerStore
            )
            let workspace = try S3ApprovedWorkspace.bundled()
            let executor = try ISHReadOnlyExecutor.bundled()
            let loopStore = try FileS3AttemptStore(directoryURL: evidenceDirectory)
            let agent = S3ReadOnlyAgent(
                provider: provider,
                executor: executor,
                policy: S3ToolPolicy(workspace: workspace),
                attemptStore: loopStore
            )

            switch await agent.run(taskID: taskID) {
            case let .completed(completion):
                guard completion.taskID == taskID,
                      completion.relativePath == "records/target.txt",
                      completion.value == S3TaskContract.value,
                      completion.providerRequestCount > 0,
                      completion.providerRequestCount <= S3Limits.maximumProviderTurns,
                      completion.toolExecutionCount >= 3,
                      completion.toolExecutionCount <= S3Limits.maximumToolExecutions,
                      completion.observationSHA256.count == 64 else {
                    writeFailure(taskID: taskID, category: "completion_validation_failed")
                    return
                }
                write(S3ProbeSummary(
                    taskID: taskID.uuidString,
                    resultCategory: "completed",
                    relativePath: completion.relativePath,
                    value: completion.value,
                    providerRequestCount: completion.providerRequestCount,
                    toolExecutionCount: completion.toolExecutionCount,
                    observationSHA256: completion.observationSHA256,
                    loopFailureCode: "",
                    policyRejectionReason: "",
                    policyCallIndex: -1
                ))
            case .reconciliationRequired:
                writeFailure(taskID: taskID, category: "reconciliation_required")
            case let .failure(failure):
                if case let .policyRejected(reason, callIndex) = failure {
                    writeFailure(
                        taskID: taskID,
                        category: "loop_failure",
                        loopFailureCode: failure.summaryCode,
                        policyRejectionReason: reason.rawValue,
                        policyCallIndex: callIndex ?? -1
                    )
                } else {
                    writeFailure(
                        taskID: taskID,
                        category: "loop_failure",
                        loopFailureCode: failure.summaryCode
                    )
                }
            }
        } catch {
            writeFailure(taskID: taskID, category: "configuration_rejected")
        }
    }

    private static func writeFailure(
        taskID: UUID,
        category: String,
        loopFailureCode: String = "",
        policyRejectionReason: String = "",
        policyCallIndex: Int = -1
    ) {
        write(S3ProbeSummary(
            taskID: taskID.uuidString,
            resultCategory: category,
            relativePath: "",
            value: "",
            providerRequestCount: 0,
            toolExecutionCount: 0,
            observationSHA256: String(repeating: "0", count: 64),
            loopFailureCode: loopFailureCode,
            policyRejectionReason: policyRejectionReason,
            policyCallIndex: policyCallIndex
        ))
    }

    private static func write(_ summary: S3ProbeSummary) {
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
                to: documents.appendingPathComponent("wuji-s3-summary.json"),
                options: .atomic
            )
        } catch {
            return
        }
    }
}
