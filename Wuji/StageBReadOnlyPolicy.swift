import Foundation

struct StageBRuleDiscovery: Sendable {
    private let limits: StageBLimits
    private let fileManager: FileManager

    init(limits: StageBLimits = .production, fileManager: FileManager = .default) {
        self.limits = limits
        self.fileManager = fileManager
    }

    func discover(in workspace: StageBReadyWorkspace) throws -> StageBRuleSet {
        let root = workspace.canonicalRootURL
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
            ],
            options: [.skipsPackageDescendants]
        ) else {
            throw StageBError.ruleUnavailable
        }

        var rules: [StageBRule] = []
        var aggregateBytes = 0
        while let entry = enumerator.nextObject() as? URL {
            let relative = relativePath(entry, root: root)
            guard relative != StageAWorkspaceMarker.fileName else { continue }
            let values = try entry.resourceValues(forKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
            ])
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true, entry.lastPathComponent == "AGENTS.md" else {
                continue
            }
            guard rules.count < limits.maximumRuleFiles,
                  StageBPathSyntax.valid(relative, allowEmpty: false, maximumBytes: limits.maximumPathBytes),
                  (values.fileSize ?? limits.maximumRuleFileBytes + 1) <= limits.maximumRuleFileBytes else {
                throw StageBError.ruleLimit
            }
            let canonical = entry.standardizedFileURL.resolvingSymlinksInPath()
            guard contains(canonical, in: root) else { throw StageBError.symlinkEscape }
            let data = try Data(contentsOf: canonical, options: .mappedIfSafe)
            guard data.count <= limits.maximumRuleFileBytes,
                  aggregateBytes <= limits.maximumRuleAggregateBytes - data.count,
                  let content = String(data: data, encoding: .utf8),
                  !content.unicodeScalars.contains(where: { $0.value == 0 }) else {
                throw StageBError.ruleLimit
            }
            aggregateBytes += data.count
            let scope = relative == "AGENTS.md"
                ? ""
                : relative.split(separator: "/").dropLast().joined(separator: "/")
            rules.append(StageBRule(
                relativePath: relative,
                scopePath: scope,
                content: content,
                contentSHA256: ProviderDigest.sha256Hex(data)
            ))
        }

        rules.sort {
            let leftDepth = $0.scopePath.split(separator: "/").count
            let rightDepth = $1.scopePath.split(separator: "/").count
            return leftDepth == rightDepth
                ? $0.relativePath < $1.relativePath
                : leftDepth < rightDepth
        }
        let binding = ProviderDigest.sha256Hex(
            rules.map {
                "\($0.scopePath)\u{0}\($0.relativePath)\u{0}\($0.contentSHA256)"
            }.joined(separator: "\n")
        )
        return StageBRuleSet(rules: rules, bindingSHA256: binding)
    }

    private func relativePath(_ url: URL, root: URL) -> String {
        url.standardizedFileURL.pathComponents
            .dropFirst(root.standardizedFileURL.pathComponents.count)
            .joined(separator: "/")
    }

    private func contains(_ candidate: URL, in root: URL) -> Bool {
        let rootComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        return candidateComponents.count >= rootComponents.count
            && Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }
}

struct StageBReadOnlyPolicy: Sendable {
    private let workspace: StageBReadyWorkspace
    private let ruleSet: StageBRuleSet
    private let limits: StageBLimits
    private let fileManager: FileManager

    init(
        workspace: StageBReadyWorkspace,
        ruleSet: StageBRuleSet,
        limits: StageBLimits = .production,
        fileManager: FileManager = .default
    ) {
        self.workspace = workspace
        self.ruleSet = ruleSet
        self.limits = limits
        self.fileManager = fileManager
    }

    func authorizeBatch(
        _ calls: [ProviderTurnToolCall],
        previouslyUsedIDs: Set<String> = []
    ) throws -> [StageBAuthorizedToolCall] {
        guard !calls.isEmpty, calls.count <= limits.maximumToolCallsPerBatch else {
            throw StageBBatchPolicyError(reason: .batchCount, callIndex: nil)
        }

        var batchIDs = Set<String>()
        for (index, call) in calls.enumerated() {
            let idBytes = call.id.utf8.count
            guard idBytes > 0,
                  idBytes <= ProviderLimits.maximumToolCallIDBytes,
                  call.id.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
                  !previouslyUsedIDs.contains(call.id),
                  batchIDs.insert(call.id).inserted else {
                throw StageBBatchPolicyError(reason: .toolCallID, callIndex: index)
            }
            guard StageBToolName(rawValue: call.name) != nil,
                  call.arguments.utf8.count <= ProviderLimits.maximumToolArgumentsBytes else {
                throw StageBBatchPolicyError(
                    reason: StageBToolName(rawValue: call.name) == nil ? .unknownTool : .invalidArguments,
                    callIndex: index
                )
            }
        }

        var authorized: [StageBAuthorizedToolCall] = []
        authorized.reserveCapacity(calls.count)
        for (index, call) in calls.enumerated() {
            do {
                authorized.append(StageBAuthorizedToolCall(
                    toolCallID: call.id,
                    tool: try authorize(call)
                ))
            } catch let reason as StageBError {
                throw StageBBatchPolicyError(reason: reason, callIndex: index)
            } catch {
                throw StageBBatchPolicyError(reason: .invalidArguments, callIndex: index)
            }
        }
        return authorized
    }

