import Foundation

struct StageDLimits: Equatable, Sendable {
    let maximumCommandBytes: Int
    let maximumArgumentCount: Int
    let maximumArgumentBytes: Int
    let maximumCWDBytes: Int
    let maximumStdoutBytes: Int
    let maximumStderrBytes: Int
    let maximumDurableEvidenceBytes: Int
    let maximumApprovalSeconds: TimeInterval
    let commandTimeoutSeconds: TimeInterval
    let maximumCloneSeconds: TimeInterval
    let maximumCloneEntries: Int
    let maximumCloneBytes: UInt64
    let maximumWorkspaceBytes: UInt64

    // Injectable Stage D defaults for the current implementation, not permanent product limits.
    static let production = StageDLimits(
        maximumCommandBytes: 2 * 1_024,
        maximumArgumentCount: 16,
        maximumArgumentBytes: 1_024,
        maximumCWDBytes: 1_024,
        maximumStdoutBytes: 64 * 1_024,
        maximumStderrBytes: 64 * 1_024,
        maximumDurableEvidenceBytes: 2 * 1_024 * 1_024,
        maximumApprovalSeconds: 300,
        commandTimeoutSeconds: 120,
        maximumCloneSeconds: 300,
        maximumCloneEntries: 20_000,
        maximumCloneBytes: 512 * 1_024 * 1_024,
        maximumWorkspaceBytes: 2 * 1_024 * 1_024 * 1_024
    )

    init(
        maximumCommandBytes: Int,
        maximumArgumentCount: Int,
        maximumArgumentBytes: Int,
        maximumCWDBytes: Int,
        maximumStdoutBytes: Int,
        maximumStderrBytes: Int,
        maximumDurableEvidenceBytes: Int,
        maximumApprovalSeconds: TimeInterval,
        commandTimeoutSeconds: TimeInterval,
        maximumCloneSeconds: TimeInterval,
        maximumCloneEntries: Int,
        maximumCloneBytes: UInt64,
        maximumWorkspaceBytes: UInt64
    ) {
        precondition([
            maximumCommandBytes, maximumArgumentCount, maximumArgumentBytes,
            maximumCWDBytes, maximumStdoutBytes, maximumStderrBytes,
            maximumDurableEvidenceBytes, maximumCloneEntries
        ].allSatisfy { $0 > 0 })
        precondition(maximumApprovalSeconds > 0 && commandTimeoutSeconds > 0)
        precondition(maximumCloneSeconds > 0 && maximumCloneBytes > 0 && maximumWorkspaceBytes > 0)
        precondition(maximumArgumentCount <= 16)
        precondition(maximumArgumentBytes <= 1_024)
        precondition(maximumCWDBytes <= 1_024)
        precondition(maximumStdoutBytes <= 64 * 1_024 && maximumStderrBytes <= 64 * 1_024)
        self.maximumCommandBytes = maximumCommandBytes
        self.maximumArgumentCount = maximumArgumentCount
        self.maximumArgumentBytes = maximumArgumentBytes
        self.maximumCWDBytes = maximumCWDBytes
        self.maximumStdoutBytes = maximumStdoutBytes
        self.maximumStderrBytes = maximumStderrBytes
        self.maximumDurableEvidenceBytes = maximumDurableEvidenceBytes
        self.maximumApprovalSeconds = maximumApprovalSeconds
        self.commandTimeoutSeconds = commandTimeoutSeconds
        self.maximumCloneSeconds = maximumCloneSeconds
        self.maximumCloneEntries = maximumCloneEntries
        self.maximumCloneBytes = maximumCloneBytes
        self.maximumWorkspaceBytes = maximumWorkspaceBytes
    }
}

enum StageDCommandRisk: String, Codable, Equatable, Hashable, Sendable {
    case safeReadOnly = "safe_read_only"
    case workspaceWrite = "workspace_write"
    case network
    case installation
    case delete
    case overwrite
    case boundaryCrossing = "boundary_crossing"
    case unavailable
    case unsupported

    var requiresApproval: Bool {
        switch self {
        case .workspaceWrite, .network, .installation, .delete, .overwrite, .boundaryCrossing:
            return true
        case .safeReadOnly, .unavailable, .unsupported:
            return false
        }
    }
}

enum StageDExecutionRoot: String, Codable, Equatable, Sendable {
    case workspace
    case cloneRoot = "clone_root"
    case rootfs
}

