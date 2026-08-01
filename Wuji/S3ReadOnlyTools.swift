import Foundation

enum S3Limits {
    static let maximumProviderTurns = 8
    static let maximumToolExecutions = 6
    static let maximumPathBytes = 512
    static let maximumQueryBytes = 256
    static let maximumEntries = 32
    static let maximumMatches = 16
    static let maximumReadBytes = 4_096
    static let maximumLineBytes = 512
    static let maximumObservationBytes = 4_096
    static let executorStreamBytes = 4_096
}

enum S3ToolName: String, CaseIterable, Codable, Sendable {
    case list
    case search
    case read
}

enum S3PolicyError: String, Error, Equatable, Codable, Sendable, CustomStringConvertible {
    case batchCount = "batch_count"
    case toolCallID = "tool_call_id"
    case unknownTool = "unknown_tool"
    case invalidArguments = "invalid_arguments"
    case pathRejected = "path_rejected"
    case pathUnavailable = "path_unavailable"
    case symlinkEscape = "symlink_escape"
    case queryRejected = "query_rejected"

    var description: String {
        switch self {
        case .batchCount: return "tool batch count rejected"
        case .toolCallID: return "tool call ID rejected"
        case .unknownTool: return "tool is not in the S3 read-only allowlist"
        case .invalidArguments: return "tool arguments rejected"
        case .pathRejected: return "workspace path rejected"
        case .pathUnavailable: return "workspace path unavailable"
        case .symlinkEscape: return "workspace symlink escape rejected"
        case .queryRejected: return "search query rejected"
        }
    }
}

struct S3BatchPolicyError: Error, Equatable, Sendable {
    let reason: S3PolicyError
    let callIndex: Int?
}

struct S3ApprovedWorkspace: Sendable {
    let rootURL: URL
    let canonicalRootURL: URL

    init(rootURL: URL) throws {
        guard rootURL.isFileURL else { throw S3PolicyError.pathRejected }
        let canonical = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let values = try canonical.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else { throw S3PolicyError.pathUnavailable }
        self.rootURL = rootURL
        canonicalRootURL = canonical
    }

    static func bundled() throws -> S3ApprovedWorkspace {
        guard let url = Bundle.main.url(forResource: "S3Fixture", withExtension: nil) else {
            throw S3PolicyError.pathUnavailable
        }
        return try S3ApprovedWorkspace(rootURL: url)
    }
}

enum S3AuthorizedTool: Equatable, Sendable, CustomStringConvertible {
    case list(path: String)
    case search(path: String, query: String)
    case read(path: String)

    var name: S3ToolName {
        switch self {
        case .list: return .list
        case .search: return .search
        case .read: return .read
        }
    }

    var relativePath: String {
        switch self {
        case let .list(path), let .search(path, _), let .read(path): return path
        }
    }

    var query: String? {
        if case let .search(_, query) = self { return query }
        return nil
    }

    var inputSHA256: String {
        let stable: String
        switch self {
        case let .list(path): stable = "list\u{0}\(path)"
        case let .search(path, query): stable = "search\u{0}\(path)\u{0}\(query)"
        case let .read(path): stable = "read\u{0}\(path)"
        }
        return ProviderDigest.sha256Hex(stable)
    }

    var description: String {
        "S3AuthorizedTool(name: \(name.rawValue), pathHash: \(ProviderDigest.sha256Hex(relativePath)), queryBytes: \(query?.utf8.count ?? 0))"
    }
}

struct S3AuthorizedToolCall: Equatable, Sendable {
    let toolCallID: String
    let tool: S3AuthorizedTool
}

struct S3ToolPolicy: Sendable {
    private let workspace: S3ApprovedWorkspace
    private let fileManager: FileManager

    init(workspace: S3ApprovedWorkspace, fileManager: FileManager = .default) {
        self.workspace = workspace
        self.fileManager = fileManager
    }