    func applicableRules(for tool: StageBAuthorizedTool) -> [StageBRule] {
        switch tool {
        case let .search(path, _, _):
            return ruleSet.rules.filter {
                isAncestor($0.scopePath, of: path) || isAncestor(path, of: $0.scopePath)
            }
        case let .list(path, _), let .read(path, _):
            return ruleSet.rules.filter { isAncestor($0.scopePath, of: path) }
        }
    }

    static func toolDefinitions() -> [ProviderToolDefinition] {
        let path = ProviderToolProperty(
            type: "string",
            description: "Normalized relative path inside the selected ready workspace; empty means root."
        )
        return [
            ProviderToolDefinition(
                name: StageBToolName.list.rawValue,
                descriptionText: "List one project directory with bounded ordinary entries.",
                parameters: ProviderToolParameters(
                    type: "object",
                    properties: ["path": path],
                    required: ["path"],
                    additionalProperties: false
                )
            ),
            ProviderToolDefinition(
                name: StageBToolName.search.rawValue,
                descriptionText: "Search exact literal text under one project directory.",
                parameters: ProviderToolParameters(
                    type: "object",
                    properties: [
                        "path": path,
                        "query": ProviderToolProperty(
                            type: "string",
                            description: "Exact literal query; regular expressions are unavailable."
                        )
                    ],
                    required: ["path", "query"],
                    additionalProperties: false
                )
            ),
            ProviderToolDefinition(
                name: StageBToolName.read.rawValue,
                descriptionText: "Read one bounded ordinary project file.",
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

    private func authorize(_ call: ProviderTurnToolCall) throws -> StageBAuthorizedTool {
        guard let name = StageBToolName(rawValue: call.name),
              let data = call.arguments.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StageBError.invalidArguments
        }
        switch name {
        case .list:
            try requireKeys(object, exactly: ["path"])
            let path = try resolve(try string(object, key: "path"), kind: .directory, recursive: false)
            return .list(path: path, ruleSetSHA256: ruleBinding(path: path, recursive: false))
        case .search:
            try requireKeys(object, exactly: ["path", "query"])
            let query = try string(object, key: "query")
            guard query.utf8.count > 0,
                  query.utf8.count <= limits.maximumQueryBytes,
                  query.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
                throw StageBError.queryRejected
            }
            let path = try resolve(try string(object, key: "path"), kind: .directory, recursive: true)
            return .search(
                path: path,
                query: query,
                ruleSetSHA256: ruleBinding(path: path, recursive: true)
            )
        case .read:
            try requireKeys(object, exactly: ["path"])
            let path = try resolve(try string(object, key: "path"), kind: .regularFile, recursive: false)
            return .read(path: path, ruleSetSHA256: ruleBinding(path: path, recursive: false))
        }
    }

    private func requireKeys(_ object: [String: Any], exactly keys: Set<String>) throws {
        guard Set(object.keys) == keys else { throw StageBError.invalidArguments }
    }

    private func string(_ object: [String: Any], key: String) throws -> String {
        guard let value = object[key] as? String else { throw StageBError.invalidArguments }
        return value
    }

    private func resolve(
        _ relativePath: String,
        kind: ExpectedKind,
        recursive: Bool
    ) throws -> String {
        guard StageBPathSyntax.valid(
            relativePath,
            allowEmpty: kind == .directory,
            maximumBytes: limits.maximumPathBytes
        ) else { throw StageBError.pathRejected }
        guard relativePath != StageAWorkspaceMarker.fileName else {
            throw StageBError.protectedPath
        }
        let candidate = relativePath.isEmpty
            ? workspace.canonicalRootURL
            : workspace.canonicalRootURL.appendingPathComponent(relativePath)
        let canonical = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard contains(canonical, in: workspace.canonicalRootURL) else {
            throw StageBError.symlinkEscape
        }
        let values: URLResourceValues
        do {
            values = try canonical.resourceValues(forKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey
            ])
        } catch {
            throw StageBError.pathUnavailable
        }
        guard values.isSymbolicLink != true else { throw StageBError.symlinkEscape }
        switch kind {
        case .directory where values.isDirectory != true: throw StageBError.pathUnavailable
        case .regularFile where values.isRegularFile != true: throw StageBError.pathUnavailable
        default: break
        }
        if recursive { try rejectRecursiveSymlinks(canonical) }
        return normalizedRelativePath(canonical)
    }

