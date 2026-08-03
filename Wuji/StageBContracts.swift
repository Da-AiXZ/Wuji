import Foundation

struct StageBLimits: Equatable, Sendable {
    let maximumProviderTurns: Int
    let maximumToolExecutions: Int
    let maximumToolCallsPerBatch: Int
    let maximumGoalBytes: Int
    let maximumPathBytes: Int
    let maximumQueryBytes: Int
    let maximumRuleFiles: Int
    let maximumRuleFileBytes: Int
    let maximumRuleAggregateBytes: Int
    let maximumContextBytes: Int
    let maximumListEntries: Int
    let maximumSearchMatches: Int
    let maximumReadBytes: Int
    let maximumLineBytes: Int
    let maximumExecutorStreamBytes: Int
    let maximumModelObservationBytes: Int
    let maximumDurableEvidenceBytes: Int
    let maximumDiagnosticBytes: Int

    // These are injectable Stage B production defaults, not permanent product limits.
    static let production = StageBLimits(
        maximumProviderTurns: 12,
        maximumToolExecutions: 24,
        maximumToolCallsPerBatch: 8,
        maximumGoalBytes: 4 * 1_024,
        maximumPathBytes: 1_024,
        maximumQueryBytes: 512,
        maximumRuleFiles: 16,
        maximumRuleFileBytes: 16 * 1_024,
        maximumRuleAggregateBytes: 48 * 1_024,
        maximumContextBytes: 48 * 1_024,
        maximumListEntries: 128,
        maximumSearchMatches: 64,
        maximumReadBytes: 24 * 1_024,
        maximumLineBytes: 2 * 1_024,
        maximumExecutorStreamBytes: 32 * 1_024,
        maximumModelObservationBytes: 8 * 1_024,
        maximumDurableEvidenceBytes: 2 * 1_024 * 1_024,
        maximumDiagnosticBytes: 64 * 1_024
    )

    init(
        maximumProviderTurns: Int,
        maximumToolExecutions: Int,
        maximumToolCallsPerBatch: Int,
        maximumGoalBytes: Int,
        maximumPathBytes: Int,
        maximumQueryBytes: Int,
        maximumRuleFiles: Int,
        maximumRuleFileBytes: Int,
        maximumRuleAggregateBytes: Int,
        maximumContextBytes: Int,
        maximumListEntries: Int,
        maximumSearchMatches: Int,
        maximumReadBytes: Int,
        maximumLineBytes: Int,
        maximumExecutorStreamBytes: Int,
        maximumModelObservationBytes: Int,
        maximumDurableEvidenceBytes: Int,
        maximumDiagnosticBytes: Int
    ) {
        let positive = [
            maximumProviderTurns, maximumToolExecutions, maximumToolCallsPerBatch,
            maximumGoalBytes, maximumPathBytes, maximumQueryBytes, maximumRuleFiles,
            maximumRuleFileBytes, maximumRuleAggregateBytes, maximumContextBytes,
            maximumListEntries, maximumSearchMatches, maximumReadBytes,
            maximumLineBytes, maximumExecutorStreamBytes, maximumModelObservationBytes,
            maximumDurableEvidenceBytes, maximumDiagnosticBytes
        ]
        precondition(positive.allSatisfy { $0 > 0 })
        precondition(maximumToolCallsPerBatch <= maximumToolExecutions)
        precondition(maximumGoalBytes <= ProviderLimits.maximumTurnMessageBytes)
        precondition(maximumPathBytes <= 1_024)
        precondition(maximumQueryBytes <= 512)
        precondition(maximumModelObservationBytes <= ProviderLimits.maximumTurnMessageBytes)
        precondition(maximumContextBytes <= ProviderLimits.maximumRequestBodyBytes)
        precondition(maximumReadBytes <= maximumExecutorStreamBytes)
        precondition(maximumLineBytes <= maximumExecutorStreamBytes)
        precondition(maximumExecutorStreamBytes <= 32 * 1_024)
        self.maximumProviderTurns = maximumProviderTurns
        self.maximumToolExecutions = maximumToolExecutions
        self.maximumToolCallsPerBatch = maximumToolCallsPerBatch
        self.maximumGoalBytes = maximumGoalBytes
        self.maximumPathBytes = maximumPathBytes
        self.maximumQueryBytes = maximumQueryBytes
        self.maximumRuleFiles = maximumRuleFiles
        self.maximumRuleFileBytes = maximumRuleFileBytes
        self.maximumRuleAggregateBytes = maximumRuleAggregateBytes
        self.maximumContextBytes = maximumContextBytes
        self.maximumListEntries = maximumListEntries
        self.maximumSearchMatches = maximumSearchMatches
        self.maximumReadBytes = maximumReadBytes
        self.maximumLineBytes = maximumLineBytes
        self.maximumExecutorStreamBytes = maximumExecutorStreamBytes
        self.maximumModelObservationBytes = maximumModelObservationBytes
        self.maximumDurableEvidenceBytes = maximumDurableEvidenceBytes
        self.maximumDiagnosticBytes = maximumDiagnosticBytes
    }
}

