import Foundation

enum StageBSessionPhase: String, Codable, Equatable, Sendable {
    case created
    case rulesReady = "rules_ready"
    case running
    case completed
    case failed
    case reconciliationRequired = "reconciliation_required"
}

struct StageBSessionRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let importID: UUID
    let workspaceID: UUID
    let workspaceIdentitySHA256: String
    let markerSHA256: String
    let goal: StageBGoal
    let createdAt: Date
    var updatedAt: Date
    var phase: StageBSessionPhase
    var ruleSetBindingSHA256: String?
    var rules: [StageBRuleDescriptor]
    var completion: StageBCompletion?
    var diagnostics: [String]
}

enum StageBAttemptKind: String, Codable, Equatable, Sendable {
    case ruleDiscovery = "rule_discovery"
    case provider
    case executor
    case recovery
    case completionCheck = "completion_check"
}

enum StageBAttemptPhase: String, Codable, Equatable, Sendable {
    case intentRecorded = "intent_recorded"
    case succeeded
    case failed
    case reconciliationRequired = "reconciliation_required"
}

enum StageBAttemptCategory: String, Codable, Equatable, Sendable {
    case none
    case rulesBound = "rules_bound"
    case providerToolCalls = "provider_tool_calls"
    case providerFinish = "provider_finish"
    case providerFailure = "provider_failure"
    case providerUnknown = "provider_unknown"
    case observation
    case executorFailure = "executor_failure"
    case executorUnknown = "executor_unknown"
    case policyNotExecuted = "policy_not_executed"
    case recoveryBlocked = "recovery_blocked"
    case completionEstablished = "completion_established"
    case completionRejected = "completion_rejected"
}

struct StageBProviderOutcomeEvidence: Codable, Equatable, Sendable {
    let assistantContentByteCount: Int
    let assistantContentSHA256: String?
    let toolCalls: [ProviderTurnToolCall]

    var decision: ProviderInferenceDecision {
        let assistant = ProviderTurnMessage(
            role: .assistant,
            content: toolCalls.isEmpty
                ? "Provider finish restored from bounded durable outcome."
                : nil,
            toolCalls: toolCalls
        )
        return toolCalls.isEmpty ? .finish(assistant) : .toolCalls(assistant, toolCalls)
    }

    var resultDescription: String {
        toolCalls.isEmpty
            ? "provider finished with \(assistantContentByteCount) content bytes"
            : "provider selected \(toolCalls.count) typed tool calls"
    }
}

struct StageBPolicyRejectionEvidence: Codable, Equatable, Sendable {
    let reason: StageBError
    let callIndex: Int?
}

struct StageBSearchEvidence: Codable, Equatable, Sendable {
    let path: String
    let line: Int
    let textByteCount: Int
    let textSHA256: String
    let exactQueryOccurrences: Int
}

struct StageBObservationEvidence: Codable, Equatable, Sendable {
    let tool: StageBToolName
    let relativePath: String
    let querySHA256: String?
    let ruleSetSHA256: String
    let listedEntries: [String]?
    let matches: [StageBSearchEvidence]?
    let readContentSHA256: String?
    let readContentByteCount: Int?
    let exactQueryOccurrences: Int?
    let executorFacts: StageBExecutorFacts
    let observationSHA256: String