enum StageDCommandError: String, Error, Codable, Equatable, Sendable {
    case emptyCommand = "empty_command"
    case commandLimit = "command_limit"
    case controlCharacter = "control_character"
    case shellMetacharacter = "shell_metacharacter"
    case ambiguousWhitespace = "ambiguous_whitespace"
    case ambiguousQuoting = "ambiguous_quoting"
    case argumentLimit = "argument_limit"
    case unsupportedExecutable = "unsupported_executable"
    case unsupportedArguments = "unsupported_arguments"
    case unavailableTool = "unavailable_tool"
    case invalidCWD = "invalid_cwd"
    case boundaryCrossing = "boundary_crossing"
    case invalidClone = "invalid_clone"
    case invalidInstall = "invalid_install"
    case writeNotBound = "write_not_bound"
    case destructiveRejected = "destructive_rejected"
    case approvalRequired = "approval_required"
    case approvalRejected = "approval_rejected"
    case approvalExpired = "approval_expired"
    case approvalCancelled = "approval_cancelled"
    case approvalTampered = "approval_tampered"
    case approvalReplayed = "approval_replayed"
    case workspaceBusy = "workspace_busy"
    case evidenceFailure = "evidence_failure"
    case executorFailure = "executor_failure"
    case verificationFailure = "verification_failure"
    case reconciliationRequired = "reconciliation_required"
    case providerFailure = "provider_failure"
    case providerPolicy = "provider_policy"
    case providerBindingMismatch = "provider_binding_mismatch"
    case authorizationRejected = "authorization_rejected"
    case intentStoreFailure = "intent_store_failure"
    case resolverNetworkFailure = "resolver_network_failure"
    case cloneProcessNonzero = "clone_process_nonzero"
    case cloneTimeoutUnknown = "clone_timeout_unknown"
    case checkoutTargetUnavailable = "checkout_target_unavailable"
    case remoteMismatch = "remote_mismatch"
    case headMismatch = "head_mismatch"
    case treeOverflow = "tree_overflow"
    case treeEscape = "tree_escape"
    case terminalBarrierFailure = "terminal_barrier_failure"
    case durableTerminalFailure = "durable_terminal_failure"
    case durableCompletionFailure = "durable_completion_failure"
    case completionRejected = "completion_rejected"
}

struct StageDParsedCommand: Codable, Equatable, Sendable {
    let original: String
    let executable: String
    let arguments: [String]
    let cwd: String

    var bindingSHA256: String {
        ProviderDigest.sha256Hex(
            ([original, executable, cwd] + arguments).joined(separator: "\u{0}")
        )
    }
}

struct StageDBoundedWrite: Codable, Equatable, Sendable {
    let relativePath: String
    let expectedBeforeLine: String
    let replacementLine: String
    let expectedBeforeSHA256: String
    let expectedAfterSHA256: String

    var sedExpression: String {
        "s/\(expectedBeforeLine)/\(replacementLine)/"
    }
}

struct StageDAuthorizedCommand: Codable, Equatable, Sendable {
    let parsed: StageDParsedCommand
    let risk: StageDCommandRisk
    let executionRoot: StageDExecutionRoot
    let workspaceIdentitySHA256: String
    let write: StageDBoundedWrite?
    let cloneTarget: String?

    var bindingSHA256: String {
        ProviderDigest.sha256Hex([
            parsed.bindingSHA256, risk.rawValue, executionRoot.rawValue,
            workspaceIdentitySHA256, write.map { ProviderDigest.sha256Hex(
                [$0.relativePath, $0.expectedBeforeLine, $0.replacementLine,
                 $0.expectedBeforeSHA256, $0.expectedAfterSHA256].joined(separator: "\u{0}"))
            } ?? "", cloneTarget ?? ""
        ].joined(separator: "\u{0}"))
    }
}

enum StageDProcessTreeState: String, Codable, Equatable, Sendable {
    case notObserved = "not_observed"
    case quiescent
    case descendantsRemain = "descendants_remain"
}

enum StageDCancelDelivery: String, Codable, Equatable, Sendable {
    case notRequested = "not_requested"
    case signalSent = "signal_sent"
    case noActiveTask = "no_active_task"
    case unknown
}

struct StageDProcessFacts: Codable, Equatable, Sendable {
    let rootExitObserved: Bool
    let finalStateKind: String
    let finalStateValue: Int32
    let stdoutEOFObserved: Bool
    let stderrEOFObserved: Bool
    let stdoutByteCount: Int
    let stderrByteCount: Int
    let stdoutSHA256: String
    let stderrSHA256: String
    let truncated: Bool
    let cancellationRequested: Bool
    let cancelDelivery: StageDCancelDelivery
    let processTreeState: StageDProcessTreeState
    let initialActiveDescendantCount: Int?
    let activeDescendantCount: Int
    let processTreeObservationCount: Int?
    let processTreeObservedAfterTerminalBarrier: Bool

    init(
        rootExitObserved: Bool,
        finalStateKind: String,
        finalStateValue: Int32,
        stdoutEOFObserved: Bool,
        stderrEOFObserved: Bool,
        stdoutByteCount: Int,
        stderrByteCount: Int,
        stdoutSHA256: String,
        stderrSHA256: String,
        truncated: Bool,
        cancellationRequested: Bool,
        cancelDelivery: StageDCancelDelivery,
        processTreeState: StageDProcessTreeState,
        initialActiveDescendantCount: Int? = nil,
        activeDescendantCount: Int,
        processTreeObservationCount: Int? = nil,
        processTreeObservedAfterTerminalBarrier: Bool
    ) {
        self.rootExitObserved = rootExitObserved
        self.finalStateKind = finalStateKind
        self.finalStateValue = finalStateValue
        self.stdoutEOFObserved = stdoutEOFObserved
        self.stderrEOFObserved = stderrEOFObserved
        self.stdoutByteCount = stdoutByteCount
        self.stderrByteCount = stderrByteCount
        self.stdoutSHA256 = stdoutSHA256
        self.stderrSHA256 = stderrSHA256
        self.truncated = truncated
        self.cancellationRequested = cancellationRequested
        self.cancelDelivery = cancelDelivery
        self.processTreeState = processTreeState
        self.initialActiveDescendantCount = initialActiveDescendantCount
        self.activeDescendantCount = activeDescendantCount
        self.processTreeObservationCount = processTreeObservationCount
        self.processTreeObservedAfterTerminalBarrier = processTreeObservedAfterTerminalBarrier
    }

