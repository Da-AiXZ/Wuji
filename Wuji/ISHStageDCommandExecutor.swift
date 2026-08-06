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

struct StageDRawStep: Sendable {
    let facts: StageDProcessFacts
    let stdout: String
    let stderr: String
    let fixedError: StageDAdapterErrorCategory

    init(
        facts: StageDProcessFacts,
        stdout: String,
        stderr: String,
        fixedError: StageDAdapterErrorCategory = .none
    ) {
        self.facts = facts
        self.stdout = stdout
        self.stderr = stderr
        self.fixedError = fixedError
    }
}

enum StageDCloneStepResult: Sendable {
    case succeeded(StageDRawStep)
    case failed(StageDRawStep?, fixedError: StageDAdapterErrorCategory)
    case unknown(StageDRawStep?, fixedError: StageDAdapterErrorCategory)
}

enum StageDCloneTreeResult: Equatable, Sendable {
    case succeeded(entries: Int, bytes: UInt64)
    case overflow(entries: Int)
    case escape
}

struct StageDClonePipelineResult: Sendable {
    let stages: [StageDCloneStageOutcome]
    let steps: [StageDRawStep]
    let remote: String?
    let head: String?
    let entryCount: Int?
    let byteCount: UInt64?
    let failureCategory: StageDRuntimeFailureCategory?
    let unknown: Bool

    var succeeded: Bool {
        failureCategory == nil && stages.allSatisfy { $0.category == .succeeded }
    }
}