    func authorize(_ call: ProviderTurnToolCall) throws -> S3AuthorizedTool {
        guard let tool = S3ToolName(rawValue: call.name) else {
            throw S3PolicyError.unknownTool
        }
        guard call.arguments.utf8.count <= ProviderLimits.maximumToolArgumentsBytes,
              let data = call.arguments.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw S3PolicyError.invalidArguments
        }

        switch tool {
        case .list:
            try requireKeys(object, exactly: ["path"])
            let path = try string(object, key: "path")
            return .list(path: try resolve(path, kind: .directory, recursive: false))
        case .search:
            try requireKeys(object, exactly: ["path", "query"])
            let path = try string(object, key: "path")
            let query = try string(object, key: "query")
            try validateQuery(query)
            return .search(
                path: try resolve(path, kind: .directory, recursive: true),
                query: query
            )
        case .read:
            try requireKeys(object, exactly: ["path"])
            let path = try string(object, key: "path")
            return .read(path: try resolve(path, kind: .regularFile, recursive: false))
        }
    }

    func authorizeBatch(
        _ calls: [ProviderTurnToolCall],
        previouslyUsedIDs: Set<String> = []
    ) throws -> [S3AuthorizedToolCall] {
        guard !calls.isEmpty, calls.count <= ProviderLimits.maximumToolCalls else {
            throw S3BatchPolicyError(reason: .batchCount, callIndex: nil)
        }
        var ids = Set<String>()
        var authorized: [S3AuthorizedToolCall] = []
        authorized.reserveCapacity(calls.count)
        for (index, call) in calls.enumerated() {
            let idBytes = call.id.utf8.count
            guard idBytes > 0,
                  idBytes <= ProviderLimits.maximumToolCallIDBytes,
                  call.id.unicodeScalars.allSatisfy({
                      !CharacterSet.controlCharacters.contains($0)
                  }),
                  !previouslyUsedIDs.contains(call.id),
                  ids.insert(call.id).inserted else {
                throw S3BatchPolicyError(reason: .toolCallID, callIndex: index)
            }
            do {
                authorized.append(S3AuthorizedToolCall(
                    toolCallID: call.id,
                    tool: try authorize(call)
                ))
            } catch let reason as S3PolicyError {
                throw S3BatchPolicyError(reason: reason, callIndex: index)
            } catch {
                throw S3BatchPolicyError(reason: .invalidArguments, callIndex: index)
            }
        }
        return authorized
    }

    static var toolDefinitions: [ProviderToolDefinition] {
        let path = ProviderToolProperty(
            type: "string",
            description: "Normalized path relative to the approved fixture root; use an empty string for the root."
        )
        return [
            ProviderToolDefinition(
                name: S3ToolName.list.rawValue,
                descriptionText: "List one approved fixture directory with bounded entries.",
                parameters: ProviderToolParameters(
                    type: "object",
                    properties: ["path": path],
                    required: ["path"],
                    additionalProperties: false
                )
            ),
            ProviderToolDefinition(
                name: S3ToolName.search.rawValue,
                descriptionText: "Search exact literal text under one approved fixture directory.",
                parameters: ProviderToolParameters(
                    type: "object",
                    properties: [
                        "path": path,
                        "query": ProviderToolProperty(
                            type: "string",
                            description: "Exact literal query; regular expressions are not supported."
                        )
                    ],
                    required: ["path", "query"],
                    additionalProperties: false
                )
            ),
            ProviderToolDefinition(
                name: S3ToolName.read.rawValue,
                descriptionText: "Read one approved fixture file with bounded bytes and line length.",
                parameters: ProviderToolParameters(
                    type: "object",
                    properties: ["path": path],
                    required: ["path"],
                    additionalProperties: false
                )
            )
        ]
    }

    private enum ExpectedKind { case directory, regularFile }

    private func requireKeys(_ object: [String: Any], exactly keys: Set<String>) throws {
        guard Set(object.keys) == keys else { throw S3PolicyError.invalidArguments }
    }

    private func string(_ object: [String: Any], key: String) throws -> String {
        guard let value = object[key] as? String else { throw S3PolicyError.invalidArguments }
        return value
    }

    private func validateQuery(_ query: String) throws {
        let bytes = query.utf8.count
        guard bytes > 0,
              bytes <= S3Limits.maximumQueryBytes,
              query.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw S3PolicyError.queryRejected
        }
    }

    private func resolve(
        _ relativePath: String,
        kind: ExpectedKind,
        recursive: Bool
    ) throws -> String {
        try validateRelativeSyntax(relativePath)
        let candidate = relativePath.isEmpty
            ? workspace.canonicalRootURL
            : workspace.canonicalRootURL.appendingPathComponent(relativePath)
        let canonical = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard isInsideWorkspace(canonical) else { throw S3PolicyError.symlinkEscape }

        let values: URLResourceValues
        do {
            values = try canonical.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey
            ])
        } catch {
            throw S3PolicyError.pathUnavailable
        }
        switch kind {
        case .directory where values.isDirectory != true:
            throw S3PolicyError.pathUnavailable
        case .regularFile where values.isRegularFile != true:
            throw S3PolicyError.pathUnavailable
        default:
            break
        }
        if recursive {
            try rejectRecursiveSymlinkEscapes(canonical)
        }
        return normalizedRelativePath(canonical)
    }

    private func validateRelativeSyntax(_ path: String) throws {
        guard path.utf8.count <= S3Limits.maximumPathBytes,
              !path.hasPrefix("/"),
              !path.hasPrefix("\\"),
              !path.contains("\\"),
              !path.contains("%"),
              !path.contains(":"),
              path.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw S3PolicyError.pathRejected
        }
        if path.isEmpty { return }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw S3PolicyError.pathRejected
        }
    }

    private func isInsideWorkspace(_ url: URL) -> Bool {
        let root = workspace.canonicalRootURL.pathComponents
        let candidate = url.pathComponents
        return candidate.count >= root.count && Array(candidate.prefix(root.count)) == root
    }

    private func normalizedRelativePath(_ url: URL) -> String {
        let rootCount = workspace.canonicalRootURL.pathComponents.count
        return url.pathComponents.dropFirst(rootCount).joined(separator: "/")
    }

    private func rejectRecursiveSymlinkEscapes(_ root: URL) throws {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [.skipsPackageDescendants]
        ) else {
            throw S3PolicyError.pathUnavailable
        }
        while let entry = enumerator.nextObject() as? URL {
            let values = try entry.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true,
               !isInsideWorkspace(entry.resolvingSymlinksInPath()) {
                throw S3PolicyError.symlinkEscape
            }
        }
    }
}

