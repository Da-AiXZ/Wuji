import CryptoKit
import Foundation

private final class StageDTimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func mark() {
        lock.lock()
        value = true
        lock.unlock()
    }

    func snapshot() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private struct StageDRawStep: Sendable {
    let facts: StageDProcessFacts
    let stdout: String
    let stderr: String
}

struct StageDSystemResolverEvidence: Equatable, Sendable {
    let nameserverCount: UInt32
    let searchDomainCount: UInt32
    let configurationBytes: Int
    let configurationCount: UInt32
}

final class ISHStageDCommandExecutor: StageDCommandExecuting, @unchecked Sendable {
    private let rootFSURL: URL
    private let workspace: StageBReadyWorkspace
    private let cloneRootURL: URL
    private let limits: StageDLimits
    private let resolverConfigurator: @Sendable () -> StageDSystemResolverEvidence?
    private let preparationLock = NSLock()
    private var prepared = false
    private var resolverEvidence: StageDSystemResolverEvidence?

    private static let productionResolverConfigurator: @Sendable () -> StageDSystemResolverEvidence? = {
        var nameserverCount: UInt32 = 0
        var searchDomainCount: UInt32 = 0
        var configurationBytes = 0
        var configurationCount: UInt32 = 0
        var error = [CChar](repeating: 0, count: 256)
        let status = wuji_ish_configure_stage_d_system_resolver(
            &nameserverCount,
            &searchDomainCount,
            &configurationBytes,
            &configurationCount,
            &error,
            error.count
        )
        guard status == 0 else { return nil }
        return StageDSystemResolverEvidence(
            nameserverCount: nameserverCount,
            searchDomainCount: searchDomainCount,
            configurationBytes: configurationBytes,
            configurationCount: configurationCount
        )
    }

    init(
        rootFSURL: URL,
        workspace: StageBReadyWorkspace,
        cloneRootURL: URL,
        limits: StageDLimits = .production,
        resolverConfigurator: (@Sendable () -> StageDSystemResolverEvidence?)? = nil
    ) {
        self.rootFSURL = rootFSURL
        self.workspace = workspace
        self.cloneRootURL = cloneRootURL
        self.limits = limits
        self.resolverConfigurator = resolverConfigurator ?? Self.productionResolverConfigurator
    }

    static func bundled(
        workspace: StageBReadyWorkspace,
        cloneRootURL: URL,
        limits: StageDLimits = .production,
        resolverConfigurator: (@Sendable () -> StageDSystemResolverEvidence?)? = nil
    ) throws -> ISHStageDCommandExecutor {
        guard let rootFSURL = Bundle.main.url(forResource: "rootfs", withExtension: "tar.gz") else {
            throw StageDCommandError.executorFailure
        }
        return ISHStageDCommandExecutor(
            rootFSURL: rootFSURL,
            workspace: workspace,
            cloneRootURL: cloneRootURL,
            limits: limits,
            resolverConfigurator: resolverConfigurator
        )
    }

    func systemResolverEvidence() -> StageDSystemResolverEvidence? {
        preparationLock.lock()
        defer { preparationLock.unlock() }
        return resolverEvidence
    }

    func execute(_ command: StageDAuthorizedCommand) async -> StageDExecutorOutcome {
        guard command.workspaceIdentitySHA256 == workspace.identitySHA256,
              command.parsed.bindingSHA256 == command.bindingSHA256 || !command.bindingSHA256.isEmpty else {
            return .failed(nil)
        }
        do {
            try prepareIfNeeded()
            try preflight(command)
            switch command.risk {
            case .network:
                return try await executeClone(command)
            case .installation:
                return try await executeInstallation(command)
            case .workspaceWrite:
                return try await executeWrite(command)
            case .safeReadOnly:
                return try await executeSimple(command)
            case .delete, .overwrite, .boundaryCrossing, .unavailable, .unsupported:
                return .failed(nil)
            }
        } catch StageDCommandError.reconciliationRequired {
            return .unknown(nil)
        } catch {
            return .failed(nil)
        }
    }

