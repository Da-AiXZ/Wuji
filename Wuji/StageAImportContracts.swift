import Foundation

struct StageAImportPolicy: Equatable, Sendable {
    let maximumEntryCount: Int
    let maximumFileBytes: UInt64
    let maximumTotalBytes: UInt64
    let maximumCompressionRatio: UInt64
    let maximumPathBytes: Int
    let maximumDirectoryDepth: Int
    let minimumRemainingCapacityBytes: Int64
    let maximumDiagnosticBytes: Int

    static let production = StageAImportPolicy(
        maximumEntryCount: 50_000,
        maximumFileBytes: 256 * 1_024 * 1_024,
        maximumTotalBytes: 2 * 1_024 * 1_024 * 1_024,
        maximumCompressionRatio: 100,
        maximumPathBytes: 1_024,
        maximumDirectoryDepth: 64,
        minimumRemainingCapacityBytes: 512 * 1_024 * 1_024,
        maximumDiagnosticBytes: 256 * 1_024
    )

    init(
        maximumEntryCount: Int,
        maximumFileBytes: UInt64,
        maximumTotalBytes: UInt64,
        maximumCompressionRatio: UInt64,
        maximumPathBytes: Int,
        maximumDirectoryDepth: Int,
        minimumRemainingCapacityBytes: Int64,
        maximumDiagnosticBytes: Int
    ) {
        precondition(maximumEntryCount > 0)
        precondition(maximumFileBytes > 0)
        precondition(maximumTotalBytes > 0)
        precondition(maximumCompressionRatio > 0)
        precondition(maximumPathBytes > 0)
        precondition(maximumDirectoryDepth > 0)
        precondition(minimumRemainingCapacityBytes >= 0)
        precondition(maximumDiagnosticBytes > 0)
        self.maximumEntryCount = maximumEntryCount
        self.maximumFileBytes = maximumFileBytes
        self.maximumTotalBytes = maximumTotalBytes
        self.maximumCompressionRatio = maximumCompressionRatio
        self.maximumPathBytes = maximumPathBytes
        self.maximumDirectoryDepth = maximumDirectoryDepth
        self.minimumRemainingCapacityBytes = minimumRemainingCapacityBytes
        self.maximumDiagnosticBytes = maximumDiagnosticBytes
    }
}

enum StageAImportSourceKind: String, Codable, Equatable, Sendable {
    case folder
    case zip
}

enum StageAEntryKind: String, Codable, Equatable, Sendable {
    case file
    case directory
}

enum StageAImportError: String, Error, Codable, Equatable, Sendable, CustomStringConvertible {
    case ambiguousInput = "ambiguous_input"
    case unsupportedInput = "unsupported_input"
    case sourceUnavailable = "source_unavailable"
    case pathAbsolute = "path_absolute"
    case pathTraversal = "path_traversal"
    case pathTooLong = "path_too_long"
    case pathTooDeep = "path_too_deep"
    case pathCollision = "path_collision"
    case parentFileCollision = "parent_file_collision"
    case unsupportedType = "unsupported_type"
    case linkRejected = "link_rejected"
    case encryptedArchive = "encrypted_archive"
    case unsupportedCompression = "unsupported_compression"
    case entryLimitExceeded = "entry_limit_exceeded"
    case fileLimitExceeded = "file_limit_exceeded"
    case totalLimitExceeded = "total_limit_exceeded"
    case compressionRatioExceeded = "compression_ratio_exceeded"
    case insufficientCapacity = "insufficient_capacity"
    case unsafeOverwrite = "unsafe_overwrite"
    case boundaryEscape = "boundary_escape"
    case evidenceWriteFailed = "evidence_write_failed"
    case externalResultUnknown = "external_result_unknown"
    case extractionFailed = "extraction_failed"
    case copyFailed = "copy_failed"
    case cancelled = "cancelled"

    var description: String { rawValue }
}

struct StageAPlannedEntry: Equatable, Sendable {
    let sourcePath: String
    let relativePath: String
    let identityKey: String
    let kind: StageAEntryKind
    let compressedBytes: UInt64
    let outputBytes: UInt64
}

struct StageAImportPlan: Equatable, Sendable {
    let entries: [StageAPlannedEntry]
    let totalOutputBytes: UInt64
    let fileCount: Int
    let directoryCount: Int
}

enum StageAPathPolicy {
    private static let comparisonLocale = Locale(identifier: "en_US_POSIX")

