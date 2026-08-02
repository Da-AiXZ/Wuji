import Foundation

private struct S4ProbeSummary: Codable {
    let resultCategory: String
    let providerRequestCount: Int
    let executorCallCount: Int
    let toolSequence: [String]
    let approvalCategory: String
    let authorizedPath: String
    let beforeSHA256: String
    let afterSHA256: String
    let diffSHA256: String
    let writeCategory: String
    let verifyCategory: String
    let writeRootExitObserved: Bool
    let writeStdoutEOFObserved: Bool
    let writeStderrEOFObserved: Bool
    let writeTruncated: Bool
    let verifyRootExitObserved: Bool
    let verifyStdoutEOFObserved: Bool
    let verifyStderrEOFObserved: Bool
    let verifyTruncated: Bool
    let completionCategory: String
    let policyRejectionReason: String
    let policyCallIndex: Int

    enum CodingKeys: String, CodingKey {
        case resultCategory = "result_category"
        case providerRequestCount = "provider_request_count"
        case executorCallCount = "executor_call_count"
        case toolSequence = "tool_sequence"
        case approvalCategory = "approval_category"
        case authorizedPath = "authorized_path"
        case beforeSHA256 = "before_sha256"
        case afterSHA256 = "after_sha256"
        case diffSHA256 = "diff_sha256"
        case writeCategory = "write_category"
        case verifyCategory = "verify_category"
        case writeRootExitObserved = "write_root_exit_observed"
        case writeStdoutEOFObserved = "write_stdout_eof_observed"
        case writeStderrEOFObserved = "write_stderr_eof_observed"
        case writeTruncated = "write_truncated"
        case verifyRootExitObserved = "verify_root_exit_observed"
        case verifyStdoutEOFObserved = "verify_stdout_eof_observed"
        case verifyStderrEOFObserved = "verify_stderr_eof_observed"
        case verifyTruncated = "verify_truncated"
        case completionCategory = "completion_category"
        case policyRejectionReason = "policy_rejection_reason"
        case policyCallIndex = "policy_call_index"
    }
}

