import CryptoKit
import Foundation

enum S4ExecutorFailure: String, Error, Equatable, Sendable {
    case preparation
    case rejected
    case preconditionMismatch = "precondition_mismatch"
    case temporaryFilePresent = "temporary_file_present"
    case replacementCount = "replacement_count"
    case hashMismatch = "hash_mismatch"
    case nonzeroExit = "nonzero_exit"
    case incompleteDrain = "incomplete_drain"
    case observationLimit = "observation_limit"
    case malformedObservation = "malformed_observation"
}

struct S4EditObservation: Equatable, Sendable {
    let relativePath: String
    let beforeSHA256: String
    let afterSHA256: String
    let facts: S3ExecutorFacts

    func modelContent() -> String {
        "{\"after_sha256\":\"\(afterSHA256)\",\"before_sha256\":\"\(beforeSHA256)\",\"path\":\"\(relativePath)\",\"status\":\"success\",\"tool\":\"edit\"}"
    }
}

struct S4VerifyObservation: Equatable, Sendable {
    let profile: S4VerificationProfile
    let afterSHA256: String
    let contextSHA256: String
    let facts: S3ExecutorFacts

    func modelContent() -> String {
        "{\"after_sha256\":\"\(afterSHA256)\",\"context_sha256\":\"\(contextSHA256)\",\"profile\":\"\(profile.rawValue)\",\"status\":\"success\",\"tool\":\"verify\"}"
    }
}

enum S4EditOutcome: Equatable, Sendable {
    case observation(S4EditObservation)
    case failure(S4ExecutorFailure)
    case unknown
}

enum S4VerifyOutcome: Equatable, Sendable {
    case observation(S4VerifyObservation)
    case failure(S4ExecutorFailure)
    case unknown
}

enum S4ExecutorClassifier {
    static func edit(
        facts: S3ExecutorFacts?,
        stdout: String,
        stderr: String,
        edit: S4AuthorizedEdit
    ) -> S4EditOutcome {
        guard let facts, facts.completionBarrierSatisfied else { return .unknown }
        guard !facts.truncated else { return .failure(.observationLimit) }
        guard stderr.isEmpty else { return .failure(.malformedObservation) }
        switch facts.finalState {
        case .exited(0):
            guard stdout == "WUJI_S4_EDIT_OK\n" else {
                return .failure(.malformedObservation)
            }
            return .observation(S4EditObservation(
                relativePath: edit.relativePath,
                beforeSHA256: edit.beforeHash,
                afterSHA256: edit.afterHash,
                facts: facts
            ))
        case .exited(42): return .failure(.preconditionMismatch)
        case .exited(43): return .failure(.temporaryFilePresent)
        case .exited(44): return .failure(.replacementCount)
        case .exited(45), .exited(46): return .failure(.hashMismatch)
        case .unknown, .signaled: return .unknown
        default: return .failure(.nonzeroExit)
        }
    }

    static func verify(
        facts: S3ExecutorFacts?,
        stdout: String,
        stderr: String,
        profile: S4VerificationProfile
    ) -> S4VerifyOutcome {
        guard let facts, facts.completionBarrierSatisfied else { return .unknown }
        guard !facts.truncated else { return .failure(.observationLimit) }
        guard stderr.isEmpty else { return .failure(.malformedObservation) }
        switch facts.finalState {
        case .exited(0):
            guard stdout == "WUJI_S4_VERIFY_OK\n" else {
                return .failure(.malformedObservation)
            }
            return .observation(S4VerifyObservation(
                profile: profile,
                afterSHA256: S4TaskContract.afterHash,
                contextSHA256: S4TaskContract.contextHash,
                facts: facts
            ))
        case .unknown, .signaled: return .unknown
        default: return .failure(.nonzeroExit)
        }
    }
}

protocol S4Executing: S3ReadOnlyExecuting {
    func edit(_ edit: S4AuthorizedEdit) async -> S4EditOutcome
    func verify(_ profile: S4VerificationProfile) async -> S4VerifyOutcome
    func requestCancellation() -> ExecutorCancelDelivery
}

final class ISHS4Executor: S4Executing, @unchecked Sendable {
    private static let rootFSSize = 3_851_686
    private static let rootFSHash = "f31202c4070c4ef7de9e157e1bd01cb4da3a2150035d74ea5372c5e86f1efac1"

    private let rootFSURL: URL
    private let workspace: S4ApprovedWorkspace
    private let preparationLock = NSLock()
    private var prepared = false

    init(rootFSURL: URL, workspace: S4ApprovedWorkspace) {
        self.rootFSURL = rootFSURL
        self.workspace = workspace
    }