    var terminalBarrierSatisfied: Bool {
        rootExitObserved && stdoutEOFObserved && stderrEOFObserved
    }

    var boundedProcessTreeObservationSatisfied: Bool {
        guard let initialActiveDescendantCount, let processTreeObservationCount else {
            return true
        }
        return processTreeObservationCount >= 1 &&
            (initialActiveDescendantCount == 0 || processTreeObservationCount >= 2)
    }

    var verifiedSuccessBarrier: Bool {
        terminalBarrierSatisfied
            && finalStateKind == "exited"
            && finalStateValue == 0
            && !truncated
            && !cancellationRequested
            && cancelDelivery == .notRequested
            && processTreeState == .quiescent
            && activeDescendantCount == 0
            && boundedProcessTreeObservationSatisfied
            && processTreeObservedAfterTerminalBarrier
    }
}

enum StageDCloneStage: String, Codable, CaseIterable, Equatable, Sendable {
    case cloneProcess = "clone_process"
    case checkoutExactCommit = "checkout_exact_commit"
    case remoteVerify = "remote_verify"
    case headVerify = "head_verify"
    case boundedTreeVerify = "bounded_tree_verify"
}

enum StageDAdapterErrorCategory: String, Codable, Equatable, Sendable {
    case none
    case invalidInput = "invalid_input"
    case notPrepared = "not_prepared"
    case hostPipe = "host_pipe"
    case guestTask = "guest_task"
    case guestCWD = "guest_cwd"
    case guestStdio = "guest_stdio"
    case guestExec = "guest_exec"
    case stdoutReader = "stdout_reader"
    case stderrReader = "stderr_reader"
    case internalFailure = "internal_failure"
}

enum StageDCloneStageCategory: String, Codable, Equatable, Sendable {
    case notRun = "not_run"
    case succeeded
    case processNonzero = "process_nonzero"
    case resolverNetworkFailure = "resolver_network_failure"
    case remoteAccessFailure = "remote_access_failure"
    case filesystemFailure = "filesystem_failure"
    case checkoutWorktreeFailure = "checkout_worktree_failure"
    case protocolFailure = "protocol_failure"
    case capabilityUnavailable = "capability_unavailable"
    case timeoutUnknown = "timeout_unknown"
    case adapterError = "adapter_error"
    case targetUnavailable = "target_unavailable"
    case valueMismatch = "value_mismatch"
    case treeOverflow = "tree_overflow"
    case treeEscape = "tree_escape"
    case terminalBarrierFailure = "terminal_barrier_failure"
}

enum StageDCloneFilesystemSubcategory: String, Codable, Equatable, Sendable {
    case permissionReadonly = "permission_readonly"
    case namePathLimit = "name_path_limit"
    case filemodeChmod = "filemode_chmod"
    case createMkdirOpen = "create_mkdir_open"
    case destinationState = "destination_state"
    case capacityInode = "capacity_inode"
    case bindIdentity = "bind_identity"
    case generic
}

enum StageDFilesystemNodeType: String, Codable, Equatable, Sendable {
    case missing
    case directory
    case regularFile = "regular_file"
    case symbolicLink = "symbolic_link"
    case other
    case unknown
}

struct StageDCloneFilesystemPreflightFacts: Codable, Equatable, Sendable {
    let evidenceVersion: Int
    let complete: Bool
    let hostRootBindingSHA256: String
    let guestRootBindingSHA256: String
    let bindingMatches: Bool
    let parentExists: Bool
    let parentType: StageDFilesystemNodeType
    let parentIsEmpty: Bool
    let parentIsSymlink: Bool
    let targetExists: Bool
    let targetType: StageDFilesystemNodeType
    let targetIsEmpty: Bool
    let targetIsSymlink: Bool
    let probeNamesAbsent: Bool
    let mountReadOnly: Bool
    let umask: UInt32
    let nameMax: UInt64
    let pathMax: UInt64
    let availableBytes: UInt64
    let availableInodes: UInt64
    let requiredAvailableBytes: UInt64
    let requiredAvailableInodes: UInt64
    let requiredNameBytes: UInt64
    let requiredPathBytes: UInt64

    var failureSubcategory: StageDCloneFilesystemSubcategory? {
        guard evidenceVersion == 1,
              complete,
              bindingMatches,
              hostRootBindingSHA256 == guestRootBindingSHA256,
              parentExists,
              parentType == .directory,
              !parentIsSymlink else { return .bindIdentity }
        guard parentIsEmpty else { return .destinationState }
        guard !targetExists,
              targetType == .missing,
              targetIsEmpty,
              !targetIsSymlink,
              probeNamesAbsent else { return .destinationState }
        guard !mountReadOnly else { return .permissionReadonly }
        guard nameMax >= requiredNameBytes,
              pathMax >= requiredPathBytes else { return .namePathLimit }
        guard availableBytes >= requiredAvailableBytes,
              availableInodes >= requiredAvailableInodes else {
            return .capacityInode
        }
        return nil
    }
}