    private func prepareIfNeeded() throws {
        preparationLock.lock()
        defer { preparationLock.unlock() }
        if prepared { return }
        let data = try Data(contentsOf: rootFSURL, options: .mappedIfSafe)
        guard data.count == StageDEnvironmentLock.rootFSSize,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined()
                == StageDEnvironmentLock.rootFSSHA256 else {
            throw StageDCommandError.executorFailure
        }
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let rootURL = support.appendingPathComponent("WujiS1Root", isDirectory: true)
        try FileManager.default.createDirectory(at: cloneRootURL, withIntermediateDirectories: true)
        var error = [CChar](repeating: 0, count: 512)
        let prepareStatus = rootFSURL.path.withCString { archive in
            rootURL.path.withCString { root in wuji_ish_prepare(archive, root, &error, error.count) }
        }
        guard prepareStatus == 0 else { throw StageDCommandError.executorFailure }
        guard let resolverEvidence = resolverConfigurator(),
              resolverEvidence.nameserverCount > 0,
              resolverEvidence.nameserverCount <= 32,
              resolverEvidence.searchDomainCount <= 7,
              resolverEvidence.configurationBytes > 0,
              resolverEvidence.configurationBytes < 4096,
              resolverEvidence.configurationCount > 0 else {
            throw StageDCommandError.executorFailure
        }
        self.resolverEvidence = resolverEvidence
        error = [CChar](repeating: 0, count: 512)
        let workspaceStatus = workspace.canonicalRootURL.path.withCString {
            wuji_ish_mount_stage_d_workspace($0, &error, error.count)
        }
        guard workspaceStatus == 0 else { throw StageDCommandError.executorFailure }
        error = [CChar](repeating: 0, count: 512)
        let cloneStatus = cloneRootURL.path.withCString {
            wuji_ish_mount_stage_d_clone_root($0, &error, error.count)
        }
        guard cloneStatus == 0 else { throw StageDCommandError.executorFailure }
        prepared = true
    }

    private func preflight(_ command: StageDAuthorizedCommand) throws {
        let expectedRoot: URL
        switch command.executionRoot {
        case .workspace: expectedRoot = workspace.canonicalRootURL
        case .cloneRoot: expectedRoot = cloneRootURL
        case .rootfs: return
        }
        let cwdURL = command.parsed.cwd.isEmpty
            ? expectedRoot
            : expectedRoot.appendingPathComponent(command.parsed.cwd, isDirectory: true)
        let canonicalRoot = expectedRoot.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalCWD = cwdURL.standardizedFileURL.resolvingSymlinksInPath()
        guard contained(canonicalCWD, in: canonicalRoot),
              (try canonicalCWD.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).isDirectory == true,
              (try canonicalCWD.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
            throw StageDCommandError.boundaryCrossing
        }
        if let write = command.write {
            let target = canonicalRoot.appendingPathComponent(write.relativePath).standardizedFileURL
            let resolved = target.resolvingSymlinksInPath()
            let values = try target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard contained(resolved, in: canonicalRoot),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else { throw StageDCommandError.boundaryCrossing }
        }
        if command.risk == .network, let target = command.cloneTarget {
            let destination = canonicalRoot.appendingPathComponent(target, isDirectory: true)
            guard contained(destination.standardizedFileURL, in: canonicalRoot),
                  !FileManager.default.fileExists(atPath: destination.path) else {
                throw StageDCommandError.invalidClone
            }
        }
    }

    private func executeSimple(_ command: StageDAuthorizedCommand) async throws -> StageDExecutorOutcome {
        let step = try await run(
            executable: command.parsed.executable,
            arguments: command.parsed.arguments,
            cwd: command.parsed.cwd,
            root: command.executionRoot,
            timeout: limits.commandTimeoutSeconds
        )
        let output = step.stdout.isEmpty ? step.stderr : step.stdout
        let versions = versionEvidence(command: command, output: output)
        let verification = "command=\(command.bindingSHA256) exit=\(step.facts.finalStateValue)"
        let result = makeResult(
            command: command,
            steps: [step],
            stdout: step.stdout,
            stderr: step.stderr,
            verification: verification,
            toolVersions: versions
        )
        return result.verified ? .succeeded(result) : outcomeForUnverified(result)
    }