struct S3ExecutorFacts: Equatable, Sendable {
    let rootExitObserved: Bool
    let stdoutEOFObserved: Bool
    let stderrEOFObserved: Bool
    let finalState: ExecutorFinalState
    let stdoutByteCount: Int
    let stderrByteCount: Int
    let stdoutSHA256: String
    let stderrSHA256: String
    let truncated: Bool

    var completionBarrierSatisfied: Bool {
        rootExitObserved && stdoutEOFObserved && stderrEOFObserved
    }
}

struct S3SearchMatch: Codable, Equatable, Sendable {
    let path: String
    let line: Int
    let text: String
}

enum S3ObservationPayload: Equatable, Sendable {
    case list(entries: [String])
    case search(matches: [S3SearchMatch])
    case read(path: String, content: String)
}

struct S3ToolObservation: Equatable, Sendable, CustomStringConvertible {
    let tool: S3ToolName
    let relativePath: String
    let query: String?
    let payload: S3ObservationPayload
    let facts: S3ExecutorFacts

    var description: String {
        "S3ToolObservation(tool: \(tool.rawValue), pathHash: \(ProviderDigest.sha256Hex(relativePath)), queryBytes: \(query?.utf8.count ?? 0), bytes: \(facts.stdoutByteCount), truncated: \(facts.truncated), barrier: \(facts.completionBarrierSatisfied))"
    }

