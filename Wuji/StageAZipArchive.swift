import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct StageAZipEntryDescriptor: Equatable, Sendable {
    let sourcePath: String
    let compressedBytes: UInt64
    let outputBytes: UInt64
    let generalPurposeFlags: UInt16
    let compressionMethod: UInt16
    let isDirectory: Bool
    let hasDirectoryMarker: Bool
    let isSymlink: Bool
    let hasLinkName: Bool
    let isSpecialFile: Bool
    let isSupportedHostSystem: Bool
}

enum StageAZipEntryPolicy {
    static func plan(
        descriptor: StageAZipEntryDescriptor,
        policy: StageAImportPolicy
    ) throws -> StageAPlannedEntry {
        guard descriptor.isSupportedHostSystem, !descriptor.isSpecialFile else {
            throw StageAImportError.unsupportedType
        }
        guard !descriptor.isSymlink, !descriptor.hasLinkName else {
            throw StageAImportError.linkRejected
        }
        let encryptedOrMaskedFlags: UInt16 = 0x0001 | 0x0040 | 0x2000
        guard descriptor.generalPurposeFlags & encryptedOrMaskedFlags == 0 else {
            throw StageAImportError.encryptedArchive
        }
        guard descriptor.generalPurposeFlags & 0x0020 == 0 else {
            throw StageAImportError.unsupportedInput
        }
        guard descriptor.compressionMethod == 0 || descriptor.compressionMethod == 8 else {
            throw StageAImportError.unsupportedCompression
        }
        let hasNonASCIIPathByte = descriptor.sourcePath.utf8.contains { $0 >= 0x80 }
        guard !hasNonASCIIPathByte || descriptor.generalPurposeFlags & 0x0800 != 0 else {
            throw StageAImportError.ambiguousInput
        }
        guard descriptor.isDirectory == descriptor.hasDirectoryMarker else {
            throw StageAImportError.ambiguousInput
        }
        if descriptor.isDirectory, descriptor.outputBytes != 0 {
            throw StageAImportError.ambiguousInput
        }
        return try StageAPathPolicy.plan(
            sourcePath: descriptor.sourcePath,
            kind: descriptor.isDirectory ? .directory : .file,
            compressedBytes: descriptor.compressedBytes,
            outputBytes: descriptor.outputBytes,
            policy: policy
        )
    }
}

final class StageAZipArchive {
    private var reader: OpaquePointer?

    init(url: URL) throws {
        var opened: OpaquePointer?
        let result = url.path.withCString { path in
            wuji_stage_a_zip_open(path, &opened)
        }
        guard result == WUJI_STAGE_A_ZIP_OK, let opened else {
            throw StageAImportError.unsupportedInput
        }
        reader = opened
    }

    deinit {
        wuji_stage_a_zip_close(&reader)
    }

    func preflight(policy: StageAImportPolicy) throws -> StageAImportPlan {
        guard let reader else { throw StageAImportError.unsupportedInput }
        var entries: [StageAPlannedEntry] = []
        var result = wuji_stage_a_zip_first(reader)
        while result == WUJI_STAGE_A_ZIP_OK {
            if entries.count >= policy.maximumEntryCount {
                throw StageAImportError.entryLimitExceeded
            }
            let current = try currentEntry(reader: reader, policy: policy)
            entries.append(current)
            result = wuji_stage_a_zip_next(reader)
        }
        guard result == WUJI_STAGE_A_ZIP_END else {
            throw StageAImportError.unsupportedInput
        }
        return try StageAPathPolicy.finalize(
            entries,
            policy: policy,
            appliesCompressionRatio: true
        )
    }