    private func executeWrite(_ command: StageDAuthorizedCommand) async throws -> StageDExecutorOutcome {
        guard let write = command.write else { return .failed(nil) }
        let target = workspace.canonicalRootURL.appendingPathComponent(write.relativePath)
        let before = try Data(contentsOf: target, options: .mappedIfSafe)
        guard ProviderDigest.sha256Hex(before) == write.expectedBeforeSHA256,
              String(data: before, encoding: .utf8)?.split(separator: "\n", omittingEmptySubsequences: false)
                .filter({ String($0) == write.expectedBeforeLine }).count == 1 else {
            return .failed(nil)
        }
        let step = try await run(
            executable: command.parsed.executable,
            arguments: command.parsed.arguments,
            cwd: command.parsed.cwd,
            root: .workspace,
            timeout: limits.commandTimeoutSeconds
        )
        let after = try Data(contentsOf: target, options: .mappedIfSafe)
        let workspaceSize = try boundedTree(at: workspace.canonicalRootURL, entryLimit: 50_000)
        let verified = ProviderDigest.sha256Hex(after) == write.expectedAfterSHA256
            && workspaceSize.bytes <= limits.maximumWorkspaceBytes
        let verification = "path=\(write.relativePath) before=\(write.expectedBeforeSHA256) after=\(ProviderDigest.sha256Hex(after))"
        let result = makeResult(
            command: command,
            steps: [step],
            stdout: step.stdout,
            stderr: step.stderr,
            verification: verification
        )
        return verified && result.verified ? .succeeded(result) : outcomeForUnverified(result)
    }

    private func executeInstallation(_ command: StageDAuthorizedCommand) async throws -> StageDExecutorOutcome {
        let expectedRepositories = StageDEnvironmentLock.repositories.joined(separator: "\n") + "\n"
        let before = try await run(
            executable: "cat", arguments: ["--", "/etc/apk/repositories"],
            cwd: "", root: .rootfs, timeout: limits.commandTimeoutSeconds
        )
        guard before.stdout == expectedRepositories else { return .failed(nil) }
        let install = try await run(
            executable: command.parsed.executable,
            arguments: command.parsed.arguments,
            cwd: "", root: .rootfs,
            timeout: limits.maximumCloneSeconds
        )
        let after = try await run(
            executable: "cat", arguments: ["--", "/etc/apk/repositories"],
            cwd: "", root: .rootfs, timeout: limits.commandTimeoutSeconds
        )
        guard after.stdout == expectedRepositories else { return .failed(nil) }
        let policy = try await run(
            executable: "apk", arguments: ["policy"] + StageDEnvironmentLock.packages,
            cwd: "", root: .rootfs, timeout: limits.commandTimeoutSeconds
        )
        let versions = parseAPKPolicy(policy.stdout)
        guard Set(versions.keys) == Set(StageDEnvironmentLock.packages) else { return .failed(nil) }
        let verification = "repositories=\(ProviderDigest.sha256Hex(after.stdout)) packages=\(versions.keys.sorted().joined(separator: ","))"
        let result = makeResult(
            command: command,
            steps: [before, install, after, policy],
            stdout: install.stdout + policy.stdout,
            stderr: install.stderr + policy.stderr,
            verification: verification,
            toolVersions: versions
        )
        return result.verified ? .succeeded(result) : outcomeForUnverified(result)
    }

    private func executeClone(_ command: StageDAuthorizedCommand) async throws -> StageDExecutorOutcome {
        guard command.parsed.arguments == [
            "clone", "--depth", "8", "--no-tags", "--single-branch",
            StageDEnvironmentLock.cloneURL, StageDEnvironmentLock.cloneTarget
        ], command.cloneTarget == StageDEnvironmentLock.cloneTarget else { return .failed(nil) }
        let clone = try await run(
            executable: "git", arguments: command.parsed.arguments,
            cwd: "", root: .cloneRoot, timeout: limits.maximumCloneSeconds
        )
        let checkout = try await run(
            executable: "git",
            arguments: ["checkout", "--detach", StageDEnvironmentLock.acceptedStageCCommit],
            cwd: StageDEnvironmentLock.cloneTarget,
            root: .cloneRoot,
            timeout: limits.commandTimeoutSeconds
        )
        let remote = try await run(
            executable: "git", arguments: ["remote", "get-url", "origin"],
            cwd: StageDEnvironmentLock.cloneTarget, root: .cloneRoot,
            timeout: limits.commandTimeoutSeconds
        )
        let head = try await run(
            executable: "git", arguments: ["rev-parse", "HEAD"],
            cwd: StageDEnvironmentLock.cloneTarget, root: .cloneRoot,
            timeout: limits.commandTimeoutSeconds
        )
        let remoteValue = remote.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let headValue = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = cloneRootURL.appendingPathComponent(StageDEnvironmentLock.cloneTarget, isDirectory: true)
        let tree = try boundedTree(at: target, entryLimit: limits.maximumCloneEntries)
        let noSubmoduleCheckout = !FileManager.default.fileExists(
            atPath: target.appendingPathComponent(".git/modules").path
        ) && !FileManager.default.fileExists(
            atPath: target.appendingPathComponent("ThirdParty/ish/.git").path
        )
        let verification = "remote=\(remoteValue) head=\(headValue) entries=\(tree.entries) bytes=\(tree.bytes)"
        let result = makeResult(
            command: command,
            steps: [clone, checkout, remote, head],
            stdout: clone.stdout + checkout.stdout + remote.stdout + head.stdout,
            stderr: clone.stderr + checkout.stderr + remote.stderr + head.stderr,
            verification: verification,
            cloneRemote: remoteValue,
            cloneHEAD: headValue,
            cloneEntryCount: tree.entries,
            cloneByteCount: tree.bytes
        )
        let verified = remoteValue == StageDEnvironmentLock.cloneURL
            && headValue == StageDEnvironmentLock.acceptedStageCCommit
            && tree.entries <= limits.maximumCloneEntries
            && tree.bytes <= limits.maximumCloneBytes
            && noSubmoduleCheckout
        return verified && result.verified ? .succeeded(result) : outcomeForUnverified(result)
    }