enum StageDCloneCapabilityStep: String, Codable, CaseIterable, Equatable, Sendable {
    case create
    case fchmod
    case fsync
    case rename
    case unlink
}

enum StageDCloneCapabilityStepState: String, Codable, Equatable, Sendable {
    case notRun = "not_run"
    case succeeded
    case failed
    case unknown
}

struct StageDCloneCapabilityStepFacts: Codable, Equatable, Sendable {
    let step: StageDCloneCapabilityStep
    let state: StageDCloneCapabilityStepState
    let succeeded: Bool
    let subcategory: StageDCloneFilesystemSubcategory?

    init(
        step: StageDCloneCapabilityStep,
        state: StageDCloneCapabilityStepState,
        subcategory: StageDCloneFilesystemSubcategory?
    ) {
        self.step = step
        self.state = state
        succeeded = state == .succeeded
        self.subcategory = subcategory
    }
}

struct StageDCloneCapabilityProbeFacts: Codable, Equatable, Sendable {
    let steps: [StageDCloneCapabilityStepFacts]
    let cleanupKnown: Bool
    let cleanupVerified: Bool

    var succeeded: Bool {
        steps.map(\.step) == StageDCloneCapabilityStep.allCases
            && steps.allSatisfy { $0.state == .succeeded && $0.subcategory == nil }
            && cleanupKnown
            && cleanupVerified
    }

    var requiresReconciliation: Bool {
        steps.contains { $0.state == .unknown } || !cleanupKnown || !cleanupVerified
    }

    var failureSubcategory: StageDCloneFilesystemSubcategory? {
        steps.first { $0.state == .failed || $0.state == .unknown }?.subcategory
    }

    static let notRun = StageDCloneCapabilityProbeFacts(
        steps: StageDCloneCapabilityStep.allCases.map {
            .init(step: $0, state: .notRun, subcategory: nil)
        },
        cleanupKnown: true,
        cleanupVerified: true
    )
}

struct StageDCloneResidualFacts: Codable, Equatable, Sendable {
    let inspectionComplete: Bool
    let targetExists: Bool
    let targetType: StageDFilesystemNodeType
    let targetIsSymlink: Bool
    let bounded: Bool
    let entryCount: Int
    let byteCount: UInt64
    let gitDirectory: Bool
    let gitHEAD: Bool
    let gitConfig: Bool
    let gitObjects: Bool
    let gitRefs: Bool

    static let targetAbsent = StageDCloneResidualFacts(
        inspectionComplete: true,
        targetExists: false,
        targetType: .missing,
        targetIsSymlink: false,
        bounded: true,
        entryCount: 0,
        byteCount: 0,
        gitDirectory: false,
        gitHEAD: false,
        gitConfig: false,
        gitObjects: false,
        gitRefs: false
    )
}

struct StageDCloneFilesystemEvidence: Codable, Equatable, Sendable {
    let evidenceVersion: Int
    let preflight: StageDCloneFilesystemPreflightFacts
    let probe: StageDCloneCapabilityProbeFacts
    let residual: StageDCloneResidualFacts
    let blockingSubcategory: StageDCloneFilesystemSubcategory? = nil

    var permitsSuccessfulClone: Bool {
        evidenceVersion == 1
            && preflight.failureSubcategory == nil
            && probe.succeeded
            && residual.inspectionComplete
            && residual.targetExists
            && residual.targetType == .directory
            && !residual.targetIsSymlink
            && residual.bounded
            && residual.gitDirectory
            && residual.gitHEAD
            && residual.gitConfig
            && residual.gitObjects
            && residual.gitRefs
    }
}

enum StageDRuntimeFailureCategory: String, Codable, Equatable, Sendable {
    case authorizationRejected = "authorization_rejected"
    case intentStoreFailure = "intent_store_failure"
    case resolverNetworkFailure = "resolver_network_failure"
    case cloneProcessNonzero = "clone_process_nonzero"
    case cloneTimeoutUnknown = "clone_timeout_unknown"
    case adapterFixedError = "adapter_fixed_error"
    case checkoutTargetUnavailable = "checkout_target_unavailable"
    case remoteMismatch = "remote_mismatch"
    case headMismatch = "head_mismatch"
    case treeOverflow = "tree_overflow"
    case treeEscape = "tree_escape"
    case eofTruncationProcessTreeFailure = "eof_truncation_process_tree_failure"
    case durableTerminalFailure = "durable_terminal_failure"
    case durableCompletionFailure = "durable_completion_failure"
}

struct StageDCloneStageOutcome: Codable, Equatable, Sendable {
    let stage: StageDCloneStage
    let category: StageDCloneStageCategory
    let processStarted: Bool
    let facts: StageDProcessFacts
    let adapterError: StageDAdapterErrorCategory
    let capturedProcessCategory: StageDCloneStageCategory?
    let filesystemSubcategory: StageDCloneFilesystemSubcategory?
    let observedValueSHA256: String?
    let entryCount: Int?
    let byteCount: UInt64?

