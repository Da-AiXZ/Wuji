import CryptoKit
import Foundation

struct StageCWorkspaceDigest: Equatable, Sendable {
    let treeSHA256: String
    let entryCount: Int
    let totalFileBytes: UInt64
    let targetData: Data
    let targetSHA256: String
    fileprivate let entries: [StageCWorkspaceEntry]

    func replacingTarget(
        path: String,
        with data: Data,
        maximumWorkspaceBytes: UInt64
    ) throws -> StageCWorkspaceDigest {
        var replaced = false
        var updated: [StageCWorkspaceEntry] = []
        var total: UInt64 = 0
        for entry in entries {
            let next: StageCWorkspaceEntry
            if entry.relativePath == path, !entry.isDirectory {
                next = .init(
                    relativePath: entry.relativePath,
                    isDirectory: false,
                    byteCount: UInt64(data.count),
                    contentSHA256: ProviderDigest.sha256Hex(data)
                )
                replaced = true
            } else {
                next = entry
            }
            let addition = total.addingReportingOverflow(next.byteCount)
            guard !addition.overflow, addition.partialValue <= maximumWorkspaceBytes else {
                throw StageCError.workspaceLimit
            }
            total = addition.partialValue
            updated.append(next)
        }
        guard replaced else { throw StageCError.unsupportedFile }
        return StageCWorkspaceDigest(
            treeSHA256: Self.treeSHA256(updated),
            entryCount: updated.count,
            totalFileBytes: total,
            targetData: targetData,
            targetSHA256: targetSHA256,
            entries: updated
        )
    }