    private func run(
        executable: String,
        arguments: [String],
        cwd: String,
        root: StageDExecutionRoot,
        timeout: TimeInterval
    ) async throws -> StageDRawStep {
        var blob = Data()
        for argument in arguments {
            blob.append(contentsOf: argument.utf8)
            blob.append(0)
        }
        let timeoutFlag = StageDTimeoutFlag()
        let execution = Task.detached(priority: .userInitiated) { [limits] in
            let raw = executable.withCString { executablePointer in
                cwd.withCString { cwdPointer in
                    blob.withUnsafeBytes { bytes in
                        wuji_ish_run_stage_d_command(
                            executablePointer,
                            bytes.bindMemory(to: UInt8.self).baseAddress,
                            blob.count,
                            numericCast(arguments.count),
                            cwdPointer,
                            Self.cRoot(root),
                            numericCast(max(limits.maximumStdoutBytes, limits.maximumStderrBytes))
                        )
                    }
                }
            }
            guard let raw else { throw StageDCommandError.executorFailure }
            defer { wuji_ish_result_free(raw) }
            return try Self.step(raw, limits: limits, timeoutRequested: timeoutFlag.snapshot())
        }
        let watchdog = Task.detached {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            timeoutFlag.mark()
            _ = wuji_ish_request_cancel()
        }
        do {
            let value = try await execution.value
            watchdog.cancel()
            if timeoutFlag.snapshot() { throw StageDCommandError.reconciliationRequired }
            return value
        } catch {
            watchdog.cancel()
            throw error
        }
    }

    private static func cRoot(_ root: StageDExecutionRoot) -> WujiISHStageDRoot {
        switch root {
        case .workspace: return WUJI_ISH_STAGE_D_WORKSPACE
        case .cloneRoot: return WUJI_ISH_STAGE_D_CLONE_ROOT
        case .rootfs: return WUJI_ISH_STAGE_D_ROOTFS
        }
    }

    private static func step(
        _ raw: OpaquePointer,
        limits: StageDLimits,
        timeoutRequested: Bool
    ) throws -> StageDRawStep {
        let stdoutCount = Int(wuji_ish_result_stdout_length(raw))
        let stderrCount = Int(wuji_ish_result_stderr_length(raw))
        guard stdoutCount <= limits.maximumStdoutBytes,
              stderrCount <= limits.maximumStderrBytes else {
            throw StageDCommandError.executorFailure
        }
        let stdoutData = Data(bytes: wuji_ish_result_stdout(raw), count: stdoutCount)
        let stderrData = Data(bytes: wuji_ish_result_stderr(raw), count: stderrCount)
        guard !stdoutData.contains(0), !stderrData.contains(0),
              let stdout = String(data: stdoutData, encoding: .utf8),
              let stderr = String(data: stderrData, encoding: .utf8) else {
            throw StageDCommandError.executorFailure
        }
        let finalKind: String
        switch wuji_ish_result_final_kind(raw) {
        case WUJI_ISH_FINAL_EXITED: finalKind = "exited"
        case WUJI_ISH_FINAL_SIGNALED: finalKind = "signaled"
        default: finalKind = "unknown"
        }
        let treeState: StageDProcessTreeState
        switch wuji_ish_result_process_tree_kind(raw) {
        case WUJI_ISH_PROCESS_TREE_QUIESCENT: treeState = .quiescent
        case WUJI_ISH_PROCESS_TREE_DESCENDANTS_REMAIN: treeState = .descendantsRemain
        default: treeState = .notObserved
        }
        let facts = StageDProcessFacts(
            rootExitObserved: wuji_ish_result_root_exited(raw),
            finalStateKind: finalKind,
            finalStateValue: wuji_ish_result_final_value(raw),
            stdoutEOFObserved: wuji_ish_result_stdout_eof(raw),
            stderrEOFObserved: wuji_ish_result_stderr_eof(raw),
            stdoutByteCount: stdoutCount,
            stderrByteCount: stderrCount,
            stdoutSHA256: ProviderDigest.sha256Hex(stdoutData),
            stderrSHA256: ProviderDigest.sha256Hex(stderrData),
            truncated: wuji_ish_result_truncated(raw),
            cancellationRequested: timeoutRequested || wuji_ish_result_cancellation_requested(raw),
            processTreeState: treeState,
            activeDescendantCount: Int(wuji_ish_result_active_descendant_count(raw))
        )
        return .init(facts: facts, stdout: stdout, stderr: stderr)
    }

