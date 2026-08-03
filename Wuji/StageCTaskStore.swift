import Foundation

struct StageCTaskRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let sessionID: UUID
    let importID: UUID
    let workspaceID: UUID
    let workspaceIdentitySHA256: String
    let workspaceRootSHA256: String
    let markerSHA256: String
    let goalBindingSHA256: String
    let ruleSetBindingSHA256: String
    let targetRelativePath: String
    let createdAt: Date
    var updatedAt: Date
    var phase: StageCTaskPhase
    var providerFinishObserved: Bool
    var proposal: StageCEditProposal?
    var approvals: [StageCApprovalEvidence]
    var attempts: [StageCAttemptEvidence]
    var completion: StageCCompletion?
}

enum StageCTaskStoreError: Error, Equatable {
    case invalidRecord
    case alreadyExists
    case notFound
    case evidenceLimit
    case persistenceFailed
}

actor StageCTaskStore {
    let rootURL: URL
    private let recordsURL: URL
    private let limits: StageCLimits
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fileManager: FileManager

    init(
        rootURL: URL,
        limits: StageCLimits = .production,
        fileManager: FileManager = .default
    ) throws {
        self.rootURL = rootURL
        self.limits = limits
        self.fileManager = fileManager
        recordsURL = rootURL.appendingPathComponent("Tasks", isDirectory: true)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        try fileManager.createDirectory(at: recordsURL, withIntermediateDirectories: true)
    }

    static func applicationStore(limits: StageCLimits = .production) throws -> StageCTaskStore {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return try StageCTaskStore(
            rootURL: support.appendingPathComponent("WujiStageC", isDirectory: true),
            limits: limits
        )
    }

    func create(
        id: UUID = UUID(),
        session: StageBSessionRecord,
        workspace: StageBReadyWorkspace,
        ruleSet: StageBRuleSet,
        targetRelativePath: String,
        now: Date = Date()
    ) throws -> StageCTaskRecord {
        guard session.phase == .completed,
              session.completion != nil,
              session.importID == workspace.importID,
              session.workspaceID == workspace.workspaceID,
              session.workspaceIdentitySHA256 == workspace.identitySHA256,
              session.markerSHA256 == workspace.markerSHA256,
              session.goal.bindingSHA256 == session.completion?.goalBindingSHA256,
              session.ruleSetBindingSHA256 == ruleSet.bindingSHA256,
              StageBPathSyntax.valid(
                targetRelativePath,
                allowEmpty: false,
                maximumBytes: limits.maximumPathBytes
              ) else { throw StageCTaskStoreError.invalidRecord }
        let url = recordURL(id)
        guard !fileManager.fileExists(atPath: url.path) else {
            throw StageCTaskStoreError.alreadyExists
        }
        let record = StageCTaskRecord(
            id: id,
            sessionID: session.id,
            importID: session.importID,
            workspaceID: session.workspaceID,
            workspaceIdentitySHA256: session.workspaceIdentitySHA256,
            workspaceRootSHA256: ProviderDigest.sha256Hex(workspace.canonicalRootURL.path),
            markerSHA256: session.markerSHA256,
            goalBindingSHA256: session.goal.bindingSHA256,
            ruleSetBindingSHA256: ruleSet.bindingSHA256,
            targetRelativePath: targetRelativePath,
            createdAt: now,
            updatedAt: now,
            phase: .ready,
            providerFinishObserved: false,
            proposal: nil,
            approvals: [],
            attempts: [],
            completion: nil
        )
        try persist(record)
        return record
    }

    func record(_ record: StageCTaskRecord) throws {
        guard fileManager.fileExists(atPath: recordURL(record.id).path) else {
            throw StageCTaskStoreError.notFound
        }
        try persist(record)
    }

    func update(
        taskID: UUID,
        phase: StageCTaskPhase? = nil,
        providerFinishObserved: Bool? = nil,
        proposal: StageCEditProposal? = nil,
        approval: StageCApprovalEvidence? = nil,
        attempt: StageCAttemptEvidence? = nil,
        completion: StageCCompletion? = nil,
        now: Date = Date()
    ) throws -> StageCTaskRecord {
        var record = try load(taskID)
        if let phase { record.phase = phase }
        if let providerFinishObserved { record.providerFinishObserved = providerFinishObserved }
        if let proposal { record.proposal = proposal }
        if let approval { record.approvals.append(approval) }
        if let attempt { record.attempts.append(attempt) }
        if let completion { record.completion = completion }
        record.updatedAt = now
        try persist(record)
        return record
    }

    func snapshot(taskID: UUID) throws -> StageCTaskRecord { try load(taskID) }

    func records() throws -> [StageCTaskRecord] {
        try fileManager.contentsOfDirectory(
            at: recordsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }
        .map { try decode(Data(contentsOf: $0, options: .mappedIfSafe)) }
        .sorted { $0.createdAt < $1.createdAt }
    }

    private func recordURL(_ id: UUID) -> URL {
        recordsURL.appendingPathComponent(id.uuidString.lowercased() + ".json")
    }

    private func load(_ id: UUID) throws -> StageCTaskRecord {
        let url = recordURL(id)
        guard fileManager.fileExists(atPath: url.path) else { throw StageCTaskStoreError.notFound }
        do { return try decode(Data(contentsOf: url, options: .mappedIfSafe)) }
        catch let error as StageCTaskStoreError { throw error }
        catch { throw StageCTaskStoreError.persistenceFailed }
    }

    private func decode(_ data: Data) throws -> StageCTaskRecord {
        guard data.count <= limits.maximumDurableEvidenceBytes else {
            throw StageCTaskStoreError.evidenceLimit
        }
        let record = try decoder.decode(StageCTaskRecord.self, from: data)
        guard valid(record) else { throw StageCTaskStoreError.invalidRecord }
        return record
    }

    private func persist(_ record: StageCTaskRecord) throws {
        guard valid(record) else { throw StageCTaskStoreError.invalidRecord }
        do {
            let data = try encoder.encode(record)
            guard data.count <= limits.maximumDurableEvidenceBytes else {
                throw StageCTaskStoreError.evidenceLimit
            }
            if record.proposal != nil {
                let proposalData = try encoder.encode(record.proposal)
                guard proposalData.count <= limits.maximumProposalRecordBytes else {
                    throw StageCTaskStoreError.evidenceLimit
                }
            }
            try data.write(to: recordURL(record.id), options: [.atomic])
        } catch let error as StageCTaskStoreError {
            throw error
        } catch {
            throw StageCTaskStoreError.persistenceFailed
        }
    }

    private func valid(_ record: StageCTaskRecord) -> Bool {
        let bindingHashes = [
            record.workspaceIdentitySHA256, record.workspaceRootSHA256,
            record.markerSHA256, record.goalBindingSHA256, record.ruleSetBindingSHA256
        ]
        guard bindingHashes.allSatisfy(Self.validHash),
              StageBPathSyntax.valid(
                record.targetRelativePath,
                allowEmpty: false,
                maximumBytes: limits.maximumPathBytes
              ),
              record.attempts.allSatisfy({ $0.taskID == record.id && Self.valid($0) }),
              record.approvals.allSatisfy({ $0.request.taskID == record.id && Self.valid($0) }) else {
            return false
        }
        var attemptsByID: [UUID: [StageCAttemptEvidence]] = [:]
        for attempt in record.attempts {
            attemptsByID[attempt.attemptID, default: []].append(attempt)
        }
        let intents = record.attempts.filter { $0.phase == .intentRecorded }
        guard Set(intents.map(\.attemptID)).count == intents.count,
              Set(intents.map(\.operationID)).count == intents.count else { return false }
        guard attemptsByID.values.allSatisfy({ pair in
            guard pair.count == 1 || pair.count == 2,
                  pair[0].phase == .intentRecorded else { return false }
            if pair.count == 1 { return true }
            let terminal = pair[1]
            return terminal.phase != .intentRecorded
                && terminal.operationID == pair[0].operationID
                && terminal.ioKind == pair[0].ioKind
                && terminal.inputSHA256 == pair[0].inputSHA256
                && terminal.toolCallID == pair[0].toolCallID
                && terminal.recordedAt >= pair[0].recordedAt
        }) else { return false }
        var approvalsByID: [UUID: [StageCApprovalEvidence]] = [:]
        record.approvals.forEach {
            approvalsByID[$0.request.requestID, default: []].append($0)
        }
        guard approvalsByID.values.allSatisfy(Self.validApprovalSequence) else { return false }
        if let proposal = record.proposal {
            let material = StageCEditProposal.bindingMaterial(
                taskID: proposal.taskID,
                toolCallID: proposal.toolCallID,
                relativePath: proposal.relativePath,
                expectedOld: proposal.expectedOld,
                replacement: proposal.replacement,
                beforeSHA256: proposal.beforeSHA256,
                afterSHA256: proposal.afterSHA256,
                beforeTreeSHA256: proposal.beforeTreeSHA256,
                expectedAfterTreeSHA256: proposal.expectedAfterTreeSHA256,
                diffSHA256: proposal.diffSHA256,
                createdAt: proposal.createdAt
            )
            let lines = proposal.diff.split(separator: "\n", omittingEmptySubsequences: false)
            guard proposal.taskID == record.id,
                  proposal.relativePath == record.targetRelativePath,
                  !proposal.expectedOld.isEmpty,
                  !proposal.replacement.isEmpty,
                  proposal.expectedOld != proposal.replacement,
                  !proposal.expectedOld.contains("\n"),
                  !proposal.replacement.contains("\n"),
                  !proposal.expectedOld.contains("\r"),
                  !proposal.replacement.contains("\r"),
                  proposal.expectedOld.utf8.count <= ProviderLimits.maximumToolArgumentsBytes,
                  proposal.replacement.utf8.count <= ProviderLimits.maximumToolArgumentsBytes,
                  StageBPathSyntax.valid(
                    proposal.relativePath,
                    allowEmpty: false,
                    maximumBytes: limits.maximumPathBytes
                  ),
                  Self.validHash(proposal.beforeSHA256),
                  Self.validHash(proposal.afterSHA256),
                  Self.validHash(proposal.beforeTreeSHA256),
                  Self.validHash(proposal.expectedAfterTreeSHA256),
                  Self.validHash(proposal.diffSHA256),
                  Self.validHash(proposal.proposalSHA256),
                  lines == [
                    Substring("--- a/\(proposal.relativePath)"),
                    Substring("+++ b/\(proposal.relativePath)"),
                    Substring("@@ exact single replacement @@"),
                    Substring("-\(proposal.expectedOld)"),
                    Substring("+\(proposal.replacement)"),
                    Substring("")
                  ],
                  ProviderDigest.sha256Hex(proposal.diff) == proposal.diffSHA256,
                  ProviderDigest.sha256Hex(material) == proposal.proposalSHA256 else { return false }
        }
        return record.completion.map {
            $0.taskID == record.id
                && $0.sessionID == record.sessionID
                && $0.workspaceIdentitySHA256 == record.workspaceIdentitySHA256
                && $0.goalBindingSHA256 == record.goalBindingSHA256
                && $0.ruleSetBindingSHA256 == record.ruleSetBindingSHA256
                && Self.validHash($0.proposalSHA256)
                && Self.validHash($0.finalTreeSHA256)
        } ?? true
    }

    private static func valid(_ attempt: StageCAttemptEvidence) -> Bool {
        guard validHash(attempt.inputSHA256)
            && (attempt.resultSHA256.map(validHash) ?? true)
            && (attempt.toolCallID.map {
                !$0.isEmpty && $0.utf8.count <= ProviderLimits.maximumToolCallIDBytes
            } ?? true)
            && ((attempt.phase == .intentRecorded || attempt.phase == .reconciliationRequired)
                ? attempt.resultSHA256 == nil && attempt.facts == nil
                : true) else { return false }
        if attempt.ioKind == .mutationExecutor, attempt.phase == .succeeded {
            guard let facts = attempt.facts,
                  facts.terminalBarrierSatisfied,
                  !facts.truncated,
                  facts.finalStateKind == "exited",
                  facts.finalStateValue == 0 else { return false }
        }
        return true
    }

    private static func valid(_ approval: StageCApprovalEvidence) -> Bool {
        let request = approval.request
        guard validHash(request.bindingSHA256),
              validHash(request.workspaceIdentitySHA256),
              validHash(request.workspaceRootSHA256),
              validHash(request.markerSHA256),
              validHash(request.goalBindingSHA256),
              validHash(request.ruleSetBindingSHA256),
              validHash(request.proposalSHA256),
              validHash(request.beforeSHA256),
              validHash(request.afterSHA256),
              validHash(request.diffSHA256),
              request.expiresAt > request.createdAt,
              approval.recordedAt >= request.createdAt else { return false }
        if approval.state == .approved || approval.state == .consumed {
            guard let grant = approval.grant else { return false }
            return grant.requestID == request.requestID
                && grant.requestBindingSHA256 == request.bindingSHA256
                && grant.nonce == request.nonce
                && grant.approvedAt >= request.createdAt
                && grant.approvedAt <= request.expiresAt
        }
        return approval.grant == nil
    }

    private static func validApprovalSequence(_ evidence: [StageCApprovalEvidence]) -> Bool {
        guard let first = evidence.first,
              first.state == .pending,
              evidence.allSatisfy({ $0.request == first.request }),
              zip(evidence, evidence.dropFirst()).allSatisfy({ pair in
                pair.1.recordedAt >= pair.0.recordedAt
              }) else {
            return false
        }
        let states = evidence.map(\.state)
        return states == [.pending]
            || states == [.pending, .approved]
            || states == [.pending, .approved, .consumed]
            || states == [.pending, .approved, .expired]
            || states == [.pending, .rejected]
            || states == [.pending, .cancelled]
            || states == [.pending, .expired]
    }

    private static func validHash(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdef").contains($0)
        }
    }
}
