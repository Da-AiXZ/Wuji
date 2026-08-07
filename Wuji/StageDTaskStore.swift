import Foundation

enum StageDTaskStoreError: Error, Equatable {
    case invalidRecord
    case alreadyExists
    case notFound
    case evidenceLimit
    case persistenceFailed
}

actor StageDTaskStore {
    let rootURL: URL
    let cloneRootURL: URL
    private let recordsURL: URL
    private let limits: StageDLimits
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        rootURL: URL,
        cloneRootURL: URL,
        limits: StageDLimits = .production,
        fileManager: FileManager = .default
    ) throws {
        self.rootURL = rootURL
        self.cloneRootURL = cloneRootURL
        self.limits = limits
        self.fileManager = fileManager
        recordsURL = rootURL.appendingPathComponent("Tasks", isDirectory: true)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let milliseconds = date.timeIntervalSince1970 * 1_000
            guard milliseconds.isFinite,
                  milliseconds >= Double(Int64.min),
                  milliseconds <= Double(Int64.max) else {
                throw EncodingError.invalidValue(
                    date,
                    .init(codingPath: encoder.codingPath, debugDescription: "Date is outside durable range")
                )
            }
            try container.encode(Int64(milliseconds.rounded()))
        }
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let milliseconds = try container.decode(Double.self)
            guard milliseconds.isFinite,
                  milliseconds >= Double(Int64.min),
                  milliseconds <= Double(Int64.max) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Durable date is outside supported range"
                )
            }
            return Date(timeIntervalSince1970: milliseconds.rounded() / 1_000)
        }
        try fileManager.createDirectory(at: recordsURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: cloneRootURL, withIntermediateDirectories: true)
    }

    static func applicationStore(limits: StageDLimits = .production) throws -> StageDTaskStore {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return try StageDTaskStore(
            rootURL: support.appendingPathComponent("WujiStageD", isDirectory: true),
            cloneRootURL: support.appendingPathComponent("WujiStageDCloneWorkspaces", isDirectory: true),
            limits: limits
        )
    }

    func create(
        id: UUID = UUID(),
        session: StageBSessionRecord,
        workspace: StageBReadyWorkspace,
        ruleSet: StageBRuleSet,
        write: StageDBoundedWrite?,
        expectation: StageDCompletionExpectation,
        now: Date = Date()
    ) throws -> StageDTaskRecord {
        guard session.phase == .completed,
              session.completion != nil,
              session.importID == workspace.importID,
              session.workspaceID == workspace.workspaceID,
              session.workspaceIdentitySHA256 == workspace.identitySHA256,
              session.ruleSetBindingSHA256 == ruleSet.bindingSHA256,
              Self.validHash(session.goal.bindingSHA256),
              Self.validExpectation(expectation),
              write.map(Self.validWrite) ?? true else {
            throw StageDTaskStoreError.invalidRecord
        }
        guard !fileManager.fileExists(atPath: recordURL(id).path) else {
            throw StageDTaskStoreError.alreadyExists
        }
        return try persist(.init(
            id: id,
            sessionID: session.id,
            importID: session.importID,
            workspaceID: session.workspaceID,
            workspaceIdentitySHA256: workspace.identitySHA256,
            workspaceRootSHA256: ProviderDigest.sha256Hex(workspace.canonicalRootURL.path),
            goalBindingSHA256: session.goal.bindingSHA256,
            ruleSetBindingSHA256: ruleSet.bindingSHA256,
            cloneRootSHA256: ProviderDigest.sha256Hex(cloneRootURL.path),
            write: write,
            expectation: expectation,
            createdAt: now,
            updatedAt: now,
            phase: .ready,
            approvals: [],
            attempts: [],
            completion: nil
        ))
    }

    func snapshot(taskID: UUID) throws -> StageDTaskRecord { try load(taskID) }

    func records() throws -> [StageDTaskRecord] {
        try fileManager.contentsOfDirectory(
            at: recordsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }
        .map { try decode(Data(contentsOf: $0, options: .mappedIfSafe)) }
        .sorted { $0.createdAt < $1.createdAt }
    }

    func appendApproval(
        taskID: UUID,
        evidence: StageDApprovalEvidence,
        phase: StageDTaskPhase
    ) throws -> StageDTaskRecord {
        try mutate(taskID) {
            $0.approvals.append(evidence)
            $0.phase = phase
        }
    }

    func appendAttempt(
        taskID: UUID,
        evidence: StageDAttemptEvidence,
        phase: StageDTaskPhase
    ) throws -> StageDTaskRecord {
        try mutate(taskID) {
            $0.attempts.append(evidence)
            $0.phase = phase
        }
    }

    func consumeApprovalAndRecordIntent(
        taskID: UUID,
        request: StageDApprovalRequest,
        grant: StageDApprovalGrant,
        intent: StageDAttemptEvidence,
        now: Date
    ) throws -> StageDTaskRecord {
        try mutate(taskID, now: now) { record in
            guard let latest = record.approvals.last,
                  latest.request == request,
                  latest.state == .approved,
                  latest.grant == grant,
                  grant.requestBindingSHA256 == request.bindingSHA256,
                  grant.requestID == request.requestID,
                  grant.nonce == request.nonce,
                  grant.approvedAt <= request.expiresAt,
                  intent.phase == .intentRecorded,
                  intent.kind == .command,
                  intent.operationID == request.operationID,
                  intent.attemptID == request.attemptID,
                   intent.command?.bindingSHA256 == request.commandBindingSHA256,
                   intent.approvalBindingSHA256 == request.bindingSHA256,
                   intent.providerDecisionSHA256 == request.providerDecisionSHA256 else {
                throw StageDTaskStoreError.invalidRecord
            }
            record.approvals.append(.init(
                request: request,
                state: .consumed,
                recordedAt: now,
                grant: grant
            ))
            record.attempts.append(intent)
            record.phase = .executing
        }
    }

    func complete(taskID: UUID, completion: StageDCompletion) throws -> StageDTaskRecord {
        try mutate(taskID, now: completion.completedAt) {
            $0.completion = completion
            $0.phase = .completed
        }
    }

    func setPhase(taskID: UUID, phase: StageDTaskPhase, now: Date = Date()) throws -> StageDTaskRecord {
        try mutate(taskID, now: now) { $0.phase = phase }
    }

    private func mutate(
        _ id: UUID,
        now: Date = Date(),
        _ change: (inout StageDTaskRecord) throws -> Void
    ) throws -> StageDTaskRecord {
        var record = try load(id)
        try change(&record)
        record.updatedAt = now
        return try persist(record)
    }

    private func recordURL(_ id: UUID) -> URL {
        recordsURL.appendingPathComponent(id.uuidString.lowercased() + ".json")
    }

    private func load(_ id: UUID) throws -> StageDTaskRecord {
        let url = recordURL(id)
        guard fileManager.fileExists(atPath: url.path) else { throw StageDTaskStoreError.notFound }
        do { return try decode(Data(contentsOf: url, options: .mappedIfSafe)) }
        catch let error as StageDTaskStoreError { throw error }
        catch { throw StageDTaskStoreError.persistenceFailed }
    }

    private func decode(_ data: Data) throws -> StageDTaskRecord {
        guard data.count <= limits.maximumDurableEvidenceBytes else {
            throw StageDTaskStoreError.evidenceLimit
        }
        let record = try decoder.decode(StageDTaskRecord.self, from: data)
        guard valid(record) else { throw StageDTaskStoreError.invalidRecord }
        return record
    }

    private func persist(_ record: StageDTaskRecord) throws -> StageDTaskRecord {
        do {
            let data = try encoder.encode(record)
            guard data.count <= limits.maximumDurableEvidenceBytes else {
                throw StageDTaskStoreError.evidenceLimit
            }
            let canonical = try decoder.decode(StageDTaskRecord.self, from: data)
            guard valid(canonical) else { throw StageDTaskStoreError.invalidRecord }
            try data.write(to: recordURL(record.id), options: [.atomic])
            return canonical
        } catch let error as StageDTaskStoreError {
            throw error
        } catch {
            throw StageDTaskStoreError.persistenceFailed
        }
    }

    private func valid(_ record: StageDTaskRecord) -> Bool {
        guard [record.workspaceIdentitySHA256, record.workspaceRootSHA256,
               record.goalBindingSHA256, record.ruleSetBindingSHA256,
               record.cloneRootSHA256].allSatisfy(Self.validHash),
              Self.validExpectation(record.expectation),
              record.write.map(Self.validWrite) ?? true,
              record.approvals.allSatisfy({ $0.request.taskID == record.id && Self.valid($0) }),
              record.attempts.allSatisfy({ $0.taskID == record.id && Self.valid($0) }) else {
            return false
        }
        var approvalsByID: [UUID: [StageDApprovalEvidence]] = [:]
        record.approvals.forEach {
            approvalsByID[$0.request.requestID, default: []].append($0)
        }
        guard approvalsByID.values.allSatisfy(Self.validApprovalSequence) else { return false }
        var pairs: [UUID: [StageDAttemptEvidence]] = [:]
        record.attempts.forEach { pairs[$0.attemptID, default: []].append($0) }
        guard pairs.values.allSatisfy({ evidence in
            guard evidence.count == 1 || evidence.count == 2,
                  evidence[0].phase == .intentRecorded else { return false }
            if evidence.count == 1 { return true }
            let intent = evidence[0], terminal = evidence[1]
            return terminal.phase != .intentRecorded
                && terminal.operationID == intent.operationID
                && terminal.kind == intent.kind
                && terminal.inputSHA256 == intent.inputSHA256
                && terminal.command == intent.command
                && terminal.approvalBindingSHA256 == intent.approvalBindingSHA256
                && terminal.providerDecisionSHA256 == intent.providerDecisionSHA256
                && terminal.recordedAt >= intent.recordedAt
        }) else { return false }
        let providerDecisionDigests = Set(record.attempts.compactMap { evidence in
            evidence.kind == .provider && evidence.phase == .succeeded
                ? evidence.resultSHA256 : nil
        })
        let providerDecisions = record.attempts.compactMap { evidence -> (String, StageDProviderDecision)? in
            guard evidence.kind == .provider,
                  evidence.phase == .succeeded,
                  let digest = evidence.resultSHA256,
                  let decision = evidence.providerDecision else { return nil }
            return (digest, decision)
        }
        guard record.approvals.allSatisfy({ approval in
            approval.request.providerDecisionSHA256.map(providerDecisionDigests.contains) ?? true
        }), record.attempts.filter({ $0.kind == .command }).allSatisfy({ evidence in
            guard let binding = evidence.providerDecisionSHA256 else { return true }
            guard let command = evidence.command else { return false }
            return providerDecisions.contains { pair in
                pair.0 == binding
                    && (try? StageDCommandParser.parse(
                        command: pair.1.command,
                        cwd: pair.1.cwd
                    )) == command.parsed
            }
        }) else { return false }
        let consumedApprovals = record.approvals.filter { $0.state == .consumed }
        guard record.attempts.filter({ $0.kind == .command }).allSatisfy({ evidence in
            guard let command = evidence.command else { return false }
            if !command.risk.requiresApproval { return evidence.approvalBindingSHA256 == nil }
            guard let approvalBindingSHA256 = evidence.approvalBindingSHA256 else { return false }
            return consumedApprovals.contains { approval in
                let request = approval.request
                return request.taskID == record.id
                    && request.operationID == evidence.operationID
                    && request.attemptID == evidence.attemptID
                    && request.workspaceIdentitySHA256 == record.workspaceIdentitySHA256
                    && request.commandBindingSHA256 == command.bindingSHA256
                    && request.command == command.parsed.original
                    && request.argumentsSHA256 == ProviderDigest.sha256Hex(
                        command.parsed.arguments.joined(separator: "\u{0}")
                    )
                    && request.cwd == command.parsed.cwd
                    && request.risk == command.risk
                    && request.executionRoot == command.executionRoot
                    && request.providerDecisionSHA256 == evidence.providerDecisionSHA256
                    && request.bindingSHA256 == approvalBindingSHA256
            }
        }) else { return false }
        if let completion = record.completion {
            guard completion.taskID == record.id,
                  completion.sessionID == record.sessionID,
                  completion.workspaceIdentitySHA256 == record.workspaceIdentitySHA256,
                  Self.validHash(completion.commandBindingSHA256),
                  Self.validHash(completion.resultSHA256),
                  Self.validHash(completion.verificationSHA256),
                  completion.approvalBindingSHA256.map(Self.validHash) ?? true,
                  record.attempts.contains(where: {
                      $0.operationID == completion.operationID
                          && $0.attemptID == completion.attemptID
                          && $0.phase == .succeeded
                          && $0.command?.bindingSHA256 == completion.commandBindingSHA256
                          && $0.resultSHA256 == completion.resultSHA256
                          && $0.result?.verificationSHA256 == completion.verificationSHA256
                          && $0.providerDecisionSHA256 == completion.providerDecisionSHA256
                  }) else { return false }
        }
        return true
    }

    private static func valid(_ evidence: StageDAttemptEvidence) -> Bool {
        guard validHash(evidence.inputSHA256),
              evidence.resultSHA256.map(validHash) ?? true,
              evidence.approvalBindingSHA256.map(validHash) ?? true,
              evidence.providerDecisionSHA256.map(validHash) ?? true else { return false }
        if evidence.phase == .intentRecorded {
            guard evidence.result == nil && evidence.resultSHA256 == nil else { return false }
        }
        switch evidence.kind {
        case .provider:
            guard evidence.command == nil,
                  evidence.approvalBindingSHA256 == nil,
                  evidence.providerDecisionSHA256 == nil else { return false }
            if evidence.phase == .succeeded {
                guard let decision = evidence.providerDecision else { return false }
                return decision.expectedInputSHA256 == evidence.inputSHA256
                    && validHash(decision.assistantSHA256)
                    && validHash(decision.expectedInputSHA256)
                    && !decision.toolCallID.isEmpty
                    && decision.toolCallID.utf8.count <= ProviderLimits.maximumToolCallIDBytes
                    && decision.command.utf8.count <= StageDLimits.production.maximumCommandBytes
                    && decision.cwd.utf8.count <= StageDLimits.production.maximumCWDBytes
                    && evidence.resultSHA256 == digest(decision)
            }
        case .command:
            guard let command = evidence.command,
                  evidence.providerDecision == nil,
                  evidence.inputSHA256 == command.bindingSHA256 else { return false }
            if evidence.phase == .succeeded {
                guard let result = evidence.result,
                      result.verified,
                      result.commandBindingSHA256 == command.bindingSHA256,
                      valid(result),
                      evidence.resultSHA256 == digest(result) else { return false }
            }
            if evidence.phase == .reconciliationRequired, let result = evidence.result {
                guard valid(result), evidence.resultSHA256 == digest(result) else { return false }
                if let filesystem = result.cloneFilesystemEvidence,
                   !filesystem.probe.requiresReconciliation,
                   !result.cloneStages.contains(where: { $0.category == .timeoutUnknown }),
                   !result.facts.contains(where: {
                       !$0.rootExitObserved || $0.finalStateKind == "unknown" ||
                           $0.cancellationRequested || $0.processTreeState != .quiescent
                   }) {
                    return false
                }
            }
            if evidence.phase == .failed, let result = evidence.result {
                guard valid(result),
                      result.cloneFilesystemEvidence?.probe.requiresReconciliation != true,
                      evidence.resultSHA256 == digest(result) else { return false }
            }
        }
        return true
    }

    private static func valid(_ approval: StageDApprovalEvidence) -> Bool {
        let request = approval.request
        guard validHash(request.workspaceIdentitySHA256),
              validHash(request.commandBindingSHA256),
              validHash(request.argumentsSHA256),
              validHash(request.bindingSHA256),
              request.providerDecisionSHA256.map(validHash) ?? true,
              request.command.utf8.count <= StageDLimits.production.maximumCommandBytes,
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

    private static func validApprovalSequence(_ evidence: [StageDApprovalEvidence]) -> Bool {
        guard let first = evidence.first,
              first.state == .pending,
              evidence.allSatisfy({ $0.request == first.request }),
              zip(evidence, evidence.dropFirst()).allSatisfy({ $0.1.recordedAt >= $0.0.recordedAt }) else {
            return false
        }
        let states = evidence.map(\.state)
        return states == [.pending]
            || states == [.pending, .approved]
            || states == [.pending, .approved, .consumed]
            || states == [.pending, .rejected]
            || states == [.pending, .cancelled]
            || states == [.pending, .expired]
    }

    private static func validWrite(_ write: StageDBoundedWrite) -> Bool {
        validHash(write.expectedBeforeSHA256)
            && validHash(write.expectedAfterSHA256)
            && !write.expectedBeforeLine.isEmpty
            && !write.replacementLine.isEmpty
            && write.expectedBeforeLine != write.replacementLine
            && !write.expectedBeforeLine.contains("/")
            && !write.replacementLine.contains("/")
            && (try? StageDCommandParser.normalizeRelativePath(
                write.relativePath,
                allowEmpty: false
            )) != nil
    }

    private static func valid(_ result: StageDCommandResult) -> Bool {
        guard validHash(result.commandBindingSHA256),
              validHash(result.verificationSHA256),
              result.facts.allSatisfy({ facts in
                  facts.stdoutByteCount >= 0
                      && facts.stderrByteCount >= 0
                      && facts.activeDescendantCount >= 0
                      && ["not_run", "exited", "signaled", "unknown"]
                          .contains(facts.finalStateKind)
                      && validHash(facts.stdoutSHA256)
                      && validHash(facts.stderrSHA256)
              }),
              (try? result.safeDiagnosticSummaryData().count).map({ $0 <= 8 * 1_024 }) == true else {
            return false
        }
        if result.cloneStages.isEmpty {
            return result.cloneRemote == nil
                && result.cloneHEAD == nil
                && result.cloneEntryCount == nil
                && result.cloneByteCount == nil
                && result.cloneFilesystemEvidence == nil
        }
        guard result.cloneStages.map(\.stage) == StageDCloneStage.allCases,
              let filesystem = result.cloneFilesystemEvidence,
              valid(filesystem),
              filesystem.blockingSubcategory == (
                  filesystem.preflight.failureSubcategory
                      ?? filesystem.probe.failureSubcategory
                      ?? result.cloneStages.compactMap(\.filesystemSubcategory).first
              ),
              result.cloneStages.allSatisfy({ outcome in
                  outcome.observedValueSHA256.map(validHash) ?? true
                      && (outcome.entryCount ?? 0) >= 0
                      && outcome.facts.stdoutByteCount >= 0
                      && outcome.facts.stderrByteCount >= 0
                      && (outcome.category == .filesystemFailure
                          ? outcome.filesystemSubcategory != nil
                          : outcome.filesystemSubcategory == nil ||
                              (outcome.category == .terminalBarrierFailure &&
                               outcome.capturedProcessCategory == .filesystemFailure))
              }) else { return false }
        let cloneIORan = result.cloneStages.contains {
            $0.processStarted || ($0.category != .notRun && $0.stage != .boundedTreeVerify)
        }
        if filesystem.preflight.failureSubcategory != nil {
            guard filesystem.probe == .notRun,
                  result.cloneStages.allSatisfy({ $0.category == .notRun }) else { return false }
        } else if !filesystem.probe.succeeded {
            guard !cloneIORan,
                  filesystem.probe.failureSubcategory != nil ||
                    filesystem.probe.requiresReconciliation,
                  result.cloneStages.allSatisfy({ $0.category == .notRun }) else { return false }
        } else if cloneIORan {
            guard filesystem.preflight.failureSubcategory == nil else { return false }
        }
        if result.failureCategory == nil {
            return result.cloneStages.allSatisfy { $0.category == .succeeded }
                && filesystem.permitsSuccessfulClone
                && result.cloneRemote == StageDEnvironmentLock.cloneURL
                && result.cloneHEAD == StageDEnvironmentLock.acceptedStageCCommit
                && result.cloneEntryCount != nil
                && result.cloneByteCount != nil
                && result.cloneEntryCount == filesystem.residual.entryCount
                && result.cloneByteCount == filesystem.residual.byteCount
        }
        return result.cloneStages.contains { $0.category != .succeeded }
    }

    private static func valid(_ evidence: StageDCloneFilesystemEvidence) -> Bool {
        let preflight = evidence.preflight
        let probe = evidence.probe
        let residual = evidence.residual
        let expectedBlockingSubcategory = preflight.failureSubcategory
            ?? probe.failureSubcategory
        guard evidence.evidenceVersion == 1,
              preflight.evidenceVersion == evidence.evidenceVersion,
              validHash(preflight.hostRootBindingSHA256),
              validHash(preflight.guestRootBindingSHA256),
              preflight.bindingMatches ==
                (preflight.hostRootBindingSHA256 == preflight.guestRootBindingSHA256),
              preflight.umask <= 0o777,
              preflight.requiredNameBytes == 40,
              preflight.requiredPathBytes == 69,
              preflight.requiredAvailableBytes > 0,
              preflight.requiredAvailableInodes > 0,
              (!preflight.complete || (preflight.nameMax > 0 && preflight.pathMax > 0)),
              (!preflight.complete || !preflight.parentIsEmpty || !preflight.targetExists),
              (!preflight.complete || !preflight.targetExists || preflight.targetType != .missing),
              (!preflight.complete || preflight.targetExists || preflight.targetType == .missing),
              (!preflight.complete || !preflight.targetIsSymlink || preflight.targetType == .symbolicLink),
              (!probe.cleanupVerified || probe.cleanupKnown),
              probe.steps.map(\.step) == StageDCloneCapabilityStep.allCases,
              probe.steps.allSatisfy({ step in
                  guard step.succeeded == (step.state == .succeeded) else { return false }
                  switch step.state {
                  case .succeeded, .notRun: return step.subcategory == nil
                  case .failed, .unknown: return step.subcategory != nil
                  }
              }),
              validProbeSequence(probe.steps),
              residual.entryCount >= 0,
              (!residual.inspectionComplete || !residual.targetExists || residual.targetType != .missing),
              (!residual.inspectionComplete || residual.targetExists || residual.targetType == .missing),
              (!residual.inspectionComplete || !residual.targetIsSymlink || residual.targetType == .symbolicLink),
              evidence.blockingSubcategory == expectedBlockingSubcategory ||
                (expectedBlockingSubcategory == nil && evidence.blockingSubcategory != nil) else {
            return false
        }
        if !residual.targetExists {
            return residual.entryCount == 0
                && residual.byteCount == 0
                && !residual.gitDirectory
                && !residual.gitHEAD
                && !residual.gitConfig
                && !residual.gitObjects
                && !residual.gitRefs
        }
        return true
    }

    private static func validProbeSequence(_ steps: [StageDCloneCapabilityStepFacts]) -> Bool {
        var stopped = false
        for step in steps {
            if stopped {
                guard step.state == .notRun else { return false }
                continue
            }
            switch step.state {
            case .succeeded: continue
            case .failed, .unknown: stopped = true
            case .notRun: stopped = true
            }
        }
        return true
    }

    private static func validExpectation(_ expectation: StageDCompletionExpectation) -> Bool {
        switch expectation.kind {
        case .exactFile:
            return expectation.relativePath != nil
                && expectation.expectedSHA256.map(validHash) == true
                && expectation.cloneTarget == nil && expectation.cloneRemote == nil && expectation.cloneHEAD == nil
        case .exactClone:
            return expectation.relativePath == nil && expectation.expectedSHA256 == nil
                && expectation.cloneTarget == StageDEnvironmentLock.cloneTarget
                && expectation.cloneRemote == StageDEnvironmentLock.cloneURL
                && expectation.cloneHEAD == StageDEnvironmentLock.acceptedStageCCommit
        case .successfulCommand:
            return expectation.relativePath == nil && expectation.expectedSHA256 == nil
                && expectation.cloneTarget == nil && expectation.cloneRemote == nil && expectation.cloneHEAD == nil
        }
    }

    static func digest<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return (try? encoder.encode(value)).map(ProviderDigest.sha256Hex)
    }

    static func durableDate(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1_000).rounded() / 1_000)
    }

    private static func validHash(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdef").contains($0)
        }
    }
}
