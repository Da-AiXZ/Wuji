import CryptoKit
import Foundation

final class ISHStageCEditExecutor: StageCEditExecuting, @unchecked Sendable {
    private static let rootFSSize = 3_851_686
    private static let rootFSHash = "f31202c4070c4ef7de9e157e1bd01cb4da3a2150035d74ea5372c5e86f1efac1"

    private let rootFSURL: URL
    private let workspace: StageBReadyWorkspace
    private let limits: StageCLimits
    private let preparationLock = NSLock()
    private var prepared = false

    init(rootFSURL: URL, workspace: StageBReadyWorkspace, limits: StageCLimits = .production) {
        self.rootFSURL = rootFSURL
        self.workspace = workspace
        self.limits = limits
    }

    static func bundled(
        workspace: StageBReadyWorkspace,
        limits: StageCLimits = .production
    ) throws -> ISHStageCEditExecutor {
        guard let rootFSURL = Bundle.main.url(forResource: "rootfs", withExtension: "tar.gz") else {
            throw StageCError.executorFailure
        }
        return ISHStageCEditExecutor(rootFSURL: rootFSURL, workspace: workspace, limits: limits)
    }

    func execute(_ proposal: StageCEditProposal) async -> StageCExecutorOutcome {
        guard prepare() else { return .failure(nil) }
        return await Task.detached(priority: .userInitiated) {
            let raw = proposal.relativePath.withCString { path in
                proposal.expectedOld.withCString { old in
                    proposal.replacement.withCString { replacement in
                        proposal.beforeSHA256.withCString { before in
                            proposal.afterSHA256.withCString { after in
                                wuji_ish_run_stage_c_edit(
                                    path,
                                    old,
                                    replacement,
                                    before,
                                    after,
                                    numericCast(self.limits.maximumExecutorStreamBytes)
                                )
                            }
                        }
                    }
                }
            }
            guard let raw else { return .unknown(nil) }
            defer { wuji_ish_result_free(raw) }
            let facts = self.facts(raw)
            guard facts.terminalBarrierSatisfied else { return .unknown(facts) }
            guard !facts.truncated else { return .failure(facts) }
            let stdout = Data(String(cString: wuji_ish_result_stdout(raw)).utf8)
            let stderr = Data(String(cString: wuji_ish_result_stderr(raw)).utf8)
            guard stdout.count <= self.limits.maximumExecutorStreamBytes,
                  stderr.count <= self.limits.maximumExecutorStreamBytes,
                  stderr.isEmpty else { return .failure(facts) }
            guard facts.finalStateKind == "exited" else { return .unknown(facts) }
            if facts.finalStateValue == 0,
               String(data: stdout, encoding: .utf8) == "WUJI_STAGE_C_EDIT_OK\n" {
                return .applied(facts)
            }
            return .failure(facts)
        }.value
    }

    private func prepare() -> Bool {
        preparationLock.lock()
        defer { preparationLock.unlock() }
        if prepared { return true }
        do {
            let data = try Data(contentsOf: rootFSURL, options: .mappedIfSafe)
            guard data.count == Self.rootFSSize,
                  ProviderDigest.sha256Hex(data) == Self.rootFSHash else { return false }
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
            guard prepareStatus == 0 else { return false }
            error = [CChar](repeating: 0, count: 512)
            let mountStatus = workspace.canonicalRootURL.path.withCString {
                wuji_ish_mount_stage_b_workspace($0, &error, error.count)
            }
            guard mountStatus == 0 else { return false }
            prepared = true
            return true
        } catch {
            return false
        }
    }

    private func facts(_ raw: OpaquePointer) -> StageCExecutorFacts {
        let kind: String
        switch wuji_ish_result_final_kind(raw) {
        case WUJI_ISH_FINAL_EXITED: kind = "exited"
        case WUJI_ISH_FINAL_SIGNALED: kind = "signaled"
        default: kind = "unknown"
        }
        return StageCExecutorFacts(
            rootExitObserved: wuji_ish_result_root_exited(raw),
            stdoutEOFObserved: wuji_ish_result_stdout_eof(raw),
            stderrEOFObserved: wuji_ish_result_stderr_eof(raw),
            finalStateKind: kind,
            finalStateValue: wuji_ish_result_final_value(raw),
            truncated: wuji_ish_result_truncated(raw)
        )
    }
}