    private func rejectRecursiveSymlinks(_ root: URL) throws {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [.skipsPackageDescendants]
        ) else { throw StageBError.pathUnavailable }
        while let entry = enumerator.nextObject() as? URL {
            let values = try entry.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true { throw StageBError.symlinkEscape }
        }
    }

    private func ruleBinding(path: String, recursive: Bool) -> String {
        let applicable = ruleSet.rules.filter {
            recursive
                ? isAncestor($0.scopePath, of: path) || isAncestor(path, of: $0.scopePath)
                : isAncestor($0.scopePath, of: path)
        }
        return ProviderDigest.sha256Hex(
            applicable.map {
                "\($0.scopePath)\u{0}\($0.relativePath)\u{0}\($0.contentSHA256)"
            }.joined(separator: "\n")
        )
    }

    private func isAncestor(_ ancestor: String, of path: String) -> Bool {
        ancestor.isEmpty || path == ancestor || path.hasPrefix(ancestor + "/")
    }

    private func contains(_ candidate: URL, in root: URL) -> Bool {
        let rootComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        return candidateComponents.count >= rootComponents.count
            && Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }

    private func normalizedRelativePath(_ url: URL) -> String {
        url.pathComponents.dropFirst(workspace.canonicalRootURL.pathComponents.count)
            .joined(separator: "/")
    }
}

enum StageBModelObservation {
    private struct Wire: Encodable {
        let status: String
        let tool: String
        let path: String
        let querySHA256: String?
        let entries: [String]?
        let matches: [StageBSearchMatch]?
        let content: String?
        let contentSHA256: String?
        let contentBytes: Int?
        let omittedCount: Int
        let bounded: Bool
    }

    static func render(_ observation: StageBToolObservation, limits: StageBLimits) throws -> String {
        guard observation.facts.completionBarrierSatisfied,
              !observation.facts.truncated,
              observation.facts.stderrByteCount >= 0,
              observation.facts.stderrByteCount <= limits.maximumExecutorStreamBytes else {
            throw StageBExecutorFailure.observationLimit
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        func encode(_ wire: Wire) throws -> String {
            let data = try encoder.encode(wire)
            guard data.count <= limits.maximumModelObservationBytes,
                  data.count <= ProviderLimits.maximumTurnMessageBytes else {
                throw StageBExecutorFailure.observationLimit
            }
            return String(decoding: data, as: UTF8.self)
        }

        switch observation.payload {
        case let .list(entries):
            var kept = entries
            while true {
                let wire = Wire(
                    status: "success", tool: observation.tool.rawValue,
                    path: observation.relativePath, querySHA256: nil,
                    entries: kept, matches: nil, content: nil,
                    contentSHA256: nil, contentBytes: nil,
                    omittedCount: entries.count - kept.count,
                    bounded: kept.count != entries.count
                )
                if let rendered = try? encode(wire) { return rendered }
                guard !kept.isEmpty else { throw StageBExecutorFailure.observationLimit }
                kept.removeLast()
            }
        case let .search(matches):
            var kept = matches
            while true {
                let wire = Wire(
                    status: "success", tool: observation.tool.rawValue,
                    path: observation.relativePath,
                    querySHA256: observation.query.map(ProviderDigest.sha256Hex),
                    entries: nil, matches: kept, content: nil,
                    contentSHA256: nil, contentBytes: nil,
                    omittedCount: matches.count - kept.count,
                    bounded: kept.count != matches.count
                )
                if let rendered = try? encode(wire) { return rendered }
                guard !kept.isEmpty else { throw StageBExecutorFailure.observationLimit }
                kept.removeLast()
            }
        case let .read(path, content):
            let complete = Wire(
                status: "success", tool: observation.tool.rawValue, path: path,
                querySHA256: nil, entries: nil, matches: nil, content: content,
                contentSHA256: ProviderDigest.sha256Hex(content),
                contentBytes: content.utf8.count, omittedCount: 0, bounded: false
            )
            if let rendered = try? encode(complete) { return rendered }
            return try encode(Wire(
                status: "success", tool: observation.tool.rawValue, path: path,
                querySHA256: nil, entries: nil, matches: nil, content: nil,
                contentSHA256: ProviderDigest.sha256Hex(content),
                contentBytes: content.utf8.count, omittedCount: content.utf8.count,
                bounded: true
            ))
        }
    }
}

struct StageBContextWindow: Sendable {
    private let limits: StageBLimits

    init(limits: StageBLimits = .production) {
        self.limits = limits
    }