    static func bundled(workspace: S4ApprovedWorkspace) throws -> ISHS4Executor {
        guard let rootFSURL = Bundle.main.url(forResource: "rootfs", withExtension: "tar.gz") else {
            throw S4ExecutorFailure.preparation
        }
        return ISHS4Executor(rootFSURL: rootFSURL, workspace: workspace)
    }

    func execute(_ tool: S3AuthorizedTool) async -> S3ExecutorOutcome {
        guard prepare() else { return .failure(.preparation) }
        return await Task.detached(priority: .userInitiated) {
            let operation: WujiISHReadOnlyOperation
            switch tool.name {
            case .list: operation = WUJI_ISH_READ_ONLY_LIST
            case .search: operation = WUJI_ISH_READ_ONLY_SEARCH
            case .read: operation = WUJI_ISH_READ_ONLY_READ
            }
            let raw = tool.relativePath.withCString { path in
                if let query = tool.query {
                    return query.withCString {
                        wuji_ish_run_s4_read_only(
                            operation,
                            path,
                            $0,
                            numericCast(S3Limits.executorStreamBytes)
                        )
                    }
                }
                return wuji_ish_run_s4_read_only(
                    operation,
                    path,
                    nil,
                    numericCast(S3Limits.executorStreamBytes)
                )
            }
            guard let raw else { return .unknown }
            defer { wuji_ish_result_free(raw) }
            return self.readOutcome(raw, tool: tool)
        }.value
    }

    func edit(_ edit: S4AuthorizedEdit) async -> S4EditOutcome {
        guard prepare() else { return .failure(.preparation) }
        return await Task.detached(priority: .userInitiated) {
            let raw = edit.relativePath.withCString { path in
                S4TaskContract.expectedOldText.withCString { old in
                    S4TaskContract.replacementText.withCString { replacement in
                        edit.beforeHash.withCString { before in
                            edit.afterHash.withCString { after in
                                wuji_ish_run_s4_edit(
                                    path,
                                    old,
                                    replacement,
                                    before,
                                    after,
                                    numericCast(S3Limits.executorStreamBytes)
                                )
                            }
                        }
                    }
                }
            }
            guard let raw else { return .unknown }
            defer { wuji_ish_result_free(raw) }
            let stdout = String(cString: wuji_ish_result_stdout(raw))
            let stderr = String(cString: wuji_ish_result_stderr(raw))
            return S4ExecutorClassifier.edit(
                facts: self.facts(raw),
                stdout: stdout,
                stderr: stderr,
                edit: edit
            )
        }.value
    }

    func verify(_ profile: S4VerificationProfile) async -> S4VerifyOutcome {
        guard prepare() else { return .failure(.preparation) }
        return await Task.detached(priority: .userInitiated) {
            let raw = profile.rawValue.withCString { profileValue in
                S4TaskContract.afterHash.withCString { after in
                    S4TaskContract.contextHash.withCString { context in
                        wuji_ish_run_s4_verify(
                            profileValue,
                            after,
                            context,
                            numericCast(S3Limits.executorStreamBytes)
                        )
                    }
                }
            }
            guard let raw else { return .unknown }
            defer { wuji_ish_result_free(raw) }
            let stdout = String(cString: wuji_ish_result_stdout(raw))
            let stderr = String(cString: wuji_ish_result_stderr(raw))
            return S4ExecutorClassifier.verify(
                facts: self.facts(raw),
                stdout: stdout,
                stderr: stderr,
                profile: profile
            )
        }.value
    }

    func requestCancellation() -> ExecutorCancelDelivery {
        switch wuji_ish_request_cancel() {
        case WUJI_ISH_CANCEL_SIGNAL_SENT: return .signalSent
        case WUJI_ISH_CANCEL_NO_ACTIVE_TASK: return .noActiveTask
        default: return .unknown("S4 cancellation delivery unavailable")
        }
    }

    private func prepare() -> Bool {
        preparationLock.lock()
        defer { preparationLock.unlock() }
        if prepared { return true }
        do {
            let data = try Data(contentsOf: rootFSURL, options: .mappedIfSafe)
            guard data.count == Self.rootFSSize else { return false }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == Self.rootFSHash else { return false }
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let rootURL = support.appendingPathComponent("WujiS1Root", isDirectory: true)
            var error = [CChar](repeating: 0, count: 512)
            let preparedStatus = rootFSURL.path.withCString { archive in
                rootURL.path.withCString { root in
                    wuji_ish_prepare(archive, root, &error, error.count)
                }
            }
            guard preparedStatus == 0 else { return false }
            error = [CChar](repeating: 0, count: 512)
            let mountStatus = workspace.canonicalRootURL.path.withCString {
                wuji_ish_mount_s4_workspace($0, &error, error.count)
            }
            guard mountStatus == 0 else { return false }
            prepared = true
            return true
        } catch {
            return false
        }
    }