    init(
        stage: StageDCloneStage,
        category: StageDCloneStageCategory,
        processStarted: Bool,
        facts: StageDProcessFacts,
        adapterError: StageDAdapterErrorCategory,
        capturedProcessCategory: StageDCloneStageCategory? = nil,
        filesystemSubcategory: StageDCloneFilesystemSubcategory? = nil,
        observedValueSHA256: String?,
        entryCount: Int?,
        byteCount: UInt64?
    ) {
        self.stage = stage
        self.category = category
        self.processStarted = processStarted
        self.facts = facts
        self.adapterError = adapterError
        self.capturedProcessCategory = capturedProcessCategory
        self.filesystemSubcategory = filesystemSubcategory
        self.observedValueSHA256 = observedValueSHA256
        self.entryCount = entryCount
        self.byteCount = byteCount
    }

    static func notRun(stage: StageDCloneStage) -> StageDCloneStageOutcome {
        .init(
            stage: stage,
            category: .notRun,
            processStarted: false,
            facts: .notRun,
            adapterError: .none,
            filesystemSubcategory: nil,
            observedValueSHA256: nil,
            entryCount: nil,
            byteCount: nil
        )
    }
}

extension StageDProcessFacts {
    static let notRun = StageDProcessFacts(
        rootExitObserved: false,
        finalStateKind: "not_run",
        finalStateValue: 0,
        stdoutEOFObserved: false,
        stderrEOFObserved: false,
        stdoutByteCount: 0,
        stderrByteCount: 0,
        stdoutSHA256: ProviderDigest.sha256Hex(Data()),
        stderrSHA256: ProviderDigest.sha256Hex(Data()),
        truncated: false,
        cancellationRequested: false,
        cancelDelivery: .notRequested,
        processTreeState: .notObserved,
        activeDescendantCount: 0,
        processTreeObservedAfterTerminalBarrier: false
    )
}

struct StageDCommandResult: Codable, Equatable, Sendable {
    let commandBindingSHA256: String
    let facts: [StageDProcessFacts]
    let stdout: String
    let stderr: String
    let outputProjectionTruncated: Bool
    let verification: String
    let verificationSHA256: String
    let cloneRemote: String?
    let cloneHEAD: String?
    let cloneEntryCount: Int?
    let cloneByteCount: UInt64?
    let toolVersions: [String: String]
    let cloneStages: [StageDCloneStageOutcome]
    let cloneFilesystemEvidence: StageDCloneFilesystemEvidence? = nil
    let failureCategory: StageDRuntimeFailureCategory?

    var verified: Bool {
        !facts.isEmpty
            && facts.allSatisfy(\.verifiedSuccessBarrier)
            && !outputProjectionTruncated
            && ProviderDigest.sha256Hex(verification) == verificationSHA256
            && (cloneStages.isEmpty || cloneStages.allSatisfy { $0.category == .succeeded })
            && (cloneStages.isEmpty || cloneFilesystemEvidence?.permitsSuccessfulClone == true)
            && failureCategory == nil
    }


    func safeDiagnosticSummaryData() throws -> Data {
        let summary = StageDSafeDiagnosticSummary(result: self)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(summary)
        guard data.count <= 8 * 1_024 else { throw StageDCommandError.evidenceFailure }
        return data
    }

    func safeDiagnosticSummaryString() throws -> String {
        String(decoding: try safeDiagnosticSummaryData(), as: UTF8.self)
    }
}

enum StageDSafeFinalKind: String, Codable, Equatable, Sendable {
    case notRun = "not_run"
    case exited
    case signaled
    case unknown
}

struct StageDSafeProcessSummary: Codable, Equatable, Sendable {
    let rootExitObserved: Bool
    let finalKind: StageDSafeFinalKind
    let finalValue: Int32
    let stdoutEOFObserved: Bool
    let stderrEOFObserved: Bool
    let stdoutByteCount: Int
    let stderrByteCount: Int
    let stdoutSHA256: String
    let stderrSHA256: String
    let truncated: Bool
    let cancellationRequested: Bool
    let cancelDelivery: StageDCancelDelivery
    let processTreeState: StageDProcessTreeState
    let initialActiveDescendantCount: Int?
    let activeDescendantCount: Int
    let processTreeObservationCount: Int?
    let processTreeObservedAfterTerminalBarrier: Bool

    init(_ facts: StageDProcessFacts) {
        rootExitObserved = facts.rootExitObserved
        finalKind = StageDSafeFinalKind(rawValue: facts.finalStateKind) ?? .unknown
        finalValue = facts.finalStateValue
        stdoutEOFObserved = facts.stdoutEOFObserved
        stderrEOFObserved = facts.stderrEOFObserved
        stdoutByteCount = facts.stdoutByteCount
        stderrByteCount = facts.stderrByteCount
        stdoutSHA256 = facts.stdoutSHA256
        stderrSHA256 = facts.stderrSHA256
        truncated = facts.truncated
        cancellationRequested = facts.cancellationRequested
        cancelDelivery = facts.cancelDelivery
        processTreeState = facts.processTreeState
        initialActiveDescendantCount = facts.initialActiveDescendantCount
        activeDescendantCount = facts.activeDescendantCount
        processTreeObservationCount = facts.processTreeObservationCount
        processTreeObservedAfterTerminalBarrier = facts.processTreeObservedAfterTerminalBarrier
    }
}