    static func make(
        observation: StageBToolObservation,
        exactQuery: String,
        limits: StageBLimits
    ) throws -> StageBObservationEvidence {
        let listedEntries: [String]?
        let matches: [StageBSearchEvidence]?
        let readHash: String?
        let readBytes: Int?
        let occurrences: Int?
        switch observation.payload {
        case let .list(entries):
            guard entries.count <= limits.maximumListEntries else { throw StageBError.limitsExceeded }
            listedEntries = entries
            matches = nil
            readHash = nil
            readBytes = nil
            occurrences = nil
        case let .search(values):
            guard values.count <= limits.maximumSearchMatches else { throw StageBError.limitsExceeded }
            listedEntries = nil
            matches = values.map {
                StageBSearchEvidence(
                    path: $0.path,
                    line: $0.line,
                    textByteCount: $0.text.utf8.count,
                    textSHA256: ProviderDigest.sha256Hex($0.text),
                    exactQueryOccurrences: $0.text.components(separatedBy: exactQuery).count - 1
                )
            }
            readHash = nil
            readBytes = nil
            occurrences = nil
        case let .read(_, content):
            listedEntries = nil
            matches = nil
            readHash = ProviderDigest.sha256Hex(content)
            readBytes = content.utf8.count
            occurrences = content.components(separatedBy: exactQuery).count - 1
        }
        return StageBObservationEvidence(
            tool: observation.tool,
            relativePath: observation.relativePath,
            querySHA256: observation.query.map(ProviderDigest.sha256Hex),
            ruleSetSHA256: observation.ruleSetSHA256,
            listedEntries: listedEntries,
            matches: matches,
            readContentSHA256: readHash,
            readContentByteCount: readBytes,
            exactQueryOccurrences: occurrences,
            executorFacts: observation.facts,
            observationSHA256: observation.evidenceSHA256
        )
    }
}

struct StageBAttemptEvidence: Codable, Equatable, Sendable {
    let sessionID: UUID
    let operationID: UUID
    let attemptID: UUID
    let kind: StageBAttemptKind
    let toolName: StageBToolName?
    let toolCallIDHash: String?
    let inputSHA256: String
    let recordedAt: Date
    let phase: StageBAttemptPhase
    let category: StageBAttemptCategory
    let resultByteCount: Int?
    let resultSHA256: String?
    let observation: StageBObservationEvidence?
    let providerOutcome: StageBProviderOutcomeEvidence?
    let policyRejection: StageBPolicyRejectionEvidence?

    init(
        sessionID: UUID,
        operationID: UUID,
        attemptID: UUID,
        kind: StageBAttemptKind,
        toolName: StageBToolName?,
        toolCallIDHash: String?,
        inputSHA256: String,
        recordedAt: Date,
        phase: StageBAttemptPhase,
        category: StageBAttemptCategory,
        resultByteCount: Int?,
        resultSHA256: String?,
        observation: StageBObservationEvidence?,
        providerOutcome: StageBProviderOutcomeEvidence? = nil,
        policyRejection: StageBPolicyRejectionEvidence? = nil
    ) {
        self.sessionID = sessionID
        self.operationID = operationID
        self.attemptID = attemptID
        self.kind = kind
        self.toolName = toolName
        self.toolCallIDHash = toolCallIDHash
        self.inputSHA256 = inputSHA256
        self.recordedAt = recordedAt
        self.phase = phase
        self.category = category
        self.resultByteCount = resultByteCount
        self.resultSHA256 = resultSHA256
        self.observation = observation
        self.providerOutcome = providerOutcome
        self.policyRejection = policyRejection
    }
}

struct StageBDurableSnapshot: Sendable {
    let session: StageBSessionRecord
    let attempts: [StageBAttemptEvidence]
}

enum StageBSessionStoreError: Error, Equatable {
    case invalidRecord
    case invalidEvidence
    case persistenceFailed
}