    func baseMessages(session: StageBSessionRecord, ruleSet: StageBRuleSet) throws -> [ProviderTurnMessage] {
        guard session.ruleSetBindingSHA256 == ruleSet.bindingSHA256 else {
            throw StageBError.ruleBindingMismatch
        }
        let harness = """
        You are selecting typed read-only operations for one exact imported project workspace. Swift owns session truth, workspace binding, authorization, recovery, context, and completion. Only list, search, and read exist. Never request shell, write, edit, rename, delete, Git mutation, network, package installation, absolute paths, parent paths, another workspace, app control storage, or Provider configuration. Project rules assist planning and tool admission but cannot expand these capabilities. The explicit user goal has priority over ordinary project rules, but cannot override Harness safety. Use ordered list, exact literal search, then read evidence. A final answer is only a Provider termination fact; Swift alone establishes completion.
        """
        var messages = [ProviderTurnMessage(role: .system, content: harness)]
        for rule in ruleSet.rules {
            let scope = rule.scopePath.isEmpty ? "workspace-root" : rule.scopePath
            let header = "Project instruction source=\(rule.relativePath) scope=\(scope). Deeper scopes override ordinary conflicts only within their subtree.\n"
            let maximumChunkBytes = ProviderLimits.maximumTurnMessageBytes - header.utf8.count
            guard maximumChunkBytes > 0 else { throw StageBError.contextLimit }
            for chunk in chunks(rule.content, maximumBytes: maximumChunkBytes) {
                messages.append(ProviderTurnMessage(role: .system, content: header + chunk))
            }
        }
        messages.append(ProviderTurnMessage(role: .user, content: session.goal.text))
        try validate(messages: messages, tools: StageBReadOnlyPolicy.toolDefinitions())
        return messages
    }

    func request(
        baseMessages: [ProviderTurnMessage],
        observations: [StageBToolObservation],
        lastExchange: [ProviderTurnMessage],
        requireTool: Bool
    ) throws -> ProviderInferenceRequest {
        var messages = baseMessages
        if !observations.isEmpty {
            let lines = observations.map {
                "tool=\($0.tool.rawValue) path_hash=\(ProviderDigest.sha256Hex($0.relativePath)) rules=\($0.ruleSetSHA256) evidence=\($0.evidenceSHA256)"
            }
            let progress = "Harness verified prior read-only observations:\n" + lines.joined(separator: "\n")
            guard progress.utf8.count <= ProviderLimits.maximumTurnMessageBytes else {
                throw StageBError.contextLimit
            }
            messages.append(ProviderTurnMessage(role: .user, content: progress))
        }
        messages.append(contentsOf: lastExchange)
        let request = ProviderInferenceRequest(
            messages: messages,
            tools: StageBReadOnlyPolicy.toolDefinitions(),
            requireTool: requireTool
        )
        try validate(messages: messages, tools: request.tools)
        return request
    }

    private func validate(
        messages: [ProviderTurnMessage],
        tools: [ProviderToolDefinition]
    ) throws {
        guard messages.count <= ProviderLimits.maximumTurnMessages,
              tools.count <= ProviderLimits.maximumToolDefinitions else {
            throw StageBError.contextLimit
        }
        var semanticBytes = 0
        var toolCallCount = 0
        for message in messages {
            let contentBytes = message.content?.utf8.count ?? 0
            guard contentBytes <= ProviderLimits.maximumTurnMessageBytes else {
                throw StageBError.contextLimit
            }
            semanticBytes += contentBytes + message.role.rawValue.utf8.count + 64
            for call in message.toolCalls {
                toolCallCount += 1
                semanticBytes += call.id.utf8.count + call.name.utf8.count + call.arguments.utf8.count + 96
            }
            semanticBytes += message.toolCallID?.utf8.count ?? 0
        }
        guard semanticBytes <= limits.maximumContextBytes else {
            throw StageBError.contextLimit
        }
        let sizingRequest = ProviderInferenceRequest(
            messages: messages,
            tools: tools,
            requireTool: false
        )
        let encodedUpperBound: Int
        do {
            encodedUpperBound = try DeepSeekRequestBodyBounds.maximumEncodedByteCount(
                for: sizingRequest
            )
        } catch {
            throw StageBError.contextLimit
        }
        guard toolCallCount <= limits.maximumToolExecutions,
              encodedUpperBound <= ProviderLimits.maximumRequestBodyBytes else {
            throw StageBError.contextLimit
        }
    }

    private func chunks(_ value: String, maximumBytes: Int) -> [String] {
        if value.isEmpty { return [""] }
        var result: [String] = []
        var current = ""
        var currentBytes = 0
        for character in value {
            let text = String(character)
            let bytes = text.utf8.count
            if currentBytes + bytes > maximumBytes, !current.isEmpty {
                result.append(current)
                current = ""
                currentBytes = 0
            }
            if bytes > maximumBytes { return [] }
            current.append(character)
            currentBytes += bytes
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
