import Foundation

enum S4Limits {
    static let maximumProviderTurns = 10
    static let maximumToolExecutions = 10
    static let maximumWorkspaceFiles = 8
    static let maximumWorkspaceFileBytes = 8 * 1_024
    static let maximumApprovalSeconds: TimeInterval = 10 * 60
    static let maximumDurableFileBytes = 512 * 1_024
}

enum S4TaskContract {
    static let packageID = "wuji-s4-status-verified-v1"
    static let authorizedPath = "records/draft.txt"
    static let contextPath = "records/context.txt"
    static let temporarySuffix = ".wuji-s4-tmp"
    static let expectedOldText = "STATUS=pending"
    static let replacementText = "STATUS=verified"
    static let verificationProfile = S4VerificationProfile.s4StatusVerified
    static let expectedBeforeContent = "TITLE=Wuji S4 bounded edit fixture\nSTATUS=pending\nCONTEXT=preserve-this-line-byte-for-byte\n"
    static let expectedAfterContent = "TITLE=Wuji S4 bounded edit fixture\nSTATUS=verified\nCONTEXT=preserve-this-line-byte-for-byte\n"
    static let expectedContextContent = "WUJI_S4_CONTEXT=must-remain-unchanged\n"
    static let goal = "Inspect the approved S4 task workspace, then replace the single STATUS=pending line in records/draft.txt with STATUS=verified after explicit approval, and run the fixed s4_status_verified verification profile."
    static let systemPrompt = """
    You are selecting typed operations for one fixed Wuji S4 task. Swift owns policy, approval, recovery, and completion. Read-only list, search, and read calls may appear in batches of up to three and execute serially after whole-batch validation. An edit or verify response must contain exactly that one call. The only edit is records/draft.txt with expected_old STATUS=pending and replacement STATUS=verified. Verification accepts only profile s4_status_verified. Never provide shell text, commands, argv, environment, timeout, package, network, Git, delete, rename, or any other write. First inspect with list/search/read, then request edit, then request verify, then finish without a tool call. A model completion claim never completes the task.
    """

    static var beforeHash: String { ProviderDigest.sha256Hex(expectedBeforeContent) }
    static var afterHash: String { ProviderDigest.sha256Hex(expectedAfterContent) }
    static var contextHash: String { ProviderDigest.sha256Hex(expectedContextContent) }
    static var changeSummaryHash: String {
        ProviderDigest.sha256Hex("replace-once\u{0}\(authorizedPath)\u{0}\(expectedOldText)\u{0}\(replacementText)")
    }
}

enum S4VerificationProfile: String, Codable, Equatable, Sendable {
    case s4StatusVerified = "s4_status_verified"
}

enum S4WorkspaceError: String, Error, Equatable, Sendable {
    case fixtureUnavailable = "fixture_unavailable"
    case workspaceUnavailable = "workspace_unavailable"
    case invalidSeed = "invalid_seed"
    case pathRejected = "path_rejected"
    case symlinkRejected = "symlink_rejected"
    case unexpectedDiff = "unexpected_diff"
}

enum S4WorkspaceContentState: Equatable, Sendable {
    case before
    case after
    case other
}

struct S4WorkspaceInspection: Equatable, Sendable {
    let contentState: S4WorkspaceContentState
    let temporaryFilePresent: Bool
    let exactFileSet: Bool
    let contextUnchanged: Bool
    let workspaceDiffSHA256: String
}

struct S4ApprovedWorkspace: Sendable {
    let taskID: UUID
    let rootURL: URL
    let canonicalRootURL: URL
    let workspaceID: String
    let seedSnapshotSHA256: String

    init(taskID: UUID, rootURL: URL, requireInitialSeed: Bool) throws {
        guard rootURL.isFileURL else { throw S4WorkspaceError.workspaceUnavailable }
        let canonical = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let values = try canonical.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else { throw S4WorkspaceError.workspaceUnavailable }
        self.taskID = taskID
        self.rootURL = rootURL
        canonicalRootURL = canonical
        seedSnapshotSHA256 = Self.seedSnapshotHash
        workspaceID = ProviderDigest.sha256Hex(
            "\(taskID.uuidString.lowercased())\u{0}\(canonical.path)\u{0}\(Self.seedSnapshotHash)"
        )
        try validateTree(requireInitialSeed: requireInitialSeed)
    }