enum StageDClonePipeline {
    static func run(
        command: StageDAuthorizedCommand,
        limits: StageDLimits,
        step: @escaping @Sendable (StageDCloneStage) async -> StageDCloneStepResult,
        inspectTree: @escaping @Sendable () async -> StageDCloneTreeResult
    ) async -> StageDClonePipelineResult {
        let exactArguments = [
            "clone", "--depth", "8", "--no-tags", "--single-branch",
            StageDEnvironmentLock.cloneURL, StageDEnvironmentLock.cloneTarget,
        ]
        guard command.risk == .network,
              command.executionRoot == .cloneRoot,
              command.parsed.executable == "git",
              command.parsed.arguments == exactArguments,
              command.parsed.cwd.isEmpty,
              command.cloneTarget == StageDEnvironmentLock.cloneTarget,
              limits.maximumCloneEntries > 0,
              limits.maximumCloneBytes > 0 else {
            return .init(
                stages: StageDCloneStage.allCases.map { .notRun(stage: $0) },
                steps: [], remote: nil, head: nil, entryCount: nil, byteCount: nil,
                failureCategory: .authorizationRejected, unknown: false
            )
        }
        var outcomes: [StageDCloneStageOutcome] = []
        var steps: [StageDRawStep] = []
        var remote: String?
        var head: String?
        var entryCount: Int?
        var byteCount: UInt64?

        func completed(
            failure: StageDRuntimeFailureCategory?,
            unknown: Bool = false
        ) -> StageDClonePipelineResult {
            let recorded = Set(outcomes.map(\.stage))
            outcomes.append(contentsOf: StageDCloneStage.allCases.compactMap {
                recorded.contains($0) ? nil : .notRun(stage: $0)
            })
            return .init(
                stages: outcomes,
                steps: steps,
                remote: remote,
                head: head,
                entryCount: entryCount,
                byteCount: byteCount,
                failureCategory: failure,
                unknown: unknown
            )
        }

        for stage in StageDCloneStage.allCases.dropLast() {
            let result = await step(stage)
            switch result {
            case let .succeeded(raw):
                steps.append(raw)
                if raw.fixedError != .none {
                    outcomes.append(stageOutcome(
                        stage: stage, category: .adapterError, raw: raw,
                        fixedError: raw.fixedError
                    ))
                    return completed(failure: .adapterFixedError)
                }
                guard raw.facts.terminalBarrierSatisfied,
                      raw.facts.processTreeObservedAfterTerminalBarrier,
                      !raw.facts.truncated,
                      raw.facts.processTreeState == .quiescent,
                      raw.facts.activeDescendantCount == 0 else {
                    outcomes.append(stageOutcome(
                        stage: stage, category: .terminalBarrierFailure, raw: raw
                    ))
                    return completed(failure: .eofTruncationProcessTreeFailure)
                }
                guard raw.facts.finalStateKind == "exited", raw.facts.finalStateValue == 0 else {
                    let (category, failure) = nonzeroClassification(stage: stage, raw: raw)
                    outcomes.append(stageOutcome(stage: stage, category: category, raw: raw))
                    return completed(failure: failure)
                }
                if stage == .remoteVerify {
                    let value = raw.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard value == StageDEnvironmentLock.cloneURL else {
                        outcomes.append(stageOutcome(
                            stage: stage, category: .valueMismatch, raw: raw,
                            observedValueSHA256: ProviderDigest.sha256Hex(value)
                        ))
                        return completed(failure: .remoteMismatch)
                    }
                    remote = StageDEnvironmentLock.cloneURL
                }
                if stage == .headVerify {
                    let value = raw.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard value == StageDEnvironmentLock.acceptedStageCCommit else {
                        outcomes.append(stageOutcome(
                            stage: stage, category: .valueMismatch, raw: raw,
                            observedValueSHA256: ProviderDigest.sha256Hex(value)
                        ))
                        return completed(failure: .headMismatch)
                    }
                    head = StageDEnvironmentLock.acceptedStageCCommit
                }
                outcomes.append(stageOutcome(stage: stage, category: .succeeded, raw: raw))
            case let .failed(raw, fixedError):
                if let raw { steps.append(raw) }
                let adapterError = fixedError != .none || (raw.map { $0.fixedError != .none } ?? false)
                if adapterError {
                    outcomes.append(stageOutcome(
                        stage: stage, category: .adapterError, raw: raw,
                        fixedError: fixedError == .none ? raw?.fixedError ?? .internalFailure : fixedError
                    ))
                    return completed(failure: .adapterFixedError)
                }
                let (category, failure) = nonzeroClassification(stage: stage, raw: raw)
                outcomes.append(stageOutcome(stage: stage, category: category, raw: raw))
                return completed(failure: failure)
            case let .unknown(raw, fixedError):
                if let raw { steps.append(raw) }
                outcomes.append(stageOutcome(
                    stage: stage,
                    category: fixedError == .none ? .timeoutUnknown : .adapterError,
                    raw: raw,
                    fixedError: fixedError
                ))
                return completed(
                    failure: fixedError == .none ? .cloneTimeoutUnknown : .adapterFixedError,
                    unknown: true
                )
            }
        }

        switch await inspectTree() {
        case let .succeeded(entries, bytes):
            entryCount = entries
            byteCount = bytes
            outcomes.append(treeOutcome(category: .succeeded, entries: entries, bytes: bytes))
            return completed(failure: nil)
        case let .overflow(entries):
            outcomes.append(treeOutcome(category: .treeOverflow, entries: entries, bytes: nil))
            return completed(failure: .treeOverflow)
        case .escape:
            outcomes.append(treeOutcome(category: .treeEscape, entries: nil, bytes: nil))
            return completed(failure: .treeEscape)
        }
    }

    private static func stageOutcome(
        stage: StageDCloneStage,
        category: StageDCloneStageCategory,
        raw: StageDRawStep?,
        fixedError: StageDAdapterErrorCategory = .none,
        observedValueSHA256: String? = nil
    ) -> StageDCloneStageOutcome {
        .init(
            stage: stage,
            category: category,
            processStarted: raw != nil,
            facts: raw?.facts ?? .notRun,
            adapterError: fixedError == .none ? raw?.fixedError ?? .none : fixedError,
            observedValueSHA256: observedValueSHA256,
            entryCount: nil,
            byteCount: nil
        )
    }

