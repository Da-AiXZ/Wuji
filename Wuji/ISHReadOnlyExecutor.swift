import CryptoKit
import Foundation

final class ISHReadOnlyExecutor: S3ReadOnlyExecuting, @unchecked Sendable {
    private static let rootFSSize = 3_851_686
    private static let rootFSHash = "f31202c4070c4ef7de9e157e1bd01cb4da3a2150035d74ea5372c5e86f1efac1"

    private let rootFSURL: URL
    private let workspace: S3ApprovedWorkspace
    private let preparationLock = NSLock()
    private var prepared = false

    init(rootFSURL: URL, workspace: S3ApprovedWorkspace) {
        self.rootFSURL = rootFSURL
        self.workspace = workspace
    }

    static func bundled() throws -> ISHReadOnlyExecutor {
        guard let rootFSURL = Bundle.main.url(forResource: "rootfs", withExtension: "tar.gz") else {
            throw S3ExecutorFailure.preparation
        }
        return ISHReadOnlyExecutor(
            rootFSURL: rootFSURL,
            workspace: try S3ApprovedWorkspace.bundled()
        )
    }

    func execute(_ tool: S3AuthorizedTool) async -> S3ExecutorOutcome {
        do {
            try prepareIfNeeded()
        } catch {
            return .failure(.preparation)
        }

        return await Task.detached(priority: .userInitiated) {
            let operation: WujiISHReadOnlyOperation
            switch tool.name {
            case .list: operation = WUJI_ISH_READ_ONLY_LIST
            case .search: operation = WUJI_ISH_READ_ONLY_SEARCH
            case .read: operation = WUJI_ISH_READ_ONLY_READ
            }

            let rawResult = tool.relativePath.withCString { path in
                if let query = tool.query {
                    return query.withCString { queryPointer in
                        wuji_ish_run_read_only(
                            operation,
                            path,
                            queryPointer,
                            numericCast(S3Limits.executorStreamBytes)
                        )
                    }
                }
                return wuji_ish_run_read_only(
                    operation,
                    path,
                    nil,
                    numericCast(S3Limits.executorStreamBytes)
                )
            }
            guard let rawResult else { return .unknown }
            defer { wuji_ish_result_free(rawResult) }
            return self.makeOutcome(rawResult, tool: tool)
        }.value
    }

    private func prepareIfNeeded() throws {
        preparationLock.lock()
        defer { preparationLock.unlock() }
        if prepared { return }

        let data = try Data(contentsOf: rootFSURL, options: .mappedIfSafe)
        guard data.count == Self.rootFSSize else { throw S3ExecutorFailure.preparation }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == Self.rootFSHash else { throw S3ExecutorFailure.preparation }

        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let rootURL = applicationSupport.appendingPathComponent("WujiS1Root", isDirectory: true)
        var errorBuffer = [CChar](repeating: 0, count: 512)
        let prepareStatus = rootFSURL.path.withCString { archivePath in
            rootURL.path.withCString { rootPath in
                wuji_ish_prepare(archivePath, rootPath, &errorBuffer, errorBuffer.count)
            }
        }
        guard prepareStatus == 0 else { throw S3ExecutorFailure.preparation }

        errorBuffer = [CChar](repeating: 0, count: 512)
        let mountStatus = workspace.canonicalRootURL.path.withCString { workspacePath in
            wuji_ish_mount_read_only_workspace(
                workspacePath,
                &errorBuffer,
                errorBuffer.count
            )
        }
        guard mountStatus == 0 else { throw S3ExecutorFailure.preparation }
        prepared = true
    }

    private func makeOutcome(
        _ rawResult: OpaquePointer,
        tool: S3AuthorizedTool
    ) -> S3ExecutorOutcome {
        let stdout = String(cString: wuji_ish_result_stdout(rawResult))
        let stderr = String(cString: wuji_ish_result_stderr(rawResult))
        let stdoutData = Data(stdout.utf8)
        let stderrData = Data(stderr.utf8)
        let finalState: ExecutorFinalState
        switch wuji_ish_result_final_kind(rawResult) {
        case WUJI_ISH_FINAL_EXITED:
            finalState = .exited(wuji_ish_result_final_value(rawResult))
        case WUJI_ISH_FINAL_SIGNALED:
            finalState = .signaled(wuji_ish_result_final_value(rawResult))
        default:
            return .unknown
        }
        let facts = S3ExecutorFacts(
            rootExitObserved: wuji_ish_result_root_exited(rawResult),
            stdoutEOFObserved: wuji_ish_result_stdout_eof(rawResult),
            stderrEOFObserved: wuji_ish_result_stderr_eof(rawResult),
            finalState: finalState,
            stdoutByteCount: stdoutData.count,
            stderrByteCount: stderrData.count,
            stdoutSHA256: ProviderDigest.sha256Hex(stdoutData),
            stderrSHA256: ProviderDigest.sha256Hex(stderrData),
            truncated: wuji_ish_result_truncated(rawResult)
        )
        guard facts.completionBarrierSatisfied else { return .unknown }
        guard !facts.truncated else { return .failure(.observationLimit) }
        guard stderr.isEmpty else { return .failure(.malformedObservation) }

        switch (tool, finalState) {
        case (.search, .exited(1)):
            return observation(tool: tool, stdout: stdout, facts: facts)
        case (_, .exited(0)):
            return observation(tool: tool, stdout: stdout, facts: facts)
        case (_, .unknown), (_, .signaled):
            return .unknown
        default:
            return .failure(.nonzeroExit)
        }
    }

    private func observation(
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
                      entries.allSatisfy({
                          !$0.isEmpty
                              && $0.utf8.count <= S3Limits.maximumLineBytes
                              && !$0.contains("/")
                              && !$0.contains("\\")
                      }) else {
                    throw S3ExecutorFailure.observationLimit
                }
                payload = .list(entries: entries)
            case .search:
                let lines = stdout.split(separator: "\n").map(String.init)
                guard lines.count <= S3Limits.maximumMatches else {
                    throw S3ExecutorFailure.observationLimit
                }
                let matches = try lines.map(parseSearchMatch)
                payload = .search(matches: matches)
            case let .read(path):
                guard stdout.utf8.count <= S3Limits.maximumReadBytes,
                      stdout.split(separator: "\n", omittingEmptySubsequences: false).allSatisfy({
                          $0.utf8.count <= S3Limits.maximumLineBytes
                      }) else {
                    throw S3ExecutorFailure.observationLimit
                }
                payload = .read(path: path, content: stdout)
            }
            let value = S3ToolObservation(
                tool: tool.name,
                relativePath: tool.relativePath,
                query: tool.query,
                payload: payload,
                facts: facts
            )
            _ = try value.modelContent()
            return .observation(value)
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
        guard parts.count == 3,
              let lineNumber = Int(parts[1]),
              lineNumber > 0 else {
            throw S3ExecutorFailure.malformedObservation
        }
        let guestPath = String(parts[0])
        let prefix = "/wuji-s3/"
        guard guestPath.hasPrefix(prefix) else {
            throw S3ExecutorFailure.malformedObservation
        }
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