    func modelContent() throws -> String {
        try validateCaps()
        struct Wire: Encodable {
            let status: String
            let tool: String
            let path: String
            let entries: [String]?
            let matches: [S3SearchMatch]?
            let content: String?
        }
        let wire: Wire
        switch payload {
        case let .list(entries):
            wire = Wire(status: "success", tool: tool.rawValue, path: relativePath, entries: entries, matches: nil, content: nil)
        case let .search(matches):
            wire = Wire(status: "success", tool: tool.rawValue, path: relativePath, entries: nil, matches: matches, content: nil)
        case let .read(path, content):
            wire = Wire(status: "success", tool: tool.rawValue, path: path, entries: nil, matches: nil, content: content)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(wire)
        guard data.count <= S3Limits.maximumObservationBytes else {
            throw S3ExecutorFailure.observationLimit
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func validateCaps() throws {
        guard facts.completionBarrierSatisfied,
              !facts.truncated,
              facts.stdoutByteCount >= 0,
              facts.stdoutByteCount <= S3Limits.executorStreamBytes,
              facts.stderrByteCount >= 0,
              facts.stderrByteCount <= S3Limits.executorStreamBytes else {
            throw S3ExecutorFailure.observationLimit
        }
        switch facts.finalState {
        case .exited(0): break
        case .exited(1) where tool == .search: break
        case .unknown: throw S3ExecutorFailure.incompleteDrain
        default: throw S3ExecutorFailure.nonzeroExit
        }
        switch payload {
        case let .list(entries):
            guard entries.count <= S3Limits.maximumEntries,
                  entries.allSatisfy({
                      !$0.isEmpty && $0.utf8.count <= S3Limits.maximumLineBytes
                  }) else {
                throw S3ExecutorFailure.observationLimit
            }
        case let .search(matches):
            guard matches.count <= S3Limits.maximumMatches,
                  matches.allSatisfy({
                      !$0.path.isEmpty
                          && $0.line > 0
                          && $0.text.utf8.count <= S3Limits.maximumLineBytes
                  }) else {
                throw S3ExecutorFailure.observationLimit
            }
        case let .read(path, content):
            guard !path.isEmpty,
                  content.utf8.count <= S3Limits.maximumReadBytes,
                  content.split(separator: "\n", omittingEmptySubsequences: false).allSatisfy({
                      $0.utf8.count <= S3Limits.maximumLineBytes
                  }) else {
                throw S3ExecutorFailure.observationLimit
            }
        }
    }
}

enum S3ExecutorFailure: Error, Equatable, CustomStringConvertible {
    case preparation
    case rejected
    case nonzeroExit
    case incompleteDrain
    case observationLimit
    case malformedObservation

    var description: String {
        switch self {
        case .preparation: return "read-only executor preparation failed"
        case .rejected: return "read-only executor input rejected"
        case .nonzeroExit: return "read-only executor returned nonzero exit"
        case .incompleteDrain: return "read-only executor did not observe root exit and both EOFs"
        case .observationLimit: return "read-only observation exceeded a cap"
        case .malformedObservation: return "read-only observation malformed"
        }
    }
}

enum S3ExecutorOutcome: Equatable, Sendable, CustomStringConvertible {
    case observation(S3ToolObservation)
    case failure(S3ExecutorFailure)
    case unknown

    var description: String {
        switch self {
        case let .observation(value): return value.description
        case let .failure(failure): return failure.description
        case .unknown: return "read-only executor result unknown; reconciliation required"
        }
    }
}

protocol S3ReadOnlyExecuting: Sendable {
    func execute(_ tool: S3AuthorizedTool) async -> S3ExecutorOutcome
}