enum S4ProbeRunner {
    static func startIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WUJI_S4_PROBE_MODE"] == "1" else { return }
        Task.detached(priority: .userInitiated) {
            await run(environment: environment)
        }
    }

    private static func run(environment: [String: String]) async {
        let taskID = UUID()
        guard environment["WUJI_S4_TASK_PACKAGE_ID"] == S4TaskContract.packageID,
              let baseURL = environment["DEEPSEEK_BASE_URL"],
              let model = environment["DEEPSEEK_MODEL"],
              let apiKey = environment["DEEPSEEK_API_KEY"],
              !baseURL.isEmpty,
              !model.isEmpty,
              !apiKey.isEmpty,
              !CommandLine.arguments.contains(where: {
                  $0.contains(baseURL) || $0.contains(model) || $0.contains(apiKey)
              }) else {
            writeFailure(category: "configuration_rejected")
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
                "WujiS4Evidence-\(taskID.uuidString.lowercased())",
                isDirectory: true
            )
            let durableStore = try FileS4DurableStore(directoryURL: evidenceDirectory)
            let prepareOperationID = UUID()
            let prepareAttemptID = UUID()
            let prepareHash = ProviderDigest.sha256Hex(
                "\(S4TaskContract.packageID)\u{0}\(taskID.uuidString.lowercased())"
            )
            try await durableStore.recordAttempt(attempt(
                taskID: taskID,
                operationID: prepareOperationID,
                attemptID: prepareAttemptID,
                inputSHA256: prepareHash,
                phase: .intentRecorded,
                category: .none,
                result: nil
            ))

            let workspace = try S4ApprovedWorkspace.prepare(
                taskID: taskID,
                applicationSupportURL: applicationSupport
            )
            try await durableStore.recordAttempt(attempt(
                taskID: taskID,
                operationID: prepareOperationID,
                attemptID: prepareAttemptID,
                inputSHA256: prepareHash,
                phase: .succeeded,
                category: .workspaceBefore,
                result: Data(workspace.workspaceID.utf8)
            ))

            let credential = try ProviderCredential(apiKey)
            let providerStore = try FileProviderAttemptStore(directoryURL: evidenceDirectory)
            let provider = try DeepSeekProvider(
                baseURL: baseURL,
                model: model,
                credentialSource: StaticProviderCredentialSource(credential: credential),
                transport: URLSessionProviderTransport(),
                attemptStore: providerStore
            )
            let executor = try ISHS4Executor.bundled(workspace: workspace)
            let authorizer = S4ValidationApprovalAuthorizer(
                probeMode: true,
                taskPackageID: S4TaskContract.packageID,
                workspace: workspace,
                now: { Date() }
            )
            let agent = S4Agent(
                provider: provider,
                executor: executor,
                policy: try S4ToolPolicy(workspace: workspace),
                durableStore: durableStore,
                approvalAuthorizer: authorizer,
                workspace: workspace
            )

            let outcome = await agent.run(taskID: taskID)
            let snapshot = try await durableStore.snapshot(taskID: taskID)
            switch outcome {
            case let .completed(completion):
                guard let summary = completedSummary(completion: completion, snapshot: snapshot) else {
                    writeFailure(category: "completion_validation_failed")
                    return
                }
                write(summary)
            case .reconciliationRequired:
                writeFailure(category: "reconciliation_required")
            case let .policyRejected(diagnostic):
                writeFailure(
                    category: "policy_rejected",
                    policyRejectionReason: diagnostic.reason.rawValue,
                    policyCallIndex: diagnostic.callIndex ?? -1
                )
            case let .failure(failure):
                writeFailure(category: failure.rawValue)
            }
        } catch {
            writeFailure(category: "configuration_rejected")
        }
    }

    private static func completedSummary(
        completion: S4Completion,
        snapshot: S4DurableSnapshot
    ) -> S4ProbeSummary? {
        let terminals = snapshot.attempts.filter {
            $0.phase != .intentRecorded
                && [.readExecutor, .writeExecutor, .verifyExecutor].contains($0.ioKind)
        }
        let sequence = terminals.compactMap { evidence -> String? in
            guard evidence.phase == .succeeded else { return nil }
            return evidence.toolName
        }
        guard sequence.contains("list"),
              sequence.contains("search"),
              sequence.contains("read"),
              sequence.filter({ $0 == "edit" }).count == 1,
              sequence.filter({ $0 == "verify" }).count == 1,
              let write = terminals.last(where: {
                  $0.ioKind == .writeExecutor && $0.phase == .succeeded
              }),
              let verify = terminals.last(where: { $0.ioKind == .verifyExecutor }),
              write.resultCategory == .writeApplied,
              verify.resultCategory == .verifyPassed,
              write.rootExitObserved == true,
              write.stdoutEOFObserved == true,
              write.stderrEOFObserved == true,
              write.truncated == false,
              verify.rootExitObserved == true,
              verify.stdoutEOFObserved == true,
              verify.stderrEOFObserved == true,
              verify.truncated == false,
              snapshot.approvals.last?.phase == .granted,
              completion.authorizedPath == S4TaskContract.authorizedPath,
              completion.beforeSHA256 == S4TaskContract.beforeHash,
              completion.afterSHA256 == S4TaskContract.afterHash else { return nil }

        return S4ProbeSummary(
            resultCategory: "completed",
            providerRequestCount: completion.providerRequestCount,
            executorCallCount: sequence.count,
            toolSequence: sequence,
            approvalCategory: "validation_grant",
            authorizedPath: completion.authorizedPath,
            beforeSHA256: completion.beforeSHA256,
            afterSHA256: completion.afterSHA256,
            diffSHA256: completion.workspaceDiffSHA256,
            writeCategory: write.resultCategory.rawValue,
            verifyCategory: verify.resultCategory.rawValue,
            writeRootExitObserved: true,
            writeStdoutEOFObserved: true,
            writeStderrEOFObserved: true,
            writeTruncated: false,
            verifyRootExitObserved: true,
            verifyStdoutEOFObserved: true,
            verifyStderrEOFObserved: true,
            verifyTruncated: false,
            completionCategory: "code_owned_completed",
            policyRejectionReason: "",
            policyCallIndex: -1
        )
    }

    private static func attempt(
        taskID: UUID,
        operationID: UUID,
        attemptID: UUID,
        inputSHA256: String,
        phase: S4AttemptPhase,
        category: S4AttemptResultCategory,
        result: Data?
    ) -> S4AttemptEvidence {
        S4AttemptEvidence(
            taskID: taskID,
            operationID: operationID,
            attemptID: attemptID,
            ioKind: .workspacePrepare,
            providerID: nil,
            toolName: nil,
            toolCallIDHash: nil,
            approvalNonceHash: nil,
            inputSHA256: inputSHA256,
            recordedAt: Date(),
            phase: phase,
            resultCategory: category,
            resultByteCount: result?.count,
            resultSHA256: result.map(ProviderDigest.sha256Hex),
            rootExitObserved: nil,
            stdoutEOFObserved: nil,
            stderrEOFObserved: nil,
            finalStateKind: nil,
            finalStateValue: nil,
            truncated: nil
        )
    }

    private static func writeFailure(
        category: String,
        policyRejectionReason: String = "",
        policyCallIndex: Int = -1
    ) {
        write(S4ProbeSummary(
            resultCategory: category,
            providerRequestCount: 0,
            executorCallCount: 0,
            toolSequence: [],
            approvalCategory: "none",
            authorizedPath: S4TaskContract.authorizedPath,
            beforeSHA256: S4TaskContract.beforeHash,
            afterSHA256: S4TaskContract.afterHash,
            diffSHA256: String(repeating: "0", count: 64),
            writeCategory: "none",
            verifyCategory: "none",
            writeRootExitObserved: false,
            writeStdoutEOFObserved: false,
            writeStderrEOFObserved: false,
            writeTruncated: false,
            verifyRootExitObserved: false,
            verifyStdoutEOFObserved: false,
            verifyStderrEOFObserved: false,
            verifyTruncated: false,
            completionCategory: "not_completed",
            policyRejectionReason: policyRejectionReason,
            policyCallIndex: policyCallIndex
        ))
    }

    private static func write(_ summary: S4ProbeSummary) {
        do {
            let documents = try FileManager.default.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(summary).write(
                to: documents.appendingPathComponent("wuji-s4-summary.json"),
                options: .atomic
            )
        } catch {
            return
        }
    }
}