    static func prepare(
        taskID: UUID,
        applicationSupportURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> S4ApprovedWorkspace {
        let support = try applicationSupportURL ?? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let taskRoot = support
            .appendingPathComponent("WujiS4Tasks", isDirectory: true)
            .appendingPathComponent(taskID.uuidString.lowercased(), isDirectory: true)
        let workspaceURL = taskRoot.appendingPathComponent("workspace", isDirectory: true)
        if fileManager.fileExists(atPath: workspaceURL.path) {
            return try S4ApprovedWorkspace(
                taskID: taskID,
                rootURL: workspaceURL,
                requireInitialSeed: false
            )
        }
        guard let fixtureURL = Bundle.main.url(forResource: "S4Fixture", withExtension: nil) else {
            throw S4WorkspaceError.fixtureUnavailable
        }
        try fileManager.createDirectory(at: taskRoot, withIntermediateDirectories: true)
        do {
            try fileManager.copyItem(at: fixtureURL, to: workspaceURL)
        } catch {
            throw S4WorkspaceError.workspaceUnavailable
        }
        return try S4ApprovedWorkspace(
            taskID: taskID,
            rootURL: workspaceURL,
            requireInitialSeed: true
        )
    }

    func fileURL(relativePath: String) throws -> URL {
        try Self.validateRelativePath(relativePath)
        let candidate = canonicalRootURL.appendingPathComponent(relativePath)
        let canonical = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard Self.contains(canonical, in: canonicalRootURL) else {
            throw S4WorkspaceError.symlinkRejected
        }
        return canonical
    }

    func inspect(fileManager: FileManager = .default) throws -> S4WorkspaceInspection {
        try validateTree(requireInitialSeed: false)
        let draftURL = try fileURL(relativePath: S4TaskContract.authorizedPath)
        let contextURL = try fileURL(relativePath: S4TaskContract.contextPath)
        let draftData = try Data(contentsOf: draftURL, options: .mappedIfSafe)
        let contextData = try Data(contentsOf: contextURL, options: .mappedIfSafe)
        let draftHash = ProviderDigest.sha256Hex(draftData)
        let contextHash = ProviderDigest.sha256Hex(contextData)
        let contentState: S4WorkspaceContentState
        if draftHash == S4TaskContract.beforeHash {
            contentState = .before
        } else if draftHash == S4TaskContract.afterHash {
            contentState = .after
        } else {
            contentState = .other
        }
        let temporaryURL = draftURL.appendingPathExtension(String(S4TaskContract.temporarySuffix.dropFirst()))
        let fileSet = try Self.relativeFileSet(rootURL: canonicalRootURL, fileManager: fileManager)
        let exactFiles = Set(fileSet) == Set([
            S4TaskContract.authorizedPath,
            S4TaskContract.contextPath
        ])
        let diff = [
            "draft=\(draftHash)",
            "context=\(contextHash)",
            "files=\(fileSet.sorted().joined(separator: ","))",
            "temp=\(fileManager.fileExists(atPath: temporaryURL.path))"
        ].joined(separator: "\n")
        return S4WorkspaceInspection(
            contentState: contentState,
            temporaryFilePresent: fileManager.fileExists(atPath: temporaryURL.path),
            exactFileSet: exactFiles,
            contextUnchanged: contextHash == S4TaskContract.contextHash,
            workspaceDiffSHA256: ProviderDigest.sha256Hex(diff)
        )
    }

    private func validateTree(requireInitialSeed: Bool) throws {
        let files = try Self.relativeFileSet(rootURL: canonicalRootURL, fileManager: .default)
        guard files.count <= S4Limits.maximumWorkspaceFiles,
              Set(files) == Set([S4TaskContract.authorizedPath, S4TaskContract.contextPath]) else {
            throw S4WorkspaceError.invalidSeed
        }
        let draftURL = try fileURL(relativePath: S4TaskContract.authorizedPath)
        let contextURL = try fileURL(relativePath: S4TaskContract.contextPath)
        for url in [draftURL, contextURL] {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey
            ])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  (values.fileSize ?? S4Limits.maximumWorkspaceFileBytes + 1) <= S4Limits.maximumWorkspaceFileBytes else {
                throw S4WorkspaceError.invalidSeed
            }
        }
        guard ProviderDigest.sha256Hex(try Data(contentsOf: contextURL)) == S4TaskContract.contextHash else {
            throw S4WorkspaceError.invalidSeed
        }
        if requireInitialSeed,
           ProviderDigest.sha256Hex(try Data(contentsOf: draftURL)) != S4TaskContract.beforeHash {
            throw S4WorkspaceError.invalidSeed
        }
    }

    private static var seedSnapshotHash: String {
        ProviderDigest.sha256Hex(
            "\(S4TaskContract.authorizedPath)=\(S4TaskContract.beforeHash)\n" +
            "\(S4TaskContract.contextPath)=\(S4TaskContract.contextHash)"
        )
    }

    private static func validateRelativePath(_ path: String) throws {
        guard !path.isEmpty,
              path.utf8.count <= S3Limits.maximumPathBytes,
              !path.hasPrefix("/"),
              !path.hasPrefix("\\"),
              !path.contains("\\"),
              !path.contains("%"),
              !path.contains(":"),
              path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".."
              }) else {
            throw S4WorkspaceError.pathRejected
        }
    }

    private static func contains(_ candidate: URL, in root: URL) -> Bool {
        let rootComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        return candidateComponents.count >= rootComponents.count
            && Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }

    private static func relativeFileSet(rootURL: URL, fileManager: FileManager) throws -> [String] {
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw S4WorkspaceError.workspaceUnavailable
        }
        var files: [String] = []
        while let entry = enumerator.nextObject() as? URL {
            let values = try entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { throw S4WorkspaceError.symlinkRejected }
            if values.isRegularFile == true {
                guard contains(entry.standardizedFileURL, in: rootURL) else {
                    throw S4WorkspaceError.pathRejected
                }
                let relative = entry.pathComponents.dropFirst(rootURL.pathComponents.count).joined(separator: "/")
                try validateRelativePath(relative)
                files.append(relative)
            }
        }
        return files
    }
}