    private static func nonzeroClassification(
        stage: StageDCloneStage,
        raw: StageDRawStep?
    ) -> (StageDCloneStageCategory, StageDRuntimeFailureCategory) {
        if stage == .checkoutExactCommit {
            return (.targetUnavailable, .checkoutTargetUnavailable)
        }
        if stage == .cloneProcess, let raw {
            let category = safeCloneProcessCategory(raw.stderr)
            if category == .resolverNetworkFailure {
                return (category, .resolverNetworkFailure)
            }
            return (category, .cloneProcessNonzero)
        }
        return (.processNonzero, .cloneProcessNonzero)
    }

    private static func safeCloneProcessCategory(_ stderr: String) -> StageDCloneStageCategory {
        let value = stderr.lowercased()
        let categories: [(StageDCloneStageCategory, [String])] = [
            (.resolverNetworkFailure, [
                "could not resolve", "couldn't resolve", "getaddrinfo",
                "failed to connect", "connection timed out", "connection refused",
                "connection reset", "network is unreachable", "ssl", "tls",
                "gnutls", "curl 6", "curl 7", "curl 28", "curl 35", "curl 56",
                "curl 92", "http/2 stream", "remote end hung up",
            ]),
            (.capabilityUnavailable, [
                "unable to find remote helper", "remote-https is not a git command",
                "not a git command",
            ]),
            (.remoteAccessFailure, [
                "repository not found", "authentication failed", "could not read username",
                "requested url returned error",
            ]),
            (.checkoutWorktreeFailure, [
                "unable to checkout working tree", "checkout failed", "invalid path",
            ]),
            (.filesystemFailure, [
                "operation not permitted", "permission denied", "read-only file system",
                "file name too long", "could not set 'core.filemode'", "chmod on",
                "unable to create", "could not create", "cannot create",
                "destination path",
            ]),
            (.protocolFailure, [
                "rpc failed", "early eof", "invalid index-pack", "unexpected disconnect",
                "protocol error", "bad pack header",
            ]),
        ]
        return categories.first(where: { category in
            category.1.contains { value.contains($0) }
        })?.0 ?? .processNonzero
    }

    private static func treeOutcome(
        category: StageDCloneStageCategory,
        entries: Int?,
        bytes: UInt64?
    ) -> StageDCloneStageOutcome {
        .init(
            stage: .boundedTreeVerify,
            category: category,
            processStarted: false,
            facts: .notRun,
            adapterError: .none,
            observedValueSHA256: nil,
            entryCount: entries,
            byteCount: bytes
        )
    }
}