    func extract(plan: StageAImportPlan, to stagingURL: URL, policy: StageAImportPolicy) throws {
        guard let reader else { throw StageAImportError.extractionFailed }
        let fileManager = FileManager.default
        var result = wuji_stage_a_zip_first(reader)
        var index = 0
        while result == WUJI_STAGE_A_ZIP_OK {
            guard index < plan.entries.count else { throw StageAImportError.externalResultUnknown }
            let expected = plan.entries[index]
            let current = try currentEntry(reader: reader, policy: policy)
            guard current == expected else { throw StageAImportError.externalResultUnknown }
            let destination = try StageAPathPolicy.containedURL(
                root: stagingURL,
                relativePath: expected.relativePath,
                isDirectory: expected.kind == .directory
            )
            if expected.kind == .directory {
                try createDirectoryIfAbsent(destination, root: stagingURL, fileManager: fileManager)
            } else {
                try createDirectoryIfAbsent(
                    destination.deletingLastPathComponent(),
                    root: stagingURL,
                    fileManager: fileManager
                )
                guard !fileManager.fileExists(atPath: destination.path) else {
                    throw StageAImportError.unsafeOverwrite
                }
                let descriptor = destination.path.withCString {
                    open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
                }
                guard descriptor >= 0 else { throw StageAImportError.unsafeOverwrite }
                var written: UInt64 = 0
                let extractionResult = wuji_stage_a_zip_extract_current_to_fd(
                    reader,
                    descriptor,
                    expected.outputBytes,
                    &written
                )
                let syncResult = fsync(descriptor)
                let closeResult = close(descriptor)
                guard extractionResult == WUJI_STAGE_A_ZIP_OK,
                      syncResult == 0,
                      closeResult == 0,
                      written == expected.outputBytes else {
                    throw StageAImportError.extractionFailed
                }
            }
            index += 1
            result = wuji_stage_a_zip_next(reader)
        }
        guard result == WUJI_STAGE_A_ZIP_END, index == plan.entries.count else {
            throw StageAImportError.externalResultUnknown
        }
    }

    private func currentEntry(
        reader: OpaquePointer,
        policy: StageAImportPolicy
    ) throws -> StageAPlannedEntry {
        var metadata = wuji_stage_a_zip_entry()
        var pathBuffer = [CChar](repeating: 0, count: policy.maximumPathBytes + 1)
        let result = pathBuffer.withUnsafeMutableBufferPointer { buffer in
            wuji_stage_a_zip_current_entry(
                reader,
                &metadata,
                buffer.baseAddress,
                buffer.count
            )
        }
        if result == WUJI_STAGE_A_ZIP_BUFFER_TOO_SMALL {
            throw StageAImportError.pathTooLong
        }
        guard result == WUJI_STAGE_A_ZIP_OK else {
            throw StageAImportError.unsupportedInput
        }
        let count = Int(metadata.path_byte_count)
        let data = Data(bytes: pathBuffer, count: count)
        guard let sourcePath = String(data: data, encoding: .utf8), !sourcePath.isEmpty else {
            throw StageAImportError.ambiguousInput
        }
        return try StageAZipEntryPolicy.plan(
            descriptor: StageAZipEntryDescriptor(
                sourcePath: sourcePath,
                compressedBytes: metadata.compressed_size,
                outputBytes: metadata.uncompressed_size,
                generalPurposeFlags: metadata.general_purpose_flags,
                compressionMethod: metadata.compression_method,
                isDirectory: metadata.is_directory == 1,
                hasDirectoryMarker: metadata.has_directory_marker == 1,
                isSymlink: metadata.is_symlink == 1,
                hasLinkName: metadata.has_link_name == 1,
                isSpecialFile: metadata.is_special_file == 1,
                isSupportedHostSystem: metadata.is_supported_host_system == 1
            ),
            policy: policy
        )
    }

    private func createDirectoryIfAbsent(
        _ url: URL,
        root: URL,
        fileManager: FileManager
    ) throws {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = url.standardizedFileURL.path
        guard candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/") else {
            throw StageAImportError.boundaryEscape
        }
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw StageAImportError.unsafeOverwrite }
            return
        }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
