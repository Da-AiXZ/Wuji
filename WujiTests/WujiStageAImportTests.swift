import Foundation
import XCTest
@testable import Wuji

final class WujiStageAImportTests: XCTestCase {
    private let fixtureBase64 = "UEsDBBQAAAAAAMUTA10AAAAAAAAAAAAAAAAIAAAAZml4dHVyZS9QSwMEFAAAAAgAxRMDXX792csPAAAADQAAABEAAABmaXh0dXJlL3J1bGVzLnR4dAsK9XG1LS5JTE/VTeQCAFBLAwQUAAAACADFEwNdTyi4yRAAAAAOAAAAFAAAAGZpeHR1cmUvc291cmNlLnN3aWZ0y0ktUShLzClNVbBVMOQCAFBLAQIUABQAAAAAAMUTA10AAAAAAAAAAAAAAAAIAAAAAAAAAAAAEAAAAAAAAABmaXh0dXJlL1BLAQIUABQAAAAIAMUTA11+/dnLDwAAAA0AAAARAAAAAAAAAAAAgAAAACYAAABmaXh0dXJlL3J1bGVzLnR4dFBLAQIUABQAAAAIAMUTA11PKLjJEAAAAA4AAAAUAAAAAAAAAAAAgAAAAGQAAABmaXh0dXJlL3NvdXJjZS5zd2lmdFBLBQYAAAAAAwADALcAAACmAAAAAAA="
    private let traversalFixtureBase64 = "UEsDBBQAAAAIAJ0UA12OsOglCAAAAAYAAAANAAAALi4vZXNjYXBlLnR4dEstTk4sSAUAUEsBAhQAFAAAAAgAnRQDXY6w6CUIAAAABgAAAA0AAAAAAAAAAACAAAAAAAAAAC4uL2VzY2FwZS50eHRQSwUGAAAAAAEAAQA7AAAAMwAAAAAA"

    func testProductionDefaultsRemainExact() {
        let policy = StageAImportPolicy.production
        XCTAssertEqual(policy.maximumEntryCount, 50_000)
        XCTAssertEqual(policy.maximumFileBytes, 256 * 1_024 * 1_024)
        XCTAssertEqual(policy.maximumTotalBytes, 2 * 1_024 * 1_024 * 1_024)
        XCTAssertEqual(policy.maximumCompressionRatio, 100)
        XCTAssertEqual(policy.maximumPathBytes, 1_024)
        XCTAssertEqual(policy.maximumDirectoryDepth, 64)
        XCTAssertEqual(policy.minimumRemainingCapacityBytes, 512 * 1_024 * 1_024)
        XCTAssertEqual(policy.maximumDiagnosticBytes, 256 * 1_024)
    }