    fileprivate static func treeSHA256(_ entries: [StageCWorkspaceEntry]) -> String {
        var digest = SHA256()
        for entry in entries.sorted(by: { $0.relativePath < $1.relativePath }) {
            digest.update(data: Data(
                "\(entry.relativePath)\u{0}\(entry.isDirectory ? "d" : "f")\u{0}\(entry.byteCount)\u{0}\(entry.contentSHA256)\n".utf8
            ))
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

fileprivate struct StageCWorkspaceEntry: Equatable, Sendable {
    let relativePath: String
    let isDirectory: Bool
    let byteCount: UInt64
    let contentSHA256: String
}

struct StageCEditPolicy: Sendable {
    private let task: StageCTaskRecord
    private let workspace: StageBReadyWorkspace
    private let ruleSet: StageBRuleSet
    private let readPolicy: StageBReadOnlyPolicy
    private let limits: StageCLimits
    private let fileManager: FileManager

    init(
        task: StageCTaskRecord,
        workspace: StageBReadyWorkspace,
        ruleSet: StageBRuleSet,
        readLimits: StageBLimits = .production,
        limits: StageCLimits = .production,
        fileManager: FileManager = .default
    ) {
        self.task = task
        self.workspace = workspace
        self.ruleSet = ruleSet
        self.readPolicy = StageBReadOnlyPolicy(
            workspace: workspace,
            ruleSet: ruleSet,
            limits: readLimits,
            fileManager: fileManager
        )
        self.limits = limits
        self.fileManager = fileManager
    }

    static func toolDefinitions() -> [ProviderToolDefinition] {
        StageBReadOnlyPolicy.toolDefinitions() + [ProviderToolDefinition(
            name: StageCToolName.edit.rawValue,
            descriptionText: "Propose one exact replacement in the task's existing ordinary UTF-8 text file. This only creates an approval request; it does not write.",
            parameters: ProviderToolParameters(
                type: "object",
                properties: [
                    "path": ProviderToolProperty(
                        type: "string",
                        description: "Exact normalized relative target path bound to this task."
                    ),
                    "expected_before": ProviderToolProperty(
                        type: "string",
                        description: "One exact nonempty existing text line to replace once."
                    ),
                    "replacement": ProviderToolProperty(
                        type: "string",
                        description: "One exact nonempty replacement text line."
                    )
                ],
                required: ["path", "expected_before", "replacement"],
                additionalProperties: false
            )
        )]
    }

    func authorizeReadBatch(
        _ calls: [ProviderTurnToolCall],
        previouslyUsedIDs: Set<String>
    ) throws -> [StageBAuthorizedToolCall] {
        guard calls.count <= limits.maximumReadCallsPerBatch,
              calls.allSatisfy({ StageBToolName(rawValue: $0.name) != nil }) else {
            throw StageCError.mixedBatch
        }
        do { return try readPolicy.authorizeBatch(calls, previouslyUsedIDs: previouslyUsedIDs) }
        catch { throw StageCError.invalidArguments }
    }

    func proposeEdit(
        _ calls: [ProviderTurnToolCall],
        previouslyUsedIDs: Set<String>,
        baseline: StageCWorkspaceDigest,
        now: Date = Date()
    ) throws -> StageCEditProposal {
        guard calls.count == 1, calls[0].name == StageCToolName.edit.rawValue else {
            throw StageCError.editBatchCount
        }
        let call = calls[0]
        guard !call.id.isEmpty,
              call.id.utf8.count <= ProviderLimits.maximumToolCallIDBytes,
              !previouslyUsedIDs.contains(call.id),
              call.arguments.utf8.count <= ProviderLimits.maximumToolArgumentsBytes else {
            throw StageCError.toolCallID
        }
        guard let data = call.arguments.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["path", "expected_before", "replacement"]),
              let path = object["path"] as? String,
              let expectedOld = object["expected_before"] as? String,
              let replacement = object["replacement"] as? String else {
            throw StageCError.invalidArguments
        }
        try validateBinding()
        try validateTargetSyntax(path)
        guard !expectedOld.isEmpty, !replacement.isEmpty,
              expectedOld != replacement,
              expectedOld.utf8.count <= ProviderLimits.maximumToolArgumentsBytes,
              replacement.utf8.count <= ProviderLimits.maximumToolArgumentsBytes,
              !expectedOld.contains("\n"), !expectedOld.contains("\r"),
              !replacement.contains("\n"), !replacement.contains("\r"),
              !expectedOld.contains("\\"), !replacement.contains("\\"),
              !expectedOld.contains("\0"), !replacement.contains("\0") else {
            throw StageCError.invalidArguments
        }

        guard baseline.targetData.count <= limits.maximumEditableFileBytes,
              !baseline.targetData.contains(0),
              let before = String(data: baseline.targetData, encoding: .utf8) else {
            throw StageCError.unsupportedFile
        }
        guard before != expectedOld else { throw StageCError.overwriteRejected }
        let lines = before.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let matches = lines.indices.filter { lines[$0] == expectedOld }
        guard matches.count == 1 else {
            throw matches.isEmpty ? StageCError.beforeMismatch : StageCError.ambiguousReplacement
        }
        var afterLines = lines
        afterLines[matches[0]] = replacement
        let after = afterLines.joined(separator: "\n")
        guard let afterData = after.data(using: .utf8),
              afterData.count <= limits.maximumEditableFileBytes else {
            throw StageCError.fileLimit
        }
        let afterHash = ProviderDigest.sha256Hex(afterData)
        let expectedTree = try baseline.replacingTarget(
            path: path,
            with: afterData,
            maximumWorkspaceBytes: limits.maximumWorkspaceBytes
        )
        let diff = "--- a/\(path)\n+++ b/\(path)\n@@ exact single replacement @@\n-\(expectedOld)\n+\(replacement)\n"
        guard diff.utf8.count <= limits.maximumDiffBytes else { throw StageCError.diffLimit }
        let diffHash = ProviderDigest.sha256Hex(diff)
        let material = StageCEditProposal.bindingMaterial(
            taskID: task.id,
            toolCallID: call.id,
            relativePath: path,
            expectedOld: expectedOld,
            replacement: replacement,
            beforeSHA256: baseline.targetSHA256,
            afterSHA256: afterHash,
            beforeTreeSHA256: baseline.treeSHA256,
            expectedAfterTreeSHA256: expectedTree.treeSHA256,
            diffSHA256: diffHash,
            createdAt: now
        )
        return StageCEditProposal(
            taskID: task.id,
            toolCallID: call.id,
            relativePath: path,
            expectedOld: expectedOld,
            replacement: replacement,
            beforeSHA256: baseline.targetSHA256,
            afterSHA256: afterHash,
            beforeTreeSHA256: baseline.treeSHA256,
            expectedAfterTreeSHA256: expectedTree.treeSHA256,
            diff: diff,
            diffSHA256: diffHash,
            createdAt: now,
            proposalSHA256: ProviderDigest.sha256Hex(material)
        )
    }

    func verifyCurrentBefore(_ proposal: StageCEditProposal) throws -> Bool {
        let digest = try workspaceDigest(targetPath: proposal.relativePath)
        return digest.targetSHA256 == proposal.beforeSHA256
            && digest.treeSHA256 == proposal.beforeTreeSHA256
    }

    func captureWorkspaceBaseline() throws -> StageCWorkspaceDigest {
        try workspaceDigest(targetPath: task.targetRelativePath)
    }

    func verifyApplied(_ proposal: StageCEditProposal) throws -> StageCWorkspaceDigest {
        let digest = try workspaceDigest(targetPath: proposal.relativePath)
        guard digest.targetSHA256 == proposal.afterSHA256,
              digest.treeSHA256 == proposal.expectedAfterTreeSHA256 else {
            throw StageCError.verificationFailed
        }
        return digest
    }

    func approvalRequest(
        for proposal: StageCEditProposal,
        now: Date = Date(),
        nonce: UUID = UUID(),
        requestID: UUID = UUID()
    ) throws -> StageCApprovalRequest {
        try validateBinding()
        guard proposal.taskID == task.id,
              proposal.relativePath == task.targetRelativePath else {
            throw StageCError.approvalTampered
        }
        let createdAt = durableDate(now)
        let expiresAt = durableDate(now.addingTimeInterval(limits.maximumApprovalSeconds))
        return StageCApprovalRequest(
            requestID: requestID,
            taskID: task.id,
            sessionID: task.sessionID,
            importID: task.importID,
            workspaceID: task.workspaceID,
            workspaceIdentitySHA256: task.workspaceIdentitySHA256,
            workspaceRootSHA256: task.workspaceRootSHA256,
            markerSHA256: task.markerSHA256,
            goalBindingSHA256: task.goalBindingSHA256,
            ruleSetBindingSHA256: task.ruleSetBindingSHA256,
            proposalSHA256: proposal.proposalSHA256,
            toolCallID: proposal.toolCallID,
            relativePath: proposal.relativePath,
            beforeSHA256: proposal.beforeSHA256,
            afterSHA256: proposal.afterSHA256,
            diffSHA256: proposal.diffSHA256,
            nonce: nonce,
            createdAt: createdAt,
            expiresAt: expiresAt
        )
    }

    func validateGrant(
        _ grant: StageCApprovalGrant,
        request: StageCApprovalRequest,
        now: Date
    ) throws {
        guard now <= request.expiresAt else { throw StageCError.approvalExpired }
        guard grant.requestID == request.requestID,
              grant.nonce == request.nonce,
              grant.requestBindingSHA256 == request.bindingSHA256,
              grant.approvedAt >= request.createdAt,
              grant.approvedAt <= request.expiresAt else {
            throw StageCError.approvalTampered
        }
    }

    func validateApprovalBinding(
        _ request: StageCApprovalRequest,
        proposal: StageCEditProposal
    ) throws {
        guard request.taskID == task.id,
              request.sessionID == task.sessionID,
              request.importID == task.importID,
              request.workspaceID == task.workspaceID,
              request.workspaceIdentitySHA256 == task.workspaceIdentitySHA256,
              request.workspaceRootSHA256 == task.workspaceRootSHA256,
              request.markerSHA256 == task.markerSHA256,
              request.goalBindingSHA256 == task.goalBindingSHA256,
              request.ruleSetBindingSHA256 == task.ruleSetBindingSHA256,
              request.proposalSHA256 == proposal.proposalSHA256,
              request.toolCallID == proposal.toolCallID,
              request.relativePath == proposal.relativePath,
              request.beforeSHA256 == proposal.beforeSHA256,
              request.afterSHA256 == proposal.afterSHA256,
              request.diffSHA256 == proposal.diffSHA256 else {
            throw StageCError.approvalTampered
        }
    }

    private func validateBinding() throws {
        guard task.importID == workspace.importID,
              task.workspaceID == workspace.workspaceID,
              task.workspaceIdentitySHA256 == workspace.identitySHA256,
              task.workspaceRootSHA256 == ProviderDigest.sha256Hex(workspace.canonicalRootURL.path),
              task.markerSHA256 == workspace.markerSHA256,
              task.ruleSetBindingSHA256 == ruleSet.bindingSHA256 else {
            throw StageCError.invalidBinding
        }
    }

    private func validateTargetSyntax(_ path: String) throws {
        guard path == task.targetRelativePath,
              StageBPathSyntax.valid(path, allowEmpty: false, maximumBytes: limits.maximumPathBytes)
        else { throw StageCError.pathRejected }
        let components = path.split(separator: "/").map { $0.lowercased() }
        guard path.lowercased() != StageAWorkspaceMarker.fileName.lowercased(),
              !components.contains(".git") else { throw StageCError.protectedPath }
    }

    private func validateTarget(_ path: String) throws {
        try validateTargetSyntax(path)
        let url = workspace.canonicalRootURL.appendingPathComponent(path)
        let standardized = url.standardizedFileURL
        let resolved = standardized.resolvingSymlinksInPath()
        guard contains(standardized, in: workspace.canonicalRootURL),
              contains(resolved, in: workspace.canonicalRootURL),
              standardized.path == resolved.path else { throw StageCError.symlinkRejected }
        let values = try resolved.resourceValues(forKeys: [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey
        ])
        guard values.isRegularFile == true,
              values.isDirectory != true,
              values.isSymbolicLink != true else { throw StageCError.unsupportedFile }
    }

    private func workspaceDigest(
        targetPath: String
    ) throws -> StageCWorkspaceDigest {
        try validateTarget(targetPath)
        let markerURL = workspace.canonicalRootURL.appendingPathComponent(StageAWorkspaceMarker.fileName)
        let markerData = try Data(contentsOf: markerURL, options: .mappedIfSafe)
        guard ProviderDigest.sha256Hex(markerData) == task.markerSHA256 else {
            throw StageCError.invalidBinding
        }
        guard let enumerator = fileManager.enumerator(
            at: workspace.canonicalRootURL,
            includingPropertiesForKeys: [
                .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey
            ],
            options: [.skipsPackageDescendants]
        ) else { throw StageCError.workspaceLimit }
        var entries: [StageCWorkspaceEntry] = []
        var total: UInt64 = 0
        var targetData = Data()
        var targetHash = ""
        while let url = enumerator.nextObject() as? URL {
            let relative = url.pathComponents
                .dropFirst(workspace.canonicalRootURL.pathComponents.count)
                .joined(separator: "/")
            if relative == StageAWorkspaceMarker.fileName { continue }
            guard StageBPathSyntax.valid(relative, allowEmpty: false, maximumBytes: limits.maximumPathBytes)
            else { throw StageCError.pathRejected }
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey
            ])
            guard values.isSymbolicLink != true else { throw StageCError.symlinkRejected }
            if values.isDirectory == true {
                entries.append(.init(
                    relativePath: relative,
                    isDirectory: true,
                    byteCount: 0,
                    contentSHA256: ProviderDigest.sha256Hex(Data())
                ))
            } else if values.isRegularFile == true {
                let actual = try Data(contentsOf: url, options: .mappedIfSafe)
                let addition = total.addingReportingOverflow(UInt64(actual.count))
                guard !addition.overflow,
                      addition.partialValue <= limits.maximumWorkspaceBytes else {
                    throw StageCError.workspaceLimit
                }
                total = addition.partialValue
                entries.append(.init(
                    relativePath: relative,
                    isDirectory: false,
                    byteCount: UInt64(actual.count),
                    contentSHA256: ProviderDigest.sha256Hex(actual)
                ))
                if relative == targetPath {
                    targetData = actual
                    targetHash = ProviderDigest.sha256Hex(actual)
                }
            } else {
                throw StageCError.unsupportedFile
            }
            guard entries.count <= limits.maximumWorkspaceEntries else {
                throw StageCError.workspaceLimit
            }
        }
        guard !targetHash.isEmpty else { throw StageCError.unsupportedFile }
        return StageCWorkspaceDigest(
            treeSHA256: StageCWorkspaceDigest.treeSHA256(entries),
            entryCount: entries.count,
            totalFileBytes: total,
            targetData: targetData,
            targetSHA256: targetHash,
            entries: entries
        )
    }

    private func contains(_ candidate: URL, in root: URL) -> Bool {
        let rootComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        return candidateComponents.count >= rootComponents.count
            && Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }

    private func durableDate(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1_000).rounded() / 1_000)
    }
}