enum S4ToolName: String, CaseIterable, Codable, Sendable {
    case list
    case search
    case read
    case edit
    case verify
}

enum S4PolicyPhase: Equatable, Sendable {
    case inspecting
    case inspected
    case edited
}

enum S4PolicyError: String, Error, Equatable, Codable, Sendable {
    case batchCount = "batch_count"
    case sideEffectIsolation = "side_effect_isolation"
    case toolCallID = "tool_call_id"
    case unknownTool = "unknown_tool"
    case invalidArguments = "invalid_arguments"
    case pathRejected = "path_rejected"
    case stalePhase = "stale_phase"
    case verificationProfile = "verification_profile"
}

struct S4BatchPolicyError: Error, Equatable, Sendable {
    let reason: S4PolicyError
    let callIndex: Int?
}

struct S4AuthorizedEdit: Equatable, Sendable {
    let relativePath: String
    let beforeHash: String
    let afterHash: String

    var inputSHA256: String {
        ProviderDigest.sha256Hex(
            "edit\u{0}\(relativePath)\u{0}\(beforeHash)\u{0}\(afterHash)\u{0}\(S4TaskContract.changeSummaryHash)"
        )
    }
}

enum S4AuthorizedTool: Equatable, Sendable {
    case readOnly(S3AuthorizedTool)
    case edit(S4AuthorizedEdit)
    case verify(S4VerificationProfile)

    var name: S4ToolName {
        switch self {
        case let .readOnly(tool): return S4ToolName(rawValue: tool.name.rawValue)!
        case .edit: return .edit
        case .verify: return .verify
        }
    }

    var inputSHA256: String {
        switch self {
        case let .readOnly(tool): return tool.inputSHA256
        case let .edit(edit): return edit.inputSHA256
        case let .verify(profile): return ProviderDigest.sha256Hex("verify\u{0}\(profile.rawValue)")
        }
    }
}

struct S4AuthorizedToolCall: Equatable, Sendable {
    let toolCallID: String
    let tool: S4AuthorizedTool
}

struct S4ToolPolicy: Sendable {
    private let readPolicy: S3ToolPolicy
    private let workspace: S4ApprovedWorkspace

    init(workspace: S4ApprovedWorkspace) throws {
        self.workspace = workspace
        readPolicy = S3ToolPolicy(workspace: try S3ApprovedWorkspace(rootURL: workspace.rootURL))
    }