    private func facts(_ raw: OpaquePointer) -> S3ExecutorFacts? {
        let stdout = Data(String(cString: wuji_ish_result_stdout(raw)).utf8)
        let stderr = Data(String(cString: wuji_ish_result_stderr(raw)).utf8)
        let finalState: ExecutorFinalState
        switch wuji_ish_result_final_kind(raw) {
        case WUJI_ISH_FINAL_EXITED:
            finalState = .exited(wuji_ish_result_final_value(raw))
        case WUJI_ISH_FINAL_SIGNALED:
            finalState = .signaled(wuji_ish_result_final_value(raw))
        default:
            return nil
        }
        return S3ExecutorFacts(
            rootExitObserved: wuji_ish_result_root_exited(raw),
            stdoutEOFObserved: wuji_ish_result_stdout_eof(raw),
            stderrEOFObserved: wuji_ish_result_stderr_eof(raw),
            finalState: finalState,
            stdoutByteCount: stdout.count,
            stderrByteCount: stderr.count,
            stdoutSHA256: ProviderDigest.sha256Hex(stdout),
            stderrSHA256: ProviderDigest.sha256Hex(stderr),
            truncated: wuji_ish_result_truncated(raw)
        )
    }

    private func readOutcome(_ raw: OpaquePointer, tool: S3AuthorizedTool) -> S3ExecutorOutcome {
        guard let facts = facts(raw), facts.completionBarrierSatisfied else { return .unknown }
        guard !facts.truncated else { return .failure(.observationLimit) }
        let stdout = String(cString: wuji_ish_result_stdout(raw))
        let stderr = String(cString: wuji_ish_result_stderr(raw))
        guard stderr.isEmpty else { return .failure(.malformedObservation) }
        switch (tool, facts.finalState) {
        case (.search, .exited(1)), (_, .exited(0)):
            return makeReadObservation(tool: tool, stdout: stdout, facts: facts)
        case (_, .unknown), (_, .signaled): return .unknown
        default: return .failure(.nonzeroExit)
        }
    }

    private func makeReadObservation(
        tool: S3AuthorizedTool,
        stdout: String,
        facts: S3ExecutorFacts
    ) -> S3ExecutorOutcome {
        do {
            let payload: S3ObservationPayload
            switch tool {
            case .list:
                let entries = stdout.split(separator: "\n").map(String.init)
                guard entries.count <= S3Limits.maximumEntries,
                      entries.allSatisfy({ !$0.isEmpty && $0.utf8.count <= S3Limits.maximumLineBytes && !$0.contains("/") && !$0.contains("\\") }) else {
                    throw S3ExecutorFailure.observationLimit
                }
                payload = .list(entries: entries)
            case .search:
                let lines = stdout.split(separator: "\n").map(String.init)
                guard lines.count <= S3Limits.maximumMatches else { throw S3ExecutorFailure.observationLimit }
                payload = .search(matches: try lines.map(parseSearchMatch))
            case let .read(path):
                guard stdout.utf8.count <= S3Limits.maximumReadBytes,
                      stdout.split(separator: "\n", omittingEmptySubsequences: false).allSatisfy({ $0.utf8.count <= S3Limits.maximumLineBytes }) else {
                    throw S3ExecutorFailure.observationLimit
                }
                payload = .read(path: path, content: stdout)
            }
            let observation = S3ToolObservation(
                tool: tool.name,
                relativePath: tool.relativePath,
                query: tool.query,
                payload: payload,
                facts: facts
            )
            _ = try observation.modelContent()
            return .observation(observation)
        } catch let failure as S3ExecutorFailure {
            return .failure(failure)
        } catch {
            return .failure(.malformedObservation)
        }
    }

    private func parseSearchMatch(_ line: String) throws -> S3SearchMatch {
        guard line.utf8.count <= S3Limits.maximumLineBytes else {
            throw S3ExecutorFailure.observationLimit
        }
        let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let lineNumber = Int(parts[1]), lineNumber > 0 else {
            throw S3ExecutorFailure.malformedObservation
        }
        let prefix = "/wuji-s4/"
        let guestPath = String(parts[0])
        guard guestPath.hasPrefix(prefix) else { throw S3ExecutorFailure.malformedObservation }
        let relativePath = String(guestPath.dropFirst(prefix.count))
        guard !relativePath.isEmpty,
              !relativePath.contains(".."),
              !relativePath.contains("%"),
              !relativePath.contains("\\"),
              !relativePath.hasPrefix("/") else {
            throw S3ExecutorFailure.malformedObservation
        }
        return S3SearchMatch(path: relativePath, line: lineNumber, text: String(parts[2]))
    }
}