    func testNamedFolderAndZIPFixturesPublishDistinctAppOwnedWorkspaces() async throws {
        let root = try temporaryDirectory(named: "StageAImportStore")
        let sourceRoot = try temporaryDirectory(named: "StageASources")
        let folder = sourceRoot.appendingPathComponent("StageAFolderFixture", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("RULE=folder\n".utf8).write(to: folder.appendingPathComponent("rules.txt"))
        let nested = folder.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        try Data("let folderValue = 1\n".utf8).write(to: nested.appendingPathComponent("main.swift"))

        let zipURL = sourceRoot.appendingPathComponent("StageAZipFixture.zip")
        try fixtureData().write(to: zipURL, options: [.withoutOverwriting])

        let policy = testPolicy()
        let store = StageAWorkspaceStore(rootURL: root, policy: policy)
        let importer = StageAWorkspaceImporter(
            store: store,
            policy: policy,
            coordinator: DirectStageACoordinator()
        )
        let folderRecord = await importer.importItem(at: folder, expectedKind: .folder)
        let zipRecord = await importer.importItem(at: zipURL, expectedKind: .zip)

        XCTAssertEqual(folderRecord.phase, .ready)
        XCTAssertEqual(zipRecord.phase, .ready)
        XCTAssertNotEqual(folderRecord.workspaceID, zipRecord.workspaceID)
        XCTAssertEqual(folderRecord.sourceDisplayName, "StageAFolderFixture")
        XCTAssertEqual(zipRecord.sourceDisplayName, "StageAZipFixture.zip")
        XCTAssertNotEqual(folderRecord.sourcePathSHA256, zipRecord.sourcePathSHA256)

        let folderWorkspace = store.workspaceURL(for: folderRecord.workspaceID)
        let zipWorkspace = store.workspaceURL(for: zipRecord.workspaceID)
        XCTAssertTrue(folderWorkspace.path.hasPrefix(store.workspacesRootURL.path))
        XCTAssertTrue(zipWorkspace.path.hasPrefix(store.workspacesRootURL.path))
        XCTAssertFalse(folderWorkspace.path.hasPrefix(folder.path))
        XCTAssertFalse(zipWorkspace.path.hasPrefix(zipURL.deletingLastPathComponent().path + "/"))
        XCTAssertEqual(
            try String(contentsOf: folderWorkspace.appendingPathComponent("rules.txt")),
            "RULE=folder\n"
        )
        XCTAssertEqual(
            try String(contentsOf: zipWorkspace.appendingPathComponent("fixture/rules.txt")),
            "RULE=stage-a\n"
        )
        let recordBytes = try FileManager.default.contentsOfDirectory(
            at: store.recordsURL,
            includingPropertiesForKeys: nil
        ).reduce(into: Data()) { data, url in data.append(try Data(contentsOf: url)) }
        let recordText = String(decoding: recordBytes, as: UTF8.self)
        XCTAssertFalse(recordText.contains("RULE=folder"))
        XCTAssertFalse(recordText.contains("RULE=stage-a"))
    }

    func testPathTraversalAbsoluteCollisionParentAndLimitsRejectBeforeReady() throws {
        let policy = testPolicy(
            maximumEntryCount: 2,
            maximumFileBytes: 8,
            maximumTotalBytes: 12,
            maximumCompressionRatio: 2,
            maximumPathBytes: 24,
            maximumDirectoryDepth: 1
        )
        XCTAssertThrowsError(try planned("../escape", policy: policy)) {
            XCTAssertEqual($0 as? StageAImportError, .pathTraversal)
        }
        XCTAssertThrowsError(try planned("/absolute", policy: policy)) {
            XCTAssertEqual($0 as? StageAImportError, .pathAbsolute)
        }
        XCTAssertThrowsError(try planned("a/b/c.txt", policy: policy)) {
            XCTAssertEqual($0 as? StageAImportError, .pathTooDeep)
        }
        XCTAssertThrowsError(try planned(String(repeating: "x", count: 25), policy: policy)) {
            XCTAssertEqual($0 as? StageAImportError, .pathTooLong)
        }
        XCTAssertThrowsError(try planned("large", output: 9, policy: policy)) {
            XCTAssertEqual($0 as? StageAImportError, .fileLimitExceeded)
        }

        let caseCollision = [
            try planned("Readme", policy: policy),
            try planned("README", policy: policy)
        ]
        XCTAssertThrowsError(try StageAPathPolicy.finalize(
            caseCollision, policy: policy, appliesCompressionRatio: false
        )) { XCTAssertEqual($0 as? StageAImportError, .pathCollision) }

        let unicodeCollision = [
            try planned("caf\u{00e9}.txt", policy: policy),
            try planned("cafe\u{0301}.txt", policy: policy)
        ]
        XCTAssertThrowsError(try StageAPathPolicy.finalize(
            unicodeCollision, policy: policy, appliesCompressionRatio: false
        )) { XCTAssertEqual($0 as? StageAImportError, .pathCollision) }

        let parentCollision = [
            try planned("Sources", policy: policy),
            try planned("Sources/main", policy: policy)
        ]
        XCTAssertThrowsError(try StageAPathPolicy.finalize(
            parentCollision, policy: policy, appliesCompressionRatio: false
        )) { XCTAssertEqual($0 as? StageAImportError, .parentFileCollision) }

        let ratio = [try planned("ratio", compressed: 3, output: 7, policy: policy)]
        XCTAssertThrowsError(try StageAPathPolicy.finalize(
            ratio, policy: policy, appliesCompressionRatio: true
        )) { XCTAssertEqual($0 as? StageAImportError, .compressionRatioExceeded) }

        let total = [
            try planned("one", output: 7, policy: policy),
            try planned("two", output: 7, policy: policy)
        ]
        XCTAssertThrowsError(try StageAPathPolicy.finalize(
            total, policy: policy, appliesCompressionRatio: false
        )) { XCTAssertEqual($0 as? StageAImportError, .totalLimitExceeded) }

        let count = [
            try planned("one", policy: policy),
            try planned("two", policy: policy),
            try planned("three", policy: policy)
        ]
        XCTAssertThrowsError(try StageAPathPolicy.finalize(
            count, policy: policy, appliesCompressionRatio: false
        )) { XCTAssertEqual($0 as? StageAImportError, .entryLimitExceeded) }
    }

    func testZIPEntryPolicyRejectsEncryptionCompressionLinksSpecialAndAmbiguity() throws {
        let policy = testPolicy()
        let valid = StageAZipEntryDescriptor(
            sourcePath: "file.txt",
            compressedBytes: 4,
            outputBytes: 8,
            generalPurposeFlags: 0,
            compressionMethod: 8,
            isDirectory: false,
            hasDirectoryMarker: false,
            isSymlink: false,
            hasLinkName: false,
            isSpecialFile: false,
            isSupportedHostSystem: true
        )
        XCTAssertNoThrow(try StageAZipEntryPolicy.plan(descriptor: valid, policy: policy))

        XCTAssertRejected(valid, policy: policy, expected: .encryptedArchive) {
            replacing(valid, flags: 1)
        }
        XCTAssertRejected(valid, policy: policy, expected: .encryptedArchive) {
            replacing(valid, flags: 0x0040)
        }
        XCTAssertRejected(valid, policy: policy, expected: .encryptedArchive) {
            replacing(valid, flags: 0x2000)
        }
        XCTAssertRejected(valid, policy: policy, expected: .unsupportedInput) {
            replacing(valid, flags: 0x0020)
        }
        XCTAssertRejected(valid, policy: policy, expected: .unsupportedCompression) {
            replacing(valid, compression: 12)
        }
        XCTAssertRejected(valid, policy: policy, expected: .linkRejected) {
            replacing(valid, symlink: true)
        }
        XCTAssertRejected(valid, policy: policy, expected: .linkRejected) {
            replacing(valid, linkName: true)
        }
        XCTAssertRejected(valid, policy: policy, expected: .unsupportedType) {
            replacing(valid, special: true)
        }
        XCTAssertRejected(valid, policy: policy, expected: .ambiguousInput) {
            replacing(valid, directory: true, directoryMarker: false)
        }
        XCTAssertRejected(valid, policy: policy, expected: .ambiguousInput) {
            StageAZipEntryDescriptor(
                sourcePath: "caf\u{00e9}.txt",
                compressedBytes: valid.compressedBytes,
                outputBytes: valid.outputBytes,
                generalPurposeFlags: 0,
                compressionMethod: valid.compressionMethod,
                isDirectory: false,
                hasDirectoryMarker: false,
                isSymlink: false,
                hasLinkName: false,
                isSpecialFile: false,
                isSupportedHostSystem: true
            )
        }
    }

    func testExistingDestinationIsNeverOverwritten() throws {
        let root = try temporaryDirectory(named: "StageAOverwrite")
        let zipURL = root.appendingPathComponent("StageAZipFixture.zip")
        try fixtureData().write(to: zipURL)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(
            at: staging.appendingPathComponent("fixture", isDirectory: true),
            withIntermediateDirectories: true
        )
        let existing = staging.appendingPathComponent("fixture/rules.txt")
        try Data("preserve".utf8).write(to: existing)
        let archive = try StageAZipArchive(url: zipURL)
        let plan = try archive.preflight(policy: testPolicy())
        XCTAssertThrowsError(try archive.extract(plan: plan, to: staging, policy: testPolicy())) {
            XCTAssertEqual($0 as? StageAImportError, .unsafeOverwrite)
        }
        XCTAssertEqual(try String(contentsOf: existing), "preserve")
    }

    func testTraversalZIPFailsBeforeWorkspaceBecomesReady() async throws {
        let root = try temporaryDirectory(named: "StageATraversalStore")
        let sourceRoot = try temporaryDirectory(named: "StageATraversalSources")
        let zipURL = sourceRoot.appendingPathComponent("StageATraversalFixture.zip")
        let data = try XCTUnwrap(Data(base64Encoded: traversalFixtureBase64))
        try data.write(to: zipURL, options: [.withoutOverwriting])
        let policy = testPolicy()
        let store = StageAWorkspaceStore(rootURL: root, policy: policy)
        let importer = StageAWorkspaceImporter(
            store: store,
            policy: policy,
            coordinator: DirectStageACoordinator()
        )

        let result = await importer.importItem(at: zipURL, expectedKind: .zip)
        XCTAssertEqual(result.phase, .failed)
        XCTAssertEqual(result.errorCode, .pathTraversal)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: store.workspaceURL(for: result.workspaceID).path
        ))
        let readyRecords = try await importerReadyRecords(importer)
        XCTAssertTrue(readyRecords.isEmpty)
    }

    func testCancellationLeavesNoReadyWorkspace() async throws {
        let root = try temporaryDirectory(named: "StageACancelStore")
        let source = try temporaryDirectory(named: "StageACancelFixture")
        try Data("cancel".utf8).write(to: source.appendingPathComponent("file.txt"))
        let policy = testPolicy()
        let store = StageAWorkspaceStore(rootURL: root, policy: policy)
        let importer = StageAWorkspaceImporter(
            store: store,
            policy: policy,
            coordinator: DirectStageACoordinator(),
            checkpoint: { point in
                if case .stagingCreated = point { throw CancellationError() }
            }
        )
        let result = await importer.importItem(at: source, expectedKind: .folder)
        XCTAssertEqual(result.phase, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.workspaceURL(for: result.workspaceID).path))
        let readyRecords = try await importerReadyRecords(importer)
        XCTAssertTrue(readyRecords.isEmpty)
    }

    func testAmbiguousFileAndFolderLinkRejectBeforeReady() async throws {
        let root = try temporaryDirectory(named: "StageARejectStore")
        let sourceRoot = try temporaryDirectory(named: "StageARejectSources")
        let regularFile = sourceRoot.appendingPathComponent("not-a-folder.txt")
        try Data("ordinary".utf8).write(to: regularFile)
        let linkedFolder = sourceRoot.appendingPathComponent("linked-folder", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: linkedFolder,
            withDestinationURL: sourceRoot
        )
        let policy = testPolicy()
        let store = StageAWorkspaceStore(rootURL: root, policy: policy)
        let importer = StageAWorkspaceImporter(
            store: store,
            policy: policy,
            coordinator: DirectStageACoordinator()
        )

        let ambiguous = await importer.importItem(at: regularFile, expectedKind: .folder)
        let linked = await importer.importItem(at: linkedFolder, expectedKind: .folder)
        XCTAssertEqual(ambiguous.phase, .failed)
        XCTAssertEqual(ambiguous.errorCode, .ambiguousInput)
        XCTAssertEqual(linked.phase, .failed)
        XCTAssertEqual(linked.errorCode, .linkRejected)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: store.workspaceURL(for: ambiguous.workspaceID).path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: store.workspaceURL(for: linked.workspaceID).path
        ))
        let readyRecords = try await importerReadyRecords(importer)
        XCTAssertTrue(readyRecords.isEmpty)
    }

    func testContainedURLRejectsBoundaryEscape() throws {
        let root = try temporaryDirectory(named: "StageABoundary")
        XCTAssertThrowsError(try StageAPathPolicy.containedURL(
            root: root,
            relativePath: "../escape",
            isDirectory: false
        )) { XCTAssertEqual($0 as? StageAImportError, .boundaryEscape) }
    }

    func testPublishedUnknownReconcilesFromDurableMarkerWithoutRepeatingImport() async throws {
        let root = try temporaryDirectory(named: "StageARecoveryStore")
        let source = try temporaryDirectory(named: "StageARecoveryFixture")
        try Data("recover".utf8).write(to: source.appendingPathComponent("file.txt"))
        let policy = testPolicy()
        let store = StageAWorkspaceStore(rootURL: root, policy: policy)
        let importer = StageAWorkspaceImporter(
            store: store,
            policy: policy,
            coordinator: DirectStageACoordinator(),
            checkpoint: { point in
                if case .workspacePublished = point {
                    throw StageAImportError.externalResultUnknown
                }
            }
        )
        let result = await importer.importItem(at: source, expectedKind: .folder)
        XCTAssertEqual(result.phase, .reconciliationRequired)
        let workspace = store.workspaceURL(for: result.workspaceID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.path))
        let before = try Data(contentsOf: workspace.appendingPathComponent("file.txt"))

        let recovered = try await importer.recover()
        let ready = try XCTUnwrap(recovered.first { $0.id == result.id })
        XCTAssertEqual(ready.phase, .ready)
        XCTAssertEqual(try Data(contentsOf: workspace.appendingPathComponent("file.txt")), before)
        let repeated = try await importer.recover()
        XCTAssertEqual(repeated.first { $0.id == result.id }?.phase, .ready)
    }

    private func importerReadyRecords(_ importer: StageAWorkspaceImporter) async throws -> [StageAImportRecord] {
        try await importer.recover().filter(\.isReady)
    }

    private func fixtureData() throws -> Data {
        try XCTUnwrap(Data(base64Encoded: fixtureBase64))
    }

    private func temporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(name + "-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func testPolicy(
        maximumEntryCount: Int = 100,
        maximumFileBytes: UInt64 = 1_024 * 1_024,
        maximumTotalBytes: UInt64 = 4 * 1_024 * 1_024,
        maximumCompressionRatio: UInt64 = 100,
        maximumPathBytes: Int = 256,
        maximumDirectoryDepth: Int = 16
    ) -> StageAImportPolicy {
        StageAImportPolicy(
            maximumEntryCount: maximumEntryCount,
            maximumFileBytes: maximumFileBytes,
            maximumTotalBytes: maximumTotalBytes,
            maximumCompressionRatio: maximumCompressionRatio,
            maximumPathBytes: maximumPathBytes,
            maximumDirectoryDepth: maximumDirectoryDepth,
            minimumRemainingCapacityBytes: 0,
            maximumDiagnosticBytes: 4 * 1_024
        )
    }

    private func planned(
        _ path: String,
        compressed: UInt64 = 1,
        output: UInt64 = 1,
        policy: StageAImportPolicy
    ) throws -> StageAPlannedEntry {
        try StageAPathPolicy.plan(
            sourcePath: path,
            kind: .file,
            compressedBytes: compressed,
            outputBytes: output,
            policy: policy
        )
    }

    private func XCTAssertRejected(
        _ valid: StageAZipEntryDescriptor,
        policy: StageAImportPolicy,
        expected: StageAImportError,
        file: StaticString = #filePath,
        line: UInt = #line,
        mutation: () -> StageAZipEntryDescriptor
    ) {
        XCTAssertThrowsError(
            try StageAZipEntryPolicy.plan(descriptor: mutation(), policy: policy),
            file: file,
            line: line
        ) { XCTAssertEqual($0 as? StageAImportError, expected, file: file, line: line) }
    }

    private func replacing(
        _ value: StageAZipEntryDescriptor,
        flags: UInt16? = nil,
        compression: UInt16? = nil,
        directory: Bool? = nil,
        directoryMarker: Bool? = nil,
        symlink: Bool? = nil,
        linkName: Bool? = nil,
        special: Bool? = nil
    ) -> StageAZipEntryDescriptor {
        StageAZipEntryDescriptor(
            sourcePath: value.sourcePath,
            compressedBytes: value.compressedBytes,
            outputBytes: value.outputBytes,
            generalPurposeFlags: flags ?? value.generalPurposeFlags,
            compressionMethod: compression ?? value.compressionMethod,
            isDirectory: directory ?? value.isDirectory,
            hasDirectoryMarker: directoryMarker ?? value.hasDirectoryMarker,
            isSymlink: symlink ?? value.isSymlink,
            hasLinkName: linkName ?? value.hasLinkName,
            isSpecialFile: special ?? value.isSpecialFile,
            isSupportedHostSystem: value.isSupportedHostSystem
        )
    }
}

private struct DirectStageACoordinator: StageAExternalFileCoordinating {
    func coordinateRead<T>(at url: URL, _ body: (URL) throws -> T) throws -> T {
        try body(url)
    }
}