actor StageDGlobalExecutionGate {
    static let shared = StageDGlobalExecutionGate()
    private var active: UUID?
    private var waiters: [(UUID, CheckedContinuation<Void, Never>)] = []

    func acquire(_ operationID: UUID) async {
        if active == nil {
            active = operationID
            return
        }
        await withCheckedContinuation { waiters.append((operationID, $0)) }
    }

    func release(_ operationID: UUID) {
        guard active == operationID else { return }
        if waiters.isEmpty {
            active = nil
            return
        }
        let next = waiters.removeFirst()
        active = next.0
        next.1.resume()
    }

    func isActive(_ operationID: UUID) -> Bool { active == operationID }
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

    func execute(
        _ command: StageDAuthorizedCommand,
        policy: StageDCommandPolicy
    ) async -> StageDExecutorOutcome {
        guard command.workspaceIdentitySHA256 == workspace.identitySHA256,
              Self.revalidates(command, using: policy) else {
            return .failed(failureResult(command: command, category: .authorizationRejected))
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
        } catch StageDCommandError.resolverNetworkFailure {
            return .failed(failureResult(command: command, category: .resolverNetworkFailure))
        } catch StageDCommandError.boundaryCrossing,
                StageDCommandError.invalidCWD,
                StageDCommandError.invalidClone {
            return .failed(failureResult(command: command, category: .authorizationRejected))
        } catch {
            return .failed(nil)
        }
    }

    static func revalidates(
        _ command: StageDAuthorizedCommand,
        using policy: StageDCommandPolicy
    ) -> Bool {
        guard command.workspaceIdentitySHA256 == policy.workspaceIdentitySHA256 else { return false }
        guard case let .authorized(expected) = policy.decide(
            command: command.parsed.original,
            cwd: command.parsed.cwd.isEmpty ? "." : command.parsed.cwd
        ) else { return false }
        return expected == command
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
            throw StageDCommandError.resolverNetworkFailure
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
        let target = cloneRootURL.appendingPathComponent(StageDEnvironmentLock.cloneTarget, isDirectory: true)
        let pipeline = await StageDClonePipeline.run(
            command: command,
            limits: limits,
            step: { [self] stage in await cloneStep(stage, command: command) },
            inspectTree: { [self] in inspectCloneTree(at: target) }
        )
        let categories = pipeline.stages.map { $0.stage.rawValue + "=" + $0.category.rawValue }
            .joined(separator: ",")
        let verification = "clone_stages=\(ProviderDigest.sha256Hex(categories))"
        let result = makeResult(
            command: command,
            steps: pipeline.steps,
            stdout: "",
            stderr: "",
            verification: verification,
            cloneRemote: pipeline.remote,
            cloneHEAD: pipeline.head,
            cloneEntryCount: pipeline.entryCount,
            cloneByteCount: pipeline.byteCount,
            cloneStages: pipeline.stages,
            failureCategory: pipeline.failureCategory
        )
        if pipeline.succeeded && result.verified { return .succeeded(result) }
        return pipeline.unknown ? .unknown(result) : .failed(result)
    }

    private func cloneStep(
        _ stage: StageDCloneStage,
        command: StageDAuthorizedCommand
    ) async -> StageDCloneStepResult {
        let executable = "git"
        let arguments: [String]
        let cwd: String
        let timeout: TimeInterval
        switch stage {
        case .cloneProcess:
            arguments = command.parsed.arguments
            cwd = ""
            timeout = limits.maximumCloneSeconds
        case .checkoutExactCommit:
            arguments = ["checkout", "--detach", StageDEnvironmentLock.acceptedStageCCommit]
            cwd = StageDEnvironmentLock.cloneTarget
            timeout = limits.commandTimeoutSeconds
        case .remoteVerify:
            arguments = ["remote", "get-url", "origin"]
            cwd = StageDEnvironmentLock.cloneTarget
            timeout = limits.commandTimeoutSeconds
        case .headVerify:
            arguments = ["rev-parse", "HEAD"]
            cwd = StageDEnvironmentLock.cloneTarget
            timeout = limits.commandTimeoutSeconds
        case .boundedTreeVerify:
            return .failed(nil, fixedError: .invalidInput)
        }
        do {
            let raw = try await run(
                executable: executable,
                arguments: arguments,
                cwd: cwd,
                root: .cloneRoot,
                timeout: timeout
            )
            if raw.fixedError != .none { return .failed(raw, fixedError: raw.fixedError) }
            if raw.facts.cancellationRequested || raw.facts.finalStateKind == "unknown" {
                return .unknown(raw, fixedError: .none)
            }
            return .succeeded(raw)
        } catch {
            return .failed(nil, fixedError: .internalFailure)
        }
    }

    private func inspectCloneTree(at root: URL) -> StageDCloneTreeResult {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in false }
        ) else { return .escape }
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        var entries = 0
        var bytes: UInt64 = 0
        while let url = enumerator.nextObject() as? URL {
            entries += 1
            guard entries <= limits.maximumCloneEntries else { return .overflow(entries: entries) }
            guard contained(url.standardizedFileURL.resolvingSymlinksInPath(), in: canonicalRoot),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isSymbolicLink != true else { return .escape }
            if values.isRegularFile == true {
                bytes += UInt64(values.fileSize ?? 0)
                guard bytes <= limits.maximumCloneBytes else { return .overflow(entries: entries) }
            }
        }
        guard !FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/modules").path),
              !FileManager.default.fileExists(atPath: root.appendingPathComponent("ThirdParty/ish/.git").path) else {
            return .escape
        }
        return .succeeded(entries: entries, bytes: bytes)
    }

    private func run(
        executable: String,
        arguments: [String],
        cwd: String,
        root: StageDExecutionRoot,
        timeout: TimeInterval
    ) async throws -> StageDRawStep {
        let leaseID = UUID()
        await StageDGlobalExecutionGate.shared.acquire(leaseID)
        if Task.isCancelled {
            await StageDGlobalExecutionGate.shared.release(leaseID)
            throw StageDCommandError.reconciliationRequired
        }
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
            guard await StageDGlobalExecutionGate.shared.isActive(leaseID) else { return }
            timeoutFlag.mark()
            _ = wuji_ish_request_cancel()
        }
        do {
            let value = try await execution.value
            watchdog.cancel()
            await StageDGlobalExecutionGate.shared.release(leaseID)
            return value
        } catch {
            watchdog.cancel()
            await StageDGlobalExecutionGate.shared.release(leaseID)
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
            cancelDelivery: cancelDelivery(raw),
            processTreeState: treeState,
            activeDescendantCount: Int(wuji_ish_result_active_descendant_count(raw)),
            processTreeObservedAfterTerminalBarrier:
                wuji_ish_result_process_tree_observed_after_terminal_barrier(raw)
        )
        return .init(
            facts: facts,
            stdout: stdout,
            stderr: stderr,
            fixedError: fixedError(raw)
        )
    }

    private static func cancelDelivery(_ raw: OpaquePointer) -> StageDCancelDelivery {
        switch wuji_ish_result_cancel_delivery(raw) {
        case WUJI_ISH_CANCEL_NOT_REQUESTED: return .notRequested
        case WUJI_ISH_CANCEL_SIGNAL_SENT: return .signalSent
        case WUJI_ISH_CANCEL_NO_ACTIVE_TASK: return .noActiveTask
        default: return .unknown
        }
    }

    private static func fixedError(_ raw: OpaquePointer) -> StageDAdapterErrorCategory {
        switch wuji_ish_result_fixed_error_kind(raw) {
        case WUJI_ISH_FIXED_ERROR_NONE: return .none
        case WUJI_ISH_FIXED_ERROR_INVALID_INPUT: return .invalidInput
        case WUJI_ISH_FIXED_ERROR_NOT_PREPARED: return .notPrepared
        case WUJI_ISH_FIXED_ERROR_HOST_PIPE: return .hostPipe
        case WUJI_ISH_FIXED_ERROR_GUEST_TASK: return .guestTask
        case WUJI_ISH_FIXED_ERROR_GUEST_CWD: return .guestCWD
        case WUJI_ISH_FIXED_ERROR_GUEST_STDIO: return .guestStdio
        case WUJI_ISH_FIXED_ERROR_GUEST_EXEC: return .guestExec
        case WUJI_ISH_FIXED_ERROR_STDOUT_READER: return .stdoutReader
        case WUJI_ISH_FIXED_ERROR_STDERR_READER: return .stderrReader
        default: return .internalFailure
        }
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
        toolVersions: [String: String] = [:],
        cloneStages: [StageDCloneStageOutcome] = [],
        failureCategory: StageDRuntimeFailureCategory? = nil
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
            toolVersions: toolVersions,
            cloneStages: cloneStages,
            failureCategory: failureCategory
        )
    }

    private func failureResult(
        command: StageDAuthorizedCommand,
        category: StageDRuntimeFailureCategory
    ) -> StageDCommandResult {
        makeResult(
            command: command,
            steps: [],
            stdout: "",
            stderr: "",
            verification: "failure_category=\(category.rawValue)",
            failureCategory: category
        )
    }

    private func outcomeForUnverified(_ result: StageDCommandResult) -> StageDExecutorOutcome {
        result.facts.contains(where: {
            !$0.rootExitObserved || $0.finalStateKind == "unknown" || $0.cancellationRequested
                || $0.processTreeState != .quiescent
                || !$0.processTreeObservedAfterTerminalBarrier
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