struct StageDSafeCloneStageSummary: Codable, Equatable, Sendable {
    let stage: StageDCloneStage
    let category: StageDCloneStageCategory
    let processStarted: Bool
    let facts: StageDSafeProcessSummary
    let adapterError: StageDAdapterErrorCategory
    let capturedProcessCategory: StageDCloneStageCategory?
    let filesystemSubcategory: StageDCloneFilesystemSubcategory?
    let observedValueSHA256: String?
    let entryCount: Int?
    let byteCount: UInt64?

    init(_ outcome: StageDCloneStageOutcome) {
        stage = outcome.stage
        category = outcome.category
        processStarted = outcome.processStarted
        facts = StageDSafeProcessSummary(outcome.facts)
        adapterError = outcome.adapterError
        capturedProcessCategory = outcome.capturedProcessCategory
        filesystemSubcategory = outcome.filesystemSubcategory
        observedValueSHA256 = outcome.observedValueSHA256
        entryCount = outcome.entryCount
        byteCount = outcome.byteCount
    }
}

enum StageDSafeLoopCategory: String, Codable, Equatable, Sendable {
    case succeeded
    case failed
    case completed
    case pendingApproval = "pending_approval"
    case rejected
    case reconciliationRequired = "reconciliation_required"
}

struct StageDSafeDiagnosticSummary: Codable, Equatable, Sendable {
    let loopCategory: StageDSafeLoopCategory
    let commandError: StageDCommandError?
    let failureCategory: StageDRuntimeFailureCategory?
    let commandBindingSHA256: String?
    let verificationSHA256: String?
    let processFacts: [StageDSafeProcessSummary]
    let cloneStages: [StageDSafeCloneStageSummary]
    let cloneFilesystemEvidence: StageDCloneFilesystemEvidence?

    init(result: StageDCommandResult) {
        loopCategory = result.cloneFilesystemEvidence?.probe.requiresReconciliation == true
            ? .reconciliationRequired
            : (result.verified ? .succeeded : .failed)
        commandError = nil
        failureCategory = result.failureCategory
        commandBindingSHA256 = result.commandBindingSHA256
        verificationSHA256 = result.verificationSHA256
        processFacts = result.facts.map(StageDSafeProcessSummary.init)
        cloneStages = result.cloneStages.map(StageDSafeCloneStageSummary.init)
        cloneFilesystemEvidence = result.cloneFilesystemEvidence
    }

    private init(loopCategory: StageDSafeLoopCategory, commandError: StageDCommandError? = nil) {
        self.loopCategory = loopCategory
        self.commandError = commandError
        failureCategory = nil
        commandBindingSHA256 = nil
        verificationSHA256 = nil
        processFacts = []
        cloneStages = []
        cloneFilesystemEvidence = nil
    }

    static func forLoopOutcome(_ outcome: StageDLoopOutcome) -> StageDSafeDiagnosticSummary {
        switch outcome {
        case .completed: return .init(loopCategory: .completed)
        case .pendingApproval: return .init(loopCategory: .pendingApproval)
        case let .rejected(error): return .init(loopCategory: .rejected, commandError: error)
        case let .failed(error): return .init(loopCategory: .failed, commandError: error)
        case .reconciliationRequired: return .init(loopCategory: .reconciliationRequired)
        }
    }

    func encodedString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= 8 * 1_024 else { throw StageDCommandError.evidenceFailure }
        return String(decoding: data, as: UTF8.self)
    }
}

enum StageDExecutorOutcome: Equatable, Sendable {
    case succeeded(StageDCommandResult)
    case failed(StageDCommandResult?)
    case unknown(StageDCommandResult?)
}

protocol StageDCommandExecuting: Sendable {
    func execute(
        _ command: StageDAuthorizedCommand,
        policy: StageDCommandPolicy
    ) async -> StageDExecutorOutcome
}

struct StageDApprovalRequest: Codable, Equatable, Sendable {
    let requestID: UUID
    let taskID: UUID
    let operationID: UUID
    let attemptID: UUID
    let workspaceIdentitySHA256: String
    let commandBindingSHA256: String
    let command: String
    let argumentsSHA256: String
    let cwd: String
    let risk: StageDCommandRisk
    let executionRoot: StageDExecutionRoot
    let providerDecisionSHA256: String?
    let nonce: UUID
    let createdAt: Date
    let expiresAt: Date