enum StageBError: String, Error, Codable, Equatable, Sendable {
    case invalidGoal = "invalid_goal"
    case workspaceUnavailable = "workspace_unavailable"
    case workspaceBindingMismatch = "workspace_binding_mismatch"
    case workspaceNotReady = "workspace_not_ready"
    case protectedPath = "protected_path"
    case pathRejected = "path_rejected"
    case pathUnavailable = "path_unavailable"
    case symlinkEscape = "symlink_escape"
    case ruleLimit = "rule_limit"
    case ruleUnavailable = "rule_unavailable"
    case contextLimit = "context_limit"
    case batchCount = "batch_count"
    case toolCallID = "tool_call_id"
    case unknownTool = "unknown_tool"
    case invalidArguments = "invalid_arguments"
    case queryRejected = "query_rejected"
    case ruleBindingMismatch = "rule_binding_mismatch"
    case evidenceUnavailable = "evidence_unavailable"
    case executorFailure = "executor_failure"
    case providerFailure = "provider_failure"
    case limitsExceeded = "limits_exceeded"
    case completionNotEstablished = "completion_not_established"
}

struct StageBGoal: Codable, Equatable, Sendable {
    let text: String
    let exactQuery: String
    let expectedRelativePath: String?
    let bindingSHA256: String

    init(
        text: String,
        exactQuery: String,
        expectedRelativePath: String? = nil,
        limits: StageBLimits = .production
    ) throws {
        guard Self.validText(text, maximumBytes: limits.maximumGoalBytes),
              Self.validText(exactQuery, maximumBytes: limits.maximumQueryBytes),
              expectedRelativePath.map({
                  StageBPathSyntax.valid($0, allowEmpty: false, maximumBytes: limits.maximumPathBytes)
              }) ?? true else {
            throw StageBError.invalidGoal
        }
        self.text = text
        self.exactQuery = exactQuery
        self.expectedRelativePath = expectedRelativePath
        bindingSHA256 = ProviderDigest.sha256Hex([
            text,
            exactQuery,
            expectedRelativePath ?? "any"
        ].joined(separator: "\u{0}"))
    }

    private static func validText(_ value: String, maximumBytes: Int) -> Bool {
        let bytes = value.utf8.count
        return bytes > 0
            && bytes <= maximumBytes
            && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
}

enum StageBPathSyntax {
    static func valid(_ path: String, allowEmpty: Bool, maximumBytes: Int) -> Bool {
        guard path.utf8.count <= maximumBytes,
              !path.hasPrefix("/"),
              !path.hasPrefix("\\"),
              !path.contains("\\"),
              !path.contains("%"),
              !path.contains(":"),
              path.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return false
        }
        if path.isEmpty { return allowEmpty }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }
}

struct StageBReadyWorkspace: Sendable {
    let importID: UUID
    let workspaceID: UUID
    let canonicalRootURL: URL
    let identitySHA256: String
    let markerSHA256: String
}

struct StageBRule: Equatable, Sendable {
    let relativePath: String
    let scopePath: String
    let content: String
    let contentSHA256: String
}

struct StageBRuleDescriptor: Codable, Equatable, Sendable {
    let relativePath: String
    let scopePath: String
    let contentByteCount: Int
    let contentSHA256: String
}

struct StageBRuleSet: Equatable, Sendable {
    let rules: [StageBRule]
    let bindingSHA256: String

    var descriptors: [StageBRuleDescriptor] {
        rules.map {
            StageBRuleDescriptor(
                relativePath: $0.relativePath,
                scopePath: $0.scopePath,
                contentByteCount: $0.content.utf8.count,
                contentSHA256: $0.contentSHA256
            )
        }
    }
}