actor StageBSessionStore {
    nonisolated let rootURL: URL
    private let sessionsURL: URL
    private let limits: StageBLimits
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fileManager: FileManager

    init(
        rootURL: URL,
        limits: StageBLimits = .production,
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL
        sessionsURL = rootURL.appendingPathComponent("Sessions", isDirectory: true)
        self.limits = limits
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    static func applicationStore(limits: StageBLimits = .production) throws -> StageBSessionStore {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return StageBSessionStore(
            rootURL: support.appendingPathComponent("WujiStageB", isDirectory: true),
            limits: limits
        )
    }

    func create(
        workspace: StageBReadyWorkspace,
        goal: StageBGoal,
        sessionID: UUID = UUID(),
        now: Date = Date()
    ) throws -> StageBSessionRecord {
        try prepareRoots()
        let directory = sessionDirectory(sessionID)
        guard !fileManager.fileExists(atPath: directory.path) else {
            throw StageBSessionStoreError.persistenceFailed
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        let record = StageBSessionRecord(
            id: sessionID,
            importID: workspace.importID,
            workspaceID: workspace.workspaceID,
            workspaceIdentitySHA256: workspace.identitySHA256,
            markerSHA256: workspace.markerSHA256,
            goal: goal,
            createdAt: now,
            updatedAt: now,
            phase: .created,
            ruleSetBindingSHA256: nil,
            rules: [],
            completion: nil,
            diagnostics: []
        )
        try persist(record)
        return record
    }

    func bindRules(
        session: StageBSessionRecord,
        ruleSet: StageBRuleSet,
        now: Date = Date()
    ) throws -> StageBSessionRecord {
        var updated = session
        guard updated.phase == .created || updated.phase == .rulesReady else {
            throw StageBSessionStoreError.invalidRecord
        }
        updated.ruleSetBindingSHA256 = ruleSet.bindingSHA256
        updated.rules = ruleSet.descriptors
        updated.phase = .rulesReady
        updated.updatedAt = now
        try persist(updated)
        return updated
    }

    func transition(
        _ session: StageBSessionRecord,
        to phase: StageBSessionPhase,
        completion: StageBCompletion? = nil,
        diagnostic: String? = nil,
        now: Date = Date()
    ) throws -> StageBSessionRecord {
        var updated = session
        updated.phase = phase
        updated.updatedAt = now
        updated.completion = completion ?? updated.completion
        if let diagnostic {
            updated.diagnostics = appendDiagnostic(diagnostic, to: updated.diagnostics)
        }
        try persist(updated)
        return updated
    }

    func record(_ evidence: StageBAttemptEvidence) throws {
        guard Self.valid(evidence, limits: limits) else {
            throw StageBSessionStoreError.invalidEvidence
        }
        do {
            let directory = sessionDirectory(evidence.sessionID)
            guard fileManager.fileExists(atPath: sessionFile(evidence.sessionID).path) else {
                throw StageBSessionStoreError.persistenceFailed
            }
            let file = attemptsFile(evidence.sessionID)
            var line = try encoder.encode(evidence)
            line.append(0x0A)
            let existing = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard existing >= 0, existing <= limits.maximumDurableEvidenceBytes - line.count else {
                throw StageBSessionStoreError.persistenceFailed
            }
            if !fileManager.fileExists(atPath: file.path) {
                guard fileManager.createFile(atPath: file.path, contents: nil) else {
                    throw StageBSessionStoreError.persistenceFailed
                }
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.synchronize()
            _ = directory
        } catch let error as StageBSessionStoreError {
            throw error
        } catch {
            throw StageBSessionStoreError.persistenceFailed
        }
    }

    func snapshot(sessionID: UUID) throws -> StageBDurableSnapshot {
        let session = try decodeSession(at: sessionFile(sessionID))
        guard Self.valid(session, limits: limits) else {
            throw StageBSessionStoreError.invalidRecord
        }
        let file = attemptsFile(sessionID)
        guard fileManager.fileExists(atPath: file.path) else {
            return StageBDurableSnapshot(session: session, attempts: [])
        }
        let fileSize = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let fileSize,
              fileSize >= 0,
              fileSize <= limits.maximumDurableEvidenceBytes else {
            throw StageBSessionStoreError.persistenceFailed
        }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        guard data.count == fileSize else { throw StageBSessionStoreError.persistenceFailed }
        var attempts: [StageBAttemptEvidence] = []
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            let evidence = try decoder.decode(StageBAttemptEvidence.self, from: Data(line))
            guard evidence.sessionID == sessionID, Self.valid(evidence, limits: limits) else {
                throw StageBSessionStoreError.invalidEvidence
            }
            attempts.append(evidence)
        }
        return StageBDurableSnapshot(session: session, attempts: attempts)
    }

    func records() throws -> [StageBSessionRecord] {
        try prepareRoots()
        return try fileManager.contentsOfDirectory(
            at: sessionsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).compactMap { url in
            let file = url.appendingPathComponent("session.json")
            guard fileManager.fileExists(atPath: file.path) else { return nil }
            return try decodeSession(at: file)
        }.sorted { $0.createdAt < $1.createdAt }
    }

    private func prepareRoots() throws {
        try fileManager.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
    }

    private func sessionDirectory(_ sessionID: UUID) -> URL {
        sessionsURL.appendingPathComponent(sessionID.uuidString.lowercased(), isDirectory: true)
    }

    private func sessionFile(_ sessionID: UUID) -> URL {
        sessionDirectory(sessionID).appendingPathComponent("session.json")
    }

    private func attemptsFile(_ sessionID: UUID) -> URL {
        sessionDirectory(sessionID).appendingPathComponent("attempts.jsonl")
    }

    private func persist(_ record: StageBSessionRecord) throws {
        guard Self.valid(record, limits: limits) else {
            throw StageBSessionStoreError.invalidRecord
        }
        let data = try encoder.encode(record)
        guard data.count <= limits.maximumDiagnosticBytes else {
            throw StageBSessionStoreError.persistenceFailed
        }
        try data.write(to: sessionFile(record.id), options: [.atomic])
    }

    private func decodeSession(at file: URL) throws -> StageBSessionRecord {
        let fileSize = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let fileSize,
              fileSize > 0,
              fileSize <= limits.maximumDiagnosticBytes else {
            throw StageBSessionStoreError.persistenceFailed
        }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        guard data.count == fileSize else { throw StageBSessionStoreError.persistenceFailed }
        let record = try decoder.decode(StageBSessionRecord.self, from: data)
        guard Self.valid(record, limits: limits) else {
            throw StageBSessionStoreError.invalidRecord
        }
        return record
    }

    private func appendDiagnostic(_ diagnostic: String, to current: [String]) -> [String] {
        let clean = diagnostic.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .prefix(96)
        let candidate = current + [String(String.UnicodeScalarView(clean))]
        guard let data = try? encoder.encode(candidate), data.count <= limits.maximumDiagnosticBytes else {
            return current
        }
        return candidate
    }

    private static func valid(_ record: StageBSessionRecord, limits: StageBLimits) -> Bool {
        guard record.rules.count <= limits.maximumRuleFiles else { return false }
        var ruleBytes = 0
        for rule in record.rules {
            guard StageBPathSyntax.valid(
                rule.relativePath,
                allowEmpty: false,
                maximumBytes: limits.maximumPathBytes
            ), StageBPathSyntax.valid(
                rule.scopePath,
                allowEmpty: true,
                maximumBytes: limits.maximumPathBytes
            ), rule.contentByteCount >= 0,
               rule.contentByteCount <= limits.maximumRuleFileBytes,
               ruleBytes <= limits.maximumRuleAggregateBytes - rule.contentByteCount,
               validHash(rule.contentSHA256) else {
                return false
            }
            ruleBytes += rule.contentByteCount
        }
        return validHash(record.workspaceIdentitySHA256)
            && validHash(record.markerSHA256)
            && validGoal(record.goal, limits: limits)
            && (record.ruleSetBindingSHA256.map(validHash) ?? true)
            && ruleBytes <= limits.maximumRuleAggregateBytes
            && (record.completion.map {
                $0.sessionID == record.id
                    && $0.workspaceIdentitySHA256 == record.workspaceIdentitySHA256
                    && $0.goalBindingSHA256 == record.goal.bindingSHA256
                    && $0.ruleSetBindingSHA256 == record.ruleSetBindingSHA256
                    && $0.query == record.goal.exactQuery
                    && StageBPathSyntax.valid(
                        $0.relativePath,
                        allowEmpty: false,
                        maximumBytes: limits.maximumPathBytes
                    )
                    && $0.providerRequestCount > 0
                    && $0.providerRequestCount <= limits.maximumProviderTurns
                    && $0.toolExecutionCount >= 3
                    && $0.toolExecutionCount <= limits.maximumToolExecutions
                    && validHash($0.evidenceChainSHA256)
            } ?? true)
    }

    private static func validGoal(_ goal: StageBGoal, limits: StageBLimits) -> Bool {
        let expectedHash = ProviderDigest.sha256Hex([
            goal.text,
            goal.exactQuery,
            goal.expectedRelativePath ?? "any"
        ].joined(separator: "\u{0}"))
        return goal.text.utf8.count > 0
            && goal.text.utf8.count <= limits.maximumGoalBytes
            && goal.exactQuery.utf8.count > 0
            && goal.exactQuery.utf8.count <= limits.maximumQueryBytes
            && (goal.expectedRelativePath.map {
                StageBPathSyntax.valid(
                    $0,
                    allowEmpty: false,
                    maximumBytes: limits.maximumPathBytes
                )
            } ?? true)
            && goal.bindingSHA256 == expectedHash
    }

    private static func valid(_ evidence: StageBAttemptEvidence, limits: StageBLimits) -> Bool {
        let hashesValid = validHash(evidence.inputSHA256)
            && (evidence.toolCallIDHash.map(validHash) ?? true)
            && (evidence.resultSHA256.map(validHash) ?? true)
        guard hashesValid,
              evidence.resultByteCount.map({ $0 >= 0 && $0 <= limits.maximumExecutorStreamBytes }) ?? true else {
            return false
        }
        if let observation = evidence.observation {
            guard evidence.kind == .executor,
                  evidence.phase == .succeeded,
                  evidence.category == .observation,
                  observation.listedEntries.map({ $0.count <= limits.maximumListEntries }) ?? true,
                  observation.matches.map({ $0.count <= limits.maximumSearchMatches }) ?? true,
                  observation.readContentByteCount.map({ $0 <= limits.maximumReadBytes }) ?? true,
                  observation.listedEntries.map({ entries in
                      entries.allSatisfy {
                          StageBPathSyntax.valid(
                              $0,
                              allowEmpty: false,
                              maximumBytes: limits.maximumPathBytes
                          ) && !$0.contains("/")
                      }
                  }) ?? true,
                  observation.matches.map({ matches in
                      matches.allSatisfy {
                          StageBPathSyntax.valid(
                              $0.path,
                              allowEmpty: false,
                              maximumBytes: limits.maximumPathBytes
                          )
                              && $0.line > 0
                              && $0.textByteCount >= 0
                              && $0.textByteCount <= limits.maximumLineBytes
                              && $0.exactQueryOccurrences >= 0
                              && validHash($0.textSHA256)
                      }
                  }) ?? true,
                  validHash(observation.ruleSetSHA256),
                  validHash(observation.observationSHA256),
                  observation.querySHA256.map(validHash) ?? true,
                  observation.readContentSHA256.map(validHash) ?? true else {
                return false
            }
        }
        if let outcome = evidence.providerOutcome {
            let contentBytes = outcome.assistantContentByteCount
            let callBytes = outcome.toolCalls.reduce(0) {
                $0 + $1.id.utf8.count + $1.name.utf8.count + $1.arguments.utf8.count + 96
            }
            let decisionShapeValid: Bool
            if evidence.category == .providerToolCalls {
                decisionShapeValid = !outcome.toolCalls.isEmpty
            } else {
                decisionShapeValid = outcome.toolCalls.isEmpty
                    && contentBytes > 0
                    && outcome.assistantContentSHA256 != nil
            }
            guard evidence.kind == .provider,
                  evidence.phase == .succeeded,
                  evidence.category == .providerToolCalls || evidence.category == .providerFinish,
                  contentBytes >= 0,
                  contentBytes <= ProviderLimits.maximumTurnMessageBytes,
                  contentBytes <= limits.maximumContextBytes,
                  outcome.assistantContentSHA256.map(validHash) ?? true,
                  callBytes <= limits.maximumContextBytes - contentBytes,
                  Set(outcome.toolCalls.map(\.id)).count == outcome.toolCalls.count,
                  outcome.toolCalls.allSatisfy({
                      validOpaqueIdentifier(
                          $0.id,
                          maximumBytes: ProviderLimits.maximumToolCallIDBytes
                      )
                          && validToolName($0.name)
                          && !$0.arguments.isEmpty
                          && $0.arguments.utf8.count <= ProviderLimits.maximumToolArgumentsBytes
                  }),
                  decisionShapeValid else {
                return false
            }
        }
        if let rejection = evidence.policyRejection {
            guard evidence.kind == .executor,
                  evidence.phase == .failed,
                  evidence.category == .policyNotExecuted,
                  rejection.callIndex.map({
                      $0 >= 0 && $0 < limits.maximumToolExecutions
                  }) ?? true else {
                return false
            }
        }
        return true
    }

    private static func validOpaqueIdentifier(_ value: String, maximumBytes: Int) -> Bool {
        let bytes = value.utf8.count
        return bytes > 0
            && bytes <= maximumBytes
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
    }

    private static func validToolName(_ value: String) -> Bool {
        validOpaqueIdentifier(value, maximumBytes: ProviderLimits.maximumToolNameBytes)
            && value.unicodeScalars.allSatisfy {
                CharacterSet.lowercaseLetters.contains($0)
                    || CharacterSet.decimalDigits.contains($0)
                    || $0 == "_"
            }
    }

    private static func validHash(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdef").contains($0)
        }
    }
}

struct StageBWorkspaceResolver: Sendable {
    private let store: StageAWorkspaceStore
    private let fileManager: FileManager

    init(store: StageAWorkspaceStore, fileManager: FileManager = .default) {
        self.store = store
        self.fileManager = fileManager
    }

    func openReadyWorkspace(importID: UUID, now: Date = Date()) throws -> StageBReadyWorkspace {
        let records = try store.recover(now: now)
        guard let record = records.first(where: { $0.id == importID }), record.phase == .ready else {
            throw StageBError.workspaceNotReady
        }
        let root = store.workspaceURL(for: record.workspaceID)
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalWorkspaces = store.workspacesRootURL.standardizedFileURL.resolvingSymlinksInPath()
        let rootComponents = canonicalRoot.pathComponents
        let parentComponents = canonicalWorkspaces.pathComponents
        guard rootComponents.count == parentComponents.count + 1,
              Array(rootComponents.prefix(parentComponents.count)) == parentComponents else {
            throw StageBError.workspaceBindingMismatch
        }
        let rootValues = try canonicalRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw StageBError.workspaceUnavailable
        }
        let markerURL = canonicalRoot.appendingPathComponent(StageAWorkspaceMarker.fileName)
        let markerValues = try markerURL.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
        ])
        guard markerValues.isRegularFile == true,
              markerValues.isSymbolicLink != true,
              (markerValues.fileSize ?? 16_385) <= 16_384 else {
            throw StageBError.workspaceBindingMismatch
        }
        let markerData = try Data(contentsOf: markerURL, options: .mappedIfSafe)
        let decoder = JSONDecoder()
        let marker = try decoder.decode(StageAWorkspaceMarker.self, from: markerData)
        guard marker.importID == record.id,
              marker.workspaceID == record.workspaceID,
              marker.entryCount == record.entryCount,
              marker.totalOutputBytes == record.totalOutputBytes else {
            throw StageBError.workspaceBindingMismatch
        }
        let markerHash = ProviderDigest.sha256Hex(markerData)
        let identity = ProviderDigest.sha256Hex([
            record.id.uuidString.lowercased(),
            record.workspaceID.uuidString.lowercased(),
            markerHash,
            ProviderDigest.sha256Hex(canonicalRoot.path)
        ].joined(separator: "\u{0}"))
        return StageBReadyWorkspace(
            importID: record.id,
            workspaceID: record.workspaceID,
            canonicalRootURL: canonicalRoot,
            identitySHA256: identity,
            markerSHA256: markerHash
        )
    }
}