    init(
        requestID: UUID,
        taskID: UUID,
        operationID: UUID,
        attemptID: UUID,
        workspaceIdentitySHA256: String,
        commandBindingSHA256: String,
        command: String,
        argumentsSHA256: String,
        cwd: String,
        risk: StageDCommandRisk,
        executionRoot: StageDExecutionRoot,
        providerDecisionSHA256: String? = nil,
        nonce: UUID,
        createdAt: Date,
        expiresAt: Date
    ) {
        self.requestID = requestID
        self.taskID = taskID
        self.operationID = operationID
        self.attemptID = attemptID
        self.workspaceIdentitySHA256 = workspaceIdentitySHA256
        self.commandBindingSHA256 = commandBindingSHA256
        self.command = command
        self.argumentsSHA256 = argumentsSHA256
        self.cwd = cwd
        self.risk = risk
        self.executionRoot = executionRoot
        self.providerDecisionSHA256 = providerDecisionSHA256
        self.nonce = nonce
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    var bindingSHA256: String {
        ProviderDigest.sha256Hex([
            requestID.uuidString.lowercased(), taskID.uuidString.lowercased(),
            operationID.uuidString.lowercased(), attemptID.uuidString.lowercased(),
            workspaceIdentitySHA256, commandBindingSHA256, ProviderDigest.sha256Hex(command),
            argumentsSHA256, cwd, risk.rawValue, executionRoot.rawValue,
            providerDecisionSHA256 ?? "",
            nonce.uuidString.lowercased(),
            String(Int64((createdAt.timeIntervalSince1970 * 1_000).rounded())),
            String(Int64((expiresAt.timeIntervalSince1970 * 1_000).rounded()))
        ].joined(separator: "\u{0}"))
    }
}

struct StageDApprovalGrant: Codable, Equatable, Sendable {
    let requestID: UUID
    let requestBindingSHA256: String
    let nonce: UUID
    let approvedAt: Date
}

enum StageDApprovalState: String, Codable, Equatable, Sendable {
    case pending
    case approved
    case rejected
    case cancelled
    case expired
    case consumed
}

struct StageDApprovalEvidence: Codable, Equatable, Sendable {
    let request: StageDApprovalRequest
    let state: StageDApprovalState
    let recordedAt: Date
    let grant: StageDApprovalGrant?
}

enum StageDApprovalDecision: Equatable, Sendable {
    case approved(StageDApprovalGrant)
    case rejected
    case cancelled
    case expired
}

protocol StageDApprovalAuthorizing: Sendable {
    func requestApproval(_ request: StageDApprovalRequest) async -> StageDApprovalDecision
}

struct StageDApprovalProjection: Equatable, Sendable {
    let state: StageDApprovalState?
    let request: StageDApprovalRequest?
}

actor StageDApprovalBroker: StageDApprovalAuthorizing {
    static let shared = StageDApprovalBroker()
    private var pending: StageDApprovalRequest?
    private var continuation: CheckedContinuation<StageDApprovalDecision, Never>?
    private var listeners: [UUID: AsyncStream<StageDApprovalProjection>.Continuation] = [:]

    func requestApproval(_ request: StageDApprovalRequest) async -> StageDApprovalDecision {
        guard pending == nil && continuation == nil else { return .rejected }
        pending = request
        emit(.init(state: .pending, request: request))
        return await withCheckedContinuation { continuation = $0 }
    }

    func approve(requestID: UUID, nonce: UUID, at: Date = Date()) {
        guard let request = pending,
              request.requestID == requestID,
              request.nonce == nonce else {
            return resolve(.rejected, state: .rejected)
        }
        guard at <= request.expiresAt else { return resolve(.expired, state: .expired) }
        resolve(.approved(.init(
            requestID: requestID,
            requestBindingSHA256: request.bindingSHA256,
            nonce: nonce,
            approvedAt: at
        )), state: .approved)
    }

    func reject(requestID: UUID, nonce: UUID) {
        guard pending?.requestID == requestID && pending?.nonce == nonce else { return }
        resolve(.rejected, state: .rejected)
    }

    func cancel(requestID: UUID, nonce: UUID) {
        guard pending?.requestID == requestID && pending?.nonce == nonce else { return }
        resolve(.cancelled, state: .cancelled)
    }

    func snapshot() -> StageDApprovalProjection {
        .init(state: pending == nil ? nil : .pending, request: pending)
    }

    func projections() -> AsyncStream<StageDApprovalProjection> {
        let id = UUID()
        return AsyncStream { continuation in
            listeners[id] = continuation
            continuation.yield(.init(state: pending == nil ? nil : .pending, request: pending))
            continuation.onTermination = { [weak self] _ in Task { await self?.remove(id) } }
        }
    }

    private func resolve(_ decision: StageDApprovalDecision, state: StageDApprovalState) {
        let request = pending
        pending = nil
        let saved = continuation
        continuation = nil
        emit(.init(state: state, request: request))
        saved?.resume(returning: decision)
    }

    private func emit(_ projection: StageDApprovalProjection) {
        listeners.values.forEach { $0.yield(projection) }
    }

    private func remove(_ id: UUID) { listeners.removeValue(forKey: id) }
}

enum StageDExternalIOKind: String, Codable, Equatable, Sendable {
    case provider
    case command
}

enum StageDAttemptPhase: String, Codable, Equatable, Sendable {
    case intentRecorded = "intent_recorded"
    case succeeded
    case failed
    case reconciliationRequired = "reconciliation_required"
}

struct StageDProviderDecision: Codable, Equatable, Sendable {
    let toolCallID: String
    let command: String
    let cwd: String
    let assistantSHA256: String
    let expectedInputSHA256: String
}

struct StageDAttemptEvidence: Codable, Equatable, Sendable {
    let taskID: UUID
    let operationID: UUID
    let attemptID: UUID
    let kind: StageDExternalIOKind
    let phase: StageDAttemptPhase
    let inputSHA256: String
    let recordedAt: Date
    let command: StageDAuthorizedCommand?
    let approvalBindingSHA256: String?
    let providerDecisionSHA256: String?
    let providerDecision: StageDProviderDecision?
    let result: StageDCommandResult?
    let resultSHA256: String?