    func authorizeBatch(
        _ calls: [ProviderTurnToolCall],
        phase: S4PolicyPhase,
        previouslyUsedIDs: Set<String> = []
    ) throws -> [S4AuthorizedToolCall] {
        guard !calls.isEmpty, calls.count <= ProviderLimits.maximumToolCalls else {
            throw S4BatchPolicyError(reason: .batchCount, callIndex: nil)
        }
        if calls.contains(where: { $0.name == S4ToolName.edit.rawValue || $0.name == S4ToolName.verify.rawValue }),
           calls.count != 1 {
            throw S4BatchPolicyError(reason: .sideEffectIsolation, callIndex: nil)
        }

        var batchIDs = Set<String>()
        var authorized: [S4AuthorizedToolCall] = []
        for (index, call) in calls.enumerated() {
            let idBytes = call.id.utf8.count
            guard idBytes > 0,
                  idBytes <= ProviderLimits.maximumToolCallIDBytes,
                  call.id.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
                  !previouslyUsedIDs.contains(call.id),
                  batchIDs.insert(call.id).inserted else {
                throw S4BatchPolicyError(reason: .toolCallID, callIndex: index)
            }
            let tool: S4AuthorizedTool
            do {
                switch S4ToolName(rawValue: call.name) {
                case .list, .search, .read:
                    tool = .readOnly(try readPolicy.authorize(call))
                case .edit:
                    guard phase == .inspected else { throw S4PolicyError.stalePhase }
                    let object = try parseObject(call.arguments, keys: ["path", "expected_old", "replacement"])
                    guard object["path"] == S4TaskContract.authorizedPath,
                          object["expected_old"] == S4TaskContract.expectedOldText,
                          object["replacement"] == S4TaskContract.replacementText else {
                        throw S4PolicyError.invalidArguments
                    }
                    _ = try workspace.fileURL(relativePath: S4TaskContract.authorizedPath)
                    tool = .edit(S4AuthorizedEdit(
                        relativePath: S4TaskContract.authorizedPath,
                        beforeHash: S4TaskContract.beforeHash,
                        afterHash: S4TaskContract.afterHash
                    ))
                case .verify:
                    guard phase == .edited else { throw S4PolicyError.stalePhase }
                    let object = try parseObject(call.arguments, keys: ["profile"])
                    guard object["profile"] == S4TaskContract.verificationProfile.rawValue else {
                        throw S4PolicyError.verificationProfile
                    }
                    tool = .verify(S4TaskContract.verificationProfile)
                case nil:
                    throw S4PolicyError.unknownTool
                }
            } catch let error as S4PolicyError {
                throw S4BatchPolicyError(reason: error, callIndex: index)
            } catch {
                throw S4BatchPolicyError(reason: .invalidArguments, callIndex: index)
            }
            authorized.append(S4AuthorizedToolCall(toolCallID: call.id, tool: tool))
        }
        return authorized
    }

    static var toolDefinitions: [ProviderToolDefinition] {
        let path = ProviderToolProperty(
            type: "string",
            description: "Normalized path relative to the approved S4 task workspace."
        )
        return S3ToolPolicy.toolDefinitions + [
            ProviderToolDefinition(
                name: S4ToolName.edit.rawValue,
                descriptionText: "Request the single approved exact replacement. Execution requires explicit user approval.",
                parameters: ProviderToolParameters(
                    type: "object",
                    properties: [
                        "path": path,
                        "expected_old": ProviderToolProperty(type: "string", description: "Exact old line."),
                        "replacement": ProviderToolProperty(type: "string", description: "Exact replacement line.")
                    ],
                    required: ["path", "expected_old", "replacement"],
                    additionalProperties: false
                )
            ),
            ProviderToolDefinition(
                name: S4ToolName.verify.rawValue,
                descriptionText: "Run the fixed code-owned S4 verification profile.",
                parameters: ProviderToolParameters(
                    type: "object",
                    properties: [
                        "profile": ProviderToolProperty(
                            type: "string",
                            description: "Must be s4_status_verified. No command or shell input is accepted."
                        )
                    ],
                    required: ["profile"],
                    additionalProperties: false
                )
            )
        ]
    }

    private func parseObject(_ arguments: String, keys: Set<String>) throws -> [String: String] {
        guard arguments.utf8.count <= ProviderLimits.maximumToolArgumentsBytes,
              let data = arguments.data(using: .utf8),
              let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(raw.keys) == keys,
              raw.values.allSatisfy({ $0 is String }) else {
            throw S4PolicyError.invalidArguments
        }
        return raw.reduce(into: [:]) { result, item in result[item.key] = item.value as? String }
    }
}