enum StageBToolName: String, CaseIterable, Codable, Sendable {
    case list
    case search
    case read
}

enum StageBAuthorizedTool: Equatable, Sendable {
    case list(path: String, ruleSetSHA256: String)
    case search(path: String, query: String, ruleSetSHA256: String)
    case read(path: String, ruleSetSHA256: String)

    var name: StageBToolName {
        switch self {
        case .list: return .list
        case .search: return .search
        case .read: return .read
        }
    }

    var relativePath: String {
        switch self {
        case let .list(path, _), let .search(path, _, _), let .read(path, _): return path
        }
    }

    var query: String? {
        if case let .search(_, query, _) = self { return query }
        return nil
    }

    var ruleSetSHA256: String {
        switch self {
        case let .list(_, hash), let .search(_, _, hash), let .read(_, hash): return hash
        }
    }

    var inputSHA256: String {
        ProviderDigest.sha256Hex([
            name.rawValue,
            relativePath,
            query ?? "",
            ruleSetSHA256
        ].joined(separator: "\u{0}"))
    }
}

struct StageBAuthorizedToolCall: Equatable, Sendable {
    let toolCallID: String
    let tool: StageBAuthorizedTool
}

struct StageBBatchPolicyError: Error, Equatable, Sendable {
    let reason: StageBError
    let callIndex: Int?
}

struct StageBExecutorFacts: Codable, Equatable, Sendable {
    let rootExitObserved: Bool
    let stdoutEOFObserved: Bool
    let stderrEOFObserved: Bool
    let finalStateKind: String
    let finalStateValue: Int32
    let stdoutByteCount: Int
    let stderrByteCount: Int
    let stdoutSHA256: String
    let stderrSHA256: String
    let truncated: Bool

    var completionBarrierSatisfied: Bool {
        rootExitObserved && stdoutEOFObserved && stderrEOFObserved
    }

    var exitedSuccessfully: Bool {
        finalStateKind == "exited" && finalStateValue == 0
    }
}

struct StageBSearchMatch: Codable, Equatable, Sendable {
    let path: String
    let line: Int
    let text: String
}

enum StageBObservationPayload: Codable, Equatable, Sendable {
    case list(entries: [String])
    case search(matches: [StageBSearchMatch])
    case read(path: String, content: String)
}

struct StageBToolObservation: Codable, Equatable, Sendable {
    let tool: StageBToolName
    let relativePath: String
    let query: String?
    let ruleSetSHA256: String
    let payload: StageBObservationPayload
    let facts: StageBExecutorFacts

    var evidenceSHA256: String {
        var parts = [
            tool.rawValue,
            relativePath,
            query ?? "",
            ruleSetSHA256,
            facts.stdoutSHA256,
            facts.stderrSHA256,
            facts.finalStateKind,
            String(facts.finalStateValue)
        ]
        switch payload {
        case let .list(entries): parts.append(contentsOf: entries)
        case let .search(matches):
            parts.append(contentsOf: matches.map { "\($0.path):\($0.line):\($0.text)" })
        case let .read(path, content):
            parts.append(path)
            parts.append(ProviderDigest.sha256Hex(content))
        }
        return ProviderDigest.sha256Hex(parts.joined(separator: "\u{0}"))
    }
}

enum StageBExecutorFailure: String, Error, Codable, Equatable, Sendable {
    case preparation
    case rejected
    case nonzeroExit = "nonzero_exit"
    case incompleteDrain = "incomplete_drain"
    case observationLimit = "observation_limit"
    case malformedObservation = "malformed_observation"
}

enum StageBExecutorOutcome: Equatable, Sendable {
    case observation(StageBToolObservation)
    case failure(StageBExecutorFailure)
    case unknown
}

protocol StageBReadOnlyExecuting: Sendable {
    func execute(_ tool: StageBAuthorizedTool) async -> StageBExecutorOutcome
}

struct StageBCompletion: Codable, Equatable, Sendable {
    let sessionID: UUID
    let workspaceIdentitySHA256: String
    let goalBindingSHA256: String
    let ruleSetBindingSHA256: String
    let relativePath: String
    let query: String
    let providerRequestCount: Int
    let toolExecutionCount: Int
    let evidenceChainSHA256: String
}

enum StageBLoopOutcome: Equatable, Sendable {
    case completed(StageBCompletion)
    case failure(StageBError)
    case reconciliationRequired
}