    static func plan(
        sourcePath: String,
        kind: StageAEntryKind,
        compressedBytes: UInt64,
        outputBytes: UInt64,
        policy: StageAImportPolicy
    ) throws -> StageAPlannedEntry {
        guard !sourcePath.isEmpty,
              !sourcePath.hasPrefix("/"),
              !sourcePath.hasPrefix("\\"),
              !sourcePath.contains("\\"),
              !looksLikeDriveAbsolutePath(sourcePath),
              sourcePath.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0) && $0.value != 0
              }) else {
            throw StageAImportError.pathAbsolute
        }

        var path = sourcePath
        if kind == .directory, path.hasSuffix("/") {
            path.removeLast()
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw StageAImportError.pathTraversal
        }
        let directoryDepth = kind == .directory ? components.count : max(components.count - 1, 0)
        guard directoryDepth <= policy.maximumDirectoryDepth else {
            throw StageAImportError.pathTooDeep
        }

        let normalizedComponents = components.map { $0.precomposedStringWithCanonicalMapping }
        let normalized = normalizedComponents.joined(separator: "/")
        guard sourcePath.utf8.count <= policy.maximumPathBytes,
              normalized.utf8.count <= policy.maximumPathBytes else {
            throw StageAImportError.pathTooLong
        }
        guard outputBytes <= policy.maximumFileBytes || kind == .directory else {
            throw StageAImportError.fileLimitExceeded
        }

        let identity = normalized
            .folding(options: [.caseInsensitive], locale: comparisonLocale)
            .precomposedStringWithCanonicalMapping
        return StageAPlannedEntry(
            sourcePath: sourcePath,
            relativePath: normalized,
            identityKey: identity,
            kind: kind,
            compressedBytes: compressedBytes,
            outputBytes: outputBytes
        )
    }

    static func finalize(
        _ entries: [StageAPlannedEntry],
        policy: StageAImportPolicy,
        appliesCompressionRatio: Bool
    ) throws -> StageAImportPlan {
        guard !entries.isEmpty else { throw StageAImportError.ambiguousInput }
        guard entries.count <= policy.maximumEntryCount else {
            throw StageAImportError.entryLimitExceeded
        }

        var identities = Set<String>()
        var paths = Set<String>()
        var kindByPath: [String: StageAEntryKind] = [:]
        var total: UInt64 = 0
        for entry in entries {
            guard identities.insert(entry.identityKey).inserted,
                  paths.insert(entry.relativePath).inserted else {
                throw StageAImportError.pathCollision
            }
            kindByPath[entry.relativePath] = entry.kind
            guard entry.outputBytes <= policy.maximumTotalBytes,
                  total <= policy.maximumTotalBytes - entry.outputBytes else {
                throw StageAImportError.totalLimitExceeded
            }
            total += entry.outputBytes
            if appliesCompressionRatio, entry.kind == .file, entry.outputBytes > 0 {
                guard entry.compressedBytes > 0 else {
                    throw StageAImportError.compressionRatioExceeded
                }
                let product = entry.compressedBytes.multipliedReportingOverflow(
                    by: policy.maximumCompressionRatio
                )
                guard product.overflow || entry.outputBytes <= product.partialValue else {
                    throw StageAImportError.compressionRatioExceeded
                }
            }
        }
        guard total <= policy.maximumTotalBytes else {
            throw StageAImportError.totalLimitExceeded
        }

        for entry in entries {
            let components = entry.relativePath.split(separator: "/").map(String.init)
            guard components.count > 1 else { continue }
            for end in 1..<components.count {
                let parent = components[0..<end].joined(separator: "/")
                if kindByPath[parent] == .file {
                    throw StageAImportError.parentFileCollision
                }
            }
        }

        return StageAImportPlan(
            entries: entries,
            totalOutputBytes: total,
            fileCount: entries.filter { $0.kind == .file }.count,
            directoryCount: entries.filter { $0.kind == .directory }.count
        )
    }

    static func containedURL(root: URL, relativePath: String, isDirectory: Bool) throws -> URL {
        let canonicalRoot = root.standardizedFileURL
        let candidate = canonicalRoot
            .appendingPathComponent(relativePath, isDirectory: isDirectory)
            .standardizedFileURL
        let rootPath = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
        guard candidate.path != canonicalRoot.path,
              candidate.path.hasPrefix(rootPath) else {
            throw StageAImportError.boundaryEscape
        }
        return candidate
    }

    private static func looksLikeDriveAbsolutePath(_ path: String) -> Bool {
        let scalars = Array(path.unicodeScalars.prefix(2))
        guard scalars.count == 2 else { return false }
        return CharacterSet.letters.contains(scalars[0]) && scalars[1] == ":"
    }
}
