import CryptoKit
import Foundation

final class ISHStageBReadOnlyExecutor: StageBReadOnlyExecuting, @unchecked Sendable {
    private static let rootFSSize = 3_851_686
    private static let rootFSHash = "f31202c4070c4ef7de9e157e1bd01cb4da3a2150035d74ea5372c5e86f1efac1"

    private let rootFSURL: URL
    private let workspace: StageBReadyWorkspace
    private let limits: StageBLimits
    private let preparationLock = NSLock()
    private var prepared = false

    init(rootFSURL: URL, workspace: StageBReadyWorkspace, limits: StageBLimits = .production) {
        self.rootFSURL = rootFSURL
        self.workspace = workspace
        self.limits = limits
    }

    static func bundled(
        workspace: StageBReadyWorkspace,
        limits: StageBLimits = .production
    ) throws -> ISHStageBReadOnlyExecutor {
        guard let rootFSURL = Bundle.main.url(forResource: "rootfs", withExtension: "tar.gz") else {
            throw StageBExecutorFailure.preparation
        }
        return ISHStageBReadOnlyExecutor(
            rootFSURL: rootFSURL,
            workspace: workspace,
            limits: limits
        )
    }

    func execute(_ tool: StageBAuthorizedTool) async -> StageBExecutorOutcome {
        guard limits.maximumExecutorStreamBytes <= 32 * 1_024 else {
            return .failure(.preparation)
        }
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
            let raw = tool.relativePath.withCString { path in
                if let query = tool.query {
                    return query.withCString {
                        wuji_ish_run_stage_b_read_only(
                            operation,
                            path,
                            $0,
                            numericCast(self.limits.maximumExecutorStreamBytes)
                        )
                    }
                }
                return wuji_ish_run_stage_b_read_only(
                    operation,
                    path,
                    nil,
                    numericCast(self.limits.maximumExecutorStreamBytes)
                )
            }
            guard let raw else { return .unknown }
            defer { wuji_ish_result_free(raw) }
            return self.makeOutcome(raw, tool: tool)
        }.value
    }

    private func prepareIfNeeded() throws {
        preparationLock.lock()
        defer { preparationLock.unlock() }
        if prepared { return }

        let data = try Data(contentsOf: rootFSURL, options: .mappedIfSafe)
        guard data.count == Self.rootFSSize,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == Self.rootFSHash else {
            throw StageBExecutorFailure.preparation
        }
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let rootURL = support.appendingPathComponent("WujiS1Root", isDirectory: true)
        var error = [CChar](repeating: 0, count: 512)
        let prepareStatus = rootFSURL.path.withCString { archive in
            rootURL.path.withCString { root in
                wuji_ish_prepare(archive, root, &error, error.count)
            }
        }
        guard prepareStatus == 0 else { throw StageBExecutorFailure.preparation }
        error = [CChar](repeating: 0, count: 512)
        let mountStatus = workspace.canonicalRootURL.path.withCString {
            wuji_ish_mount_stage_b_workspace($0, &error, error.count)
        }
        guard mountStatus == 0 else { throw StageBExecutorFailure.preparation }
        prepared = true
    }

    private func makeOutcome(
        _ raw: OpaquePointer,
        tool: StageBAuthorizedTool
    ) -> StageBExecutorOutcome {
        let stdoutLength = Int(wuji_ish_result_stdout_length(raw))
        let stderrLength = Int(wuji_ish_result_stderr_length(raw))
        guard stdoutLength <= limits.maximumExecutorStreamBytes,
              stderrLength <= limits.maximumExecutorStreamBytes else {
            return .failure(.observationLimit)
        }
        let stdoutData = Data(bytes: wuji_ish_result_stdout(raw), count: stdoutLength)
        let stderrData = Data(bytes: wuji_ish_result_stderr(raw), count: stderrLength)
        guard !stdoutData.contains(0),
              !stderrData.contains(0),
              let stdout = String(data: stdoutData, encoding: .utf8),
              let stderr = String(data: stderrData, encoding: .utf8) else {
            return .failure(.malformedObservation)
        }
        let kind: String
        let value: Int32
        switch wuji_ish_result_final_kind(raw) {
        case WUJI_ISH_FINAL_EXITED:
            kind = "exited"
            value = wuji_ish_result_final_value(raw)
        case WUJI_ISH_FINAL_SIGNALED:
            kind = "signaled"
            value = wuji_ish_result_final_value(raw)
        default:
            return .unknown
        }
        let facts = StageBExecutorFacts(
            rootExitObserved: wuji_ish_result_root_exited(raw),
            stdoutEOFObserved: wuji_ish_result_stdout_eof(raw),
            stderrEOFObserved: wuji_ish_result_stderr_eof(raw),
            finalStateKind: kind,
            finalStateValue: value,
            stdoutByteCount: stdoutData.count,
            stderrByteCount: stderrData.count,
            stdoutSHA256: ProviderDigest.sha256Hex(stdoutData),
            stderrSHA256: ProviderDigest.sha256Hex(stderrData),
            truncated: wuji_ish_result_truncated(raw)
        )
        guard facts.completionBarrierSatisfied else { return .unknown }
        guard !facts.truncated,
              stdoutData.count <= limits.maximumExecutorStreamBytes,
              stderrData.count <= limits.maximumExecutorStreamBytes else {
            return .failure(.observationLimit)
        }
        guard stderr.isEmpty else { return .failure(.malformedObservation) }
        if kind == "signaled" { return .unknown }
        if tool.name == .search, value == 1 {
            return observation(tool: tool, stdout: stdout, facts: facts)
        }
        guard value == 0 else { return .failure(.nonzeroExit) }
        return observation(tool: tool, stdout: stdout, facts: facts)
    }

    private func observation(
        tool: StageBAuthorizedTool,
        stdout: String,
        facts: StageBExecutorFacts
    ) -> StageBExecutorOutcome {
        do {
            let payload: StageBObservationPayload
            switch tool.name {
            case .list:
                let rawEntries = stdout.split(separator: "\n").map(String.init)
                let entries = tool.relativePath.isEmpty
                    ? rawEntries.filter { $0 != StageAWorkspaceMarker.fileName }
                    : rawEntries
                let internalEntryAllowance = tool.relativePath.isEmpty ? 1 : 0
                guard rawEntries.count <= limits.maximumListEntries + internalEntryAllowance,
                      entries.count <= limits.maximumListEntries,
                      entries.allSatisfy({
                          !$0.isEmpty
                              && $0.utf8.count <= limits.maximumLineBytes
                              && !$0.contains("/")
                              && !$0.contains("\\")
                      }) else { throw StageBExecutorFailure.observationLimit }
                payload = .list(entries: entries)
            case .search:
                let lines = stdout.split(separator: "\n").map(String.init)
                guard lines.count <= limits.maximumSearchMatches else {
                    throw StageBExecutorFailure.observationLimit
                }
                payload = .search(matches: try lines.map(parseSearchMatch))
            case .read:
                guard !tool.relativePath.isEmpty,
                      tool.relativePath != StageAWorkspaceMarker.fileName,
                      stdout.utf8.count <= limits.maximumReadBytes,
                      stdout.split(separator: "\n", omittingEmptySubsequences: false).allSatisfy({
                          $0.utf8.count <= limits.maximumLineBytes
                      }) else { throw StageBExecutorFailure.observationLimit }
                payload = .read(path: tool.relativePath, content: stdout)
            }
            let observation = StageBToolObservation(
                tool: tool.name,
                relativePath: tool.relativePath,
                query: tool.query,
                ruleSetSHA256: tool.ruleSetSHA256,
                payload: payload,
                facts: facts
            )
            _ = try StageBModelObservation.render(observation, limits: limits)
            return .observation(observation)
        } catch let failure as StageBExecutorFailure {
            return .failure(failure)
        } catch {
            return .failure(.malformedObservation)
        }
    }

    private func parseSearchMatch(_ line: String) throws -> StageBSearchMatch {
        guard line.utf8.count <= limits.maximumLineBytes else {
            throw StageBExecutorFailure.observationLimit
        }
        let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let lineNumber = Int(parts[1]), lineNumber > 0 else {
            throw StageBExecutorFailure.malformedObservation
        }
        let prefix = "/wuji-stage-b/"
        let guestPath = String(parts[0])
        guard guestPath.hasPrefix(prefix) else { throw StageBExecutorFailure.malformedObservation }
        let path = String(guestPath.dropFirst(prefix.count))
        guard StageBPathSyntax.valid(path, allowEmpty: false, maximumBytes: limits.maximumPathBytes),
              path != StageAWorkspaceMarker.fileName else {
            throw StageBExecutorFailure.malformedObservation
        }
        return StageBSearchMatch(path: path, line: lineNumber, text: String(parts[2]))
    }
}