    init(
        taskID: UUID,
        operationID: UUID,
        attemptID: UUID,
        kind: StageDExternalIOKind,
        phase: StageDAttemptPhase,
        inputSHA256: String,
        recordedAt: Date,
        command: StageDAuthorizedCommand?,
        approvalBindingSHA256: String?,
        providerDecisionSHA256: String? = nil,
        providerDecision: StageDProviderDecision?,
        result: StageDCommandResult?,
        resultSHA256: String?
    ) {
        self.taskID = taskID
        self.operationID = operationID
        self.attemptID = attemptID
        self.kind = kind
        self.phase = phase
        self.inputSHA256 = inputSHA256
        self.recordedAt = recordedAt
        self.command = command
        self.approvalBindingSHA256 = approvalBindingSHA256
        self.providerDecisionSHA256 = providerDecisionSHA256
        self.providerDecision = providerDecision
        self.result = result
        self.resultSHA256 = resultSHA256
    }
}

enum StageDTaskPhase: String, Codable, Equatable, Sendable {
    case ready
    case awaitingApproval = "awaiting_approval"
    case executing
    case verifying
    case completed
    case rejected
    case failed
    case reconciliationRequired = "reconciliation_required"
}

enum StageDCompletionKind: String, Codable, Equatable, Sendable {
    case exactFile = "exact_file"
    case exactClone = "exact_clone"
    case successfulCommand = "successful_command"
}

struct StageDCompletionExpectation: Codable, Equatable, Sendable {
    let kind: StageDCompletionKind
    let relativePath: String?
    let expectedSHA256: String?
    let cloneTarget: String?
    let cloneRemote: String?
    let cloneHEAD: String?
}

struct StageDCompletion: Codable, Equatable, Sendable {
    let taskID: UUID
    let sessionID: UUID
    let workspaceIdentitySHA256: String
    let commandBindingSHA256: String
    let approvalBindingSHA256: String?
    let operationID: UUID
    let attemptID: UUID
    let resultSHA256: String
    let verificationSHA256: String
    let providerDecisionSHA256: String?
    let completedAt: Date

    init(
        taskID: UUID,
        sessionID: UUID,
        workspaceIdentitySHA256: String,
        commandBindingSHA256: String,
        approvalBindingSHA256: String?,
        operationID: UUID,
        attemptID: UUID,
        resultSHA256: String,
        verificationSHA256: String,
        providerDecisionSHA256: String? = nil,
        completedAt: Date
    ) {
        self.taskID = taskID
        self.sessionID = sessionID
        self.workspaceIdentitySHA256 = workspaceIdentitySHA256
        self.commandBindingSHA256 = commandBindingSHA256
        self.approvalBindingSHA256 = approvalBindingSHA256
        self.operationID = operationID
        self.attemptID = attemptID
        self.resultSHA256 = resultSHA256
        self.verificationSHA256 = verificationSHA256
        self.providerDecisionSHA256 = providerDecisionSHA256
        self.completedAt = completedAt
    }
}

struct StageDTaskRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let sessionID: UUID
    let importID: UUID
    let workspaceID: UUID
    let workspaceIdentitySHA256: String
    let workspaceRootSHA256: String
    let goalBindingSHA256: String
    let ruleSetBindingSHA256: String
    let cloneRootSHA256: String
    let write: StageDBoundedWrite?
    let expectation: StageDCompletionExpectation
    let createdAt: Date
    var updatedAt: Date
    var phase: StageDTaskPhase
    var approvals: [StageDApprovalEvidence]
    var attempts: [StageDAttemptEvidence]
    var completion: StageDCompletion?
}

enum StageDLoopOutcome: Equatable, Sendable {
    case completed(StageDCompletion)
    case pendingApproval
    case rejected(StageDCommandError)
    case failed(StageDCommandError)
    case reconciliationRequired
}

actor StageDWorkspaceGate {
    static let shared = StageDWorkspaceGate()
    private var holders: [String: UUID] = [:]

    func acquire(_ identity: String) -> UUID? {
        guard holders[identity] == nil else { return nil }
        let token = UUID()
        holders[identity] = token
        return token
    }

    func release(_ identity: String, token: UUID) {
        guard holders[identity] == token else { return }
        holders.removeValue(forKey: identity)
    }

    func withLease<Value: Sendable>(
        _ identity: String,
        operation: @Sendable () async throws -> Value
    ) async rethrows -> Value? {
        guard let token = acquire(identity) else { return nil }
        do {
            let value = try await operation()
            release(identity, token: token)
            return value
        } catch {
            release(identity, token: token)
            throw error
        }
    }
}