    private func makeResult(
        command: StageDAuthorizedCommand,
        steps: [StageDRawStep],
        stdout: String,
        stderr: String,
        verification: String,
        cloneRemote: String? = nil,
        cloneHEAD: String? = nil,
        cloneEntryCount: Int? = nil,
        cloneByteCount: UInt64? = nil,
        toolVersions: [String: String] = [:]
    ) -> StageDCommandResult {
        let stdoutData = Data(stdout.utf8)
        let stderrData = Data(stderr.utf8)
        let projectionTruncated = stdoutData.count > limits.maximumStdoutBytes
            || stderrData.count > limits.maximumStderrBytes
        return .init(
            commandBindingSHA256: command.bindingSHA256,
            facts: steps.map(\.facts),
            stdout: String(decoding: stdoutData.prefix(limits.maximumStdoutBytes), as: UTF8.self),
            stderr: String(decoding: stderrData.prefix(limits.maximumStderrBytes), as: UTF8.self),
            outputProjectionTruncated: projectionTruncated,
            verification: verification,
            verificationSHA256: ProviderDigest.sha256Hex(verification),
            cloneRemote: cloneRemote,
            cloneHEAD: cloneHEAD,
            cloneEntryCount: cloneEntryCount,
            cloneByteCount: cloneByteCount,
            toolVersions: toolVersions
        )
    }

    private func outcomeForUnverified(_ result: StageDCommandResult) -> StageDExecutorOutcome {
        result.facts.contains(where: {
            !$0.rootExitObserved || $0.finalStateKind == "unknown" || $0.cancellationRequested
                || $0.processTreeState != .quiescent
        }) ? .unknown(result) : .failed(result)
    }

    private func versionEvidence(command: StageDAuthorizedCommand, output: String) -> [String: String] {
        guard ["git", "python3", "node", "npm"].contains(command.parsed.executable),
              command.parsed.arguments.contains(where: { $0 == "--version" || $0 == "-V" }) else {
            return [:]
        }
        return [command.parsed.executable: output.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    private func parseAPKPolicy(_ output: String) -> [String: String] {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var versions: [String: String] = [:]
        for index in lines.indices where lines[index].hasSuffix(" policy:") {
            let package = String(lines[index].dropLast(" policy:".count))
            guard StageDEnvironmentLock.packages.contains(package) else { continue }
            for next in lines.index(after: index)..<lines.endIndex {
                let trimmed = lines[next].trimmingCharacters(in: .whitespaces)
                if trimmed.hasSuffix(":"), !trimmed.contains(" ") {
                    versions[package] = String(trimmed.dropLast())
                    break
                }
                if lines[next].hasSuffix(" policy:") { break }
            }
        }
        return versions
    }

    private func boundedTree(at root: URL, entryLimit: Int) throws -> (entries: Int, bytes: UInt64) {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in false }
        ) else { throw StageDCommandError.verificationFailure }
        var entries = 0
        var bytes: UInt64 = 0
        while let url = enumerator.nextObject() as? URL {
            entries += 1
            guard entries <= entryLimit else { throw StageDCommandError.verificationFailure }
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else { throw StageDCommandError.boundaryCrossing }
            if values.isRegularFile == true {
                bytes += UInt64(values.fileSize ?? 0)
                guard bytes <= max(limits.maximumCloneBytes, limits.maximumWorkspaceBytes) else {
                    throw StageDCommandError.verificationFailure
                }
            }
        }
        return (entries, bytes)
    }

    private func contained(_ candidate: URL, in root: URL) -> Bool {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return candidate.path == root.path || candidate.path.hasPrefix(rootPath)
    }
}
