import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

protocol StageAExternalFileCoordinating: Sendable {
    func coordinateRead<T>(at url: URL, _ body: (URL) throws -> T) throws -> T
}

struct StageANSFileCoordinator: StageAExternalFileCoordinating, @unchecked Sendable {
    func coordinateRead<T>(at url: URL, _ body: (URL) throws -> T) throws -> T {
        var coordinationError: NSError?
        var bodyResult: Result<T, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) {
            coordinatedURL in
            bodyResult = Result { try body(coordinatedURL) }
        }
        if let coordinationError { throw coordinationError }
        guard let bodyResult else { throw StageAImportError.externalResultUnknown }
        return try bodyResult.get()
    }
}

enum StageAImportCheckpoint: Sendable {
    case stagingCreated
    case contentCopied
    case markerWritten
    case workspacePublished
}

actor StageAWorkspaceImporter {
    private struct FolderEntry {
        let sourceURL: URL
        let planned: StageAPlannedEntry
    }

    private let store: StageAWorkspaceStore
    private let policy: StageAImportPolicy
    private let fileManager: FileManager
    private let coordinator: any StageAExternalFileCoordinating
    private let now: @Sendable () -> Date
    private let checkpoint: @Sendable (StageAImportCheckpoint) throws -> Void

    init(
        store: StageAWorkspaceStore,
        policy: StageAImportPolicy = .production,
        fileManager: FileManager = .default,
        coordinator: any StageAExternalFileCoordinating = StageANSFileCoordinator(),
        now: @escaping @Sendable () -> Date = { Date() },
        checkpoint: @escaping @Sendable (StageAImportCheckpoint) throws -> Void = { _ in }
    ) {
        self.store = store
        self.policy = policy
        self.fileManager = fileManager
        self.coordinator = coordinator
        self.now = now
        self.checkpoint = checkpoint
    }

    func importItem(
        at sourceURL: URL,
        expectedKind: StageAImportSourceKind
    ) async -> StageAImportRecord {
        let importID = UUID()
        let workspaceID = UUID()
        let sourceHash = ProviderDigest.sha256Hex(sourceURL.standardizedFileURL.path)
        var record: StageAImportRecord
        do {
            record = try store.begin(
                importID: importID,
                workspaceID: workspaceID,
                sourceKind: expectedKind,
                sourceDisplayName: sourceURL.lastPathComponent,
                sourcePathSHA256: sourceHash,
                now: now()
            )
        } catch {
            return StageAImportRecord(
                id: importID,
                workspaceID: workspaceID,
                sourceKind: expectedKind,
                sourceDisplayName: sourceURL.lastPathComponent,
                sourcePathSHA256: sourceHash,
                targetRelativePath: "Workspaces/" + workspaceID.uuidString.lowercased(),
                createdAt: now(),
                updatedAt: now(),
                phase: .reconciliationRequired,
                entryCount: nil,
                totalOutputBytes: nil,
                errorCode: .evidenceWriteFailed,
                diagnostics: []
            )
        }

        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }
        do {
            try Task.checkCancellation()
            return try coordinator.coordinateRead(at: sourceURL) { coordinatedURL in
                try self.performImport(
                    from: coordinatedURL,
                    expectedKind: expectedKind,
                    record: &record
                )
            }
        } catch is CancellationError {
            return await terminalRecord(
                record,
                phase: .cancelled,
                error: .cancelled,
                diagnostic: "import_cancelled"
            )
        } catch let error as StageAImportError {
            return await terminalRecord(
                record,
                phase: error == .externalResultUnknown ? .reconciliationRequired : .failed,
                error: error,
                diagnostic: error.rawValue
            )
        } catch {
            return await terminalRecord(
                record,
                phase: .reconciliationRequired,
                error: .externalResultUnknown,
                diagnostic: "unclassified_external_error"
            )
        }
    }

    func recover() async throws -> [StageAImportRecord] {
        try store.recover(now: now())
    }

    private func performImport(
        from sourceURL: URL,
        expectedKind: StageAImportSourceKind,
        record: inout StageAImportRecord
    ) throws -> StageAImportRecord {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) else {
            throw StageAImportError.sourceUnavailable
        }
        var sourceStatus = stat()
        guard lstat(sourceURL.path, &sourceStatus) == 0 else {
            throw StageAImportError.sourceUnavailable
        }
        let sourceMode = sourceStatus.st_mode & mode_t(S_IFMT)
        guard sourceMode != mode_t(S_IFLNK) else {
            throw StageAImportError.linkRejected
        }

        let plan: StageAImportPlan
        let zip: StageAZipArchive?
        let folderEntries: [FolderEntry]?
        switch expectedKind {
        case .folder:
            guard isDirectory.boolValue, sourceMode == mode_t(S_IFDIR) else {
                throw StageAImportError.ambiguousInput
            }
            let entries = try folderPreflight(sourceURL)
            folderEntries = entries
            zip = nil
            plan = try StageAPathPolicy.finalize(
                entries.map(\.planned),
                policy: policy,
                appliesCompressionRatio: false
            )
        case .zip:
            guard !isDirectory.boolValue,
                  sourceMode == mode_t(S_IFREG),
                  sourceStatus.st_nlink == 1,
                  sourceURL.pathExtension.caseInsensitiveCompare("zip") == .orderedSame else {
                throw StageAImportError.ambiguousInput
            }
            let archive = try StageAZipArchive(url: sourceURL)
            zip = archive
            folderEntries = nil
            plan = try archive.preflight(policy: policy)
        }

        try requireCapacity(for: plan.totalOutputBytes)
        let stagingURL = store.stagingURL(for: record.id)
        let workspaceURL = store.workspaceURL(for: record.workspaceID)
        guard !fileManager.fileExists(atPath: stagingURL.path),
              !fileManager.fileExists(atPath: workspaceURL.path) else {
            throw StageAImportError.unsafeOverwrite
        }
        record = try store.transition(
            record,
            to: .staging,
            plan: plan,
            diagnosticCode: "preflight_complete",
            now: now()
        )
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: false)
        try checkpoint(.stagingCreated)

        if let zip {
            try zip.extract(plan: plan, to: stagingURL, policy: policy)
        } else if let folderEntries {
            try copyFolderEntries(folderEntries, to: stagingURL)
        }
        try checkpoint(.contentCopied)
        try Task.checkCancellation()

        let marker = StageAWorkspaceMarker(
            importID: record.id,
            workspaceID: record.workspaceID,
            entryCount: plan.entries.count,
            totalOutputBytes: plan.totalOutputBytes
        )
        try store.writeMarker(marker, to: stagingURL)
        try checkpoint(.markerWritten)
        record = try store.transition(
            record,
            to: .prepared,
            plan: plan,
            diagnosticCode: "staging_prepared",
            now: now()
        )
        guard !fileManager.fileExists(atPath: workspaceURL.path) else {
            throw StageAImportError.unsafeOverwrite
        }
        record = try store.transition(
            record,
            to: .publishing,
            plan: plan,
            diagnosticCode: "publication_intent_recorded",
            now: now()
        )
        try requireRemainingCapacity()
        try fileManager.moveItem(at: stagingURL, to: workspaceURL)
        try checkpoint(.workspacePublished)
        return try store.transition(
            record,
            to: .ready,
            plan: plan,
            diagnosticCode: "workspace_ready",
            now: now()
        )
    }

    private func folderPreflight(_ root: URL) throws -> [FolderEntry] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        var enumerationFailed = false
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in
                enumerationFailed = true
                return false
            }
        ) else { throw StageAImportError.sourceUnavailable }
        let rootPath = root.standardizedFileURL.path + "/"
        var entries: [FolderEntry] = []
        for case let itemURL as URL in enumerator {
            try Task.checkCancellation()
            guard entries.count < policy.maximumEntryCount else {
                throw StageAImportError.entryLimitExceeded
            }
            let standardized = itemURL.standardizedFileURL
            guard standardized.path.hasPrefix(rootPath) else {
                throw StageAImportError.boundaryEscape
            }
            let relative = String(standardized.path.dropFirst(rootPath.count))
            let values = try itemURL.resourceValues(forKeys: Set(keys))
            var status = stat()
            guard lstat(itemURL.path, &status) == 0 else {
                throw StageAImportError.sourceUnavailable
            }
            let mode = status.st_mode & mode_t(S_IFMT)
            if values.isSymbolicLink == true || mode == mode_t(S_IFLNK) {
                throw StageAImportError.linkRejected
            }
            let kind: StageAEntryKind
            let size: UInt64
            if values.isDirectory == true, mode == mode_t(S_IFDIR) {
                kind = .directory
                size = 0
            } else if values.isRegularFile == true, mode == mode_t(S_IFREG) {
                guard status.st_nlink == 1 else { throw StageAImportError.linkRejected }
                guard status.st_size >= 0 else { throw StageAImportError.unsupportedType }
                kind = .file
                size = UInt64(status.st_size)
            } else {
                throw StageAImportError.unsupportedType
            }
            entries.append(FolderEntry(
                sourceURL: itemURL,
                planned: try StageAPathPolicy.plan(
                    sourcePath: relative,
                    kind: kind,
                    compressedBytes: size,
                    outputBytes: size,
                    policy: policy
                )
            ))
        }
        guard !enumerationFailed else { throw StageAImportError.sourceUnavailable }
        return entries
    }

    private func copyFolderEntries(_ entries: [FolderEntry], to stagingURL: URL) throws {
        for entry in entries {
            try Task.checkCancellation()
            let destination = try StageAPathPolicy.containedURL(
                root: stagingURL,
                relativePath: entry.planned.relativePath,
                isDirectory: entry.planned.kind == .directory
            )
            if entry.planned.kind == .directory {
                try createDirectoryIfAbsent(destination, under: stagingURL)
            } else {
                try createDirectoryIfAbsent(destination.deletingLastPathComponent(), under: stagingURL)
                try copyFileStreaming(
                    from: entry.sourceURL,
                    to: destination,
                    expectedBytes: entry.planned.outputBytes
                )
            }
        }
    }

    private func copyFileStreaming(from source: URL, to destination: URL, expectedBytes: UInt64) throws {
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw StageAImportError.unsafeOverwrite
        }
        let input = source.path.withCString { open($0, O_RDONLY | O_NOFOLLOW) }
        guard input >= 0 else { throw StageAImportError.copyFailed }
        var inputOpen = true
        defer { if inputOpen { _ = close(input) } }
        var openedStatus = stat()
        guard fstat(input, &openedStatus) == 0,
              openedStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              openedStatus.st_nlink == 1,
              openedStatus.st_size >= 0,
              UInt64(openedStatus.st_size) == expectedBytes else {
            throw StageAImportError.externalResultUnknown
        }
        let output = destination.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        }
        guard output >= 0 else { throw StageAImportError.unsafeOverwrite }
        var outputOpen = true
        defer { if outputOpen { _ = close(output) } }

        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var total: UInt64 = 0
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { bytes in
                read(input, bytes.baseAddress, bytes.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw StageAImportError.copyFailed }
            if count == 0 { break }
            guard UInt64(count) <= policy.maximumFileBytes,
                  total <= policy.maximumFileBytes - UInt64(count) else {
                throw StageAImportError.fileLimitExceeded
            }
            var offset = 0
            while offset < count {
                let emitted = buffer.withUnsafeBytes { bytes in
                    write(output, bytes.baseAddress!.advanced(by: offset), count - offset)
                }
                if emitted < 0, errno == EINTR { continue }
                guard emitted > 0 else { throw StageAImportError.copyFailed }
                offset += emitted
            }
            total += UInt64(count)
        }
        guard total == expectedBytes else { throw StageAImportError.externalResultUnknown }
        guard fsync(output) == 0, close(output) == 0 else {
            throw StageAImportError.copyFailed
        }
        outputOpen = false
        guard close(input) == 0 else { throw StageAImportError.externalResultUnknown }
        inputOpen = false
    }

    private func createDirectoryIfAbsent(_ url: URL, under root: URL) throws {
        let rootPath = root.standardizedFileURL.path
        let candidate = url.standardizedFileURL.path
        guard candidate == rootPath || candidate.hasPrefix(rootPath + "/") else {
            throw StageAImportError.boundaryEscape
        }
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw StageAImportError.unsafeOverwrite }
            return
        }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func requireCapacity(for outputBytes: UInt64) throws {
        let root = store.workspacesRootURL
        let values = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values.volumeAvailableCapacityForImportantUsage,
              outputBytes <= UInt64(Int64.max) else {
            throw StageAImportError.insufficientCapacity
        }
        let required = Int64(outputBytes).addingReportingOverflow(policy.minimumRemainingCapacityBytes)
        guard !required.overflow, available >= required.partialValue else {
            throw StageAImportError.insufficientCapacity
        }
    }

    private func requireRemainingCapacity() throws {
        let values = try store.workspacesRootURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        guard let available = values.volumeAvailableCapacityForImportantUsage,
              available >= policy.minimumRemainingCapacityBytes else {
            throw StageAImportError.insufficientCapacity
        }
    }

    private func terminalRecord(
        _ record: StageAImportRecord,
        phase: StageAImportPhase,
        error: StageAImportError,
        diagnostic: String
    ) async -> StageAImportRecord {
        do {
            return try store.transition(
                record,
                to: phase,
                error: error,
                diagnosticCode: diagnostic,
                now: now()
            )
        } catch {
            var unknown = record
            unknown.phase = .reconciliationRequired
            unknown.errorCode = .evidenceWriteFailed
            return unknown
        }
    }

}
