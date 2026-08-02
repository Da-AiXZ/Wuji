import Foundation

enum StageAImportPhase: String, Codable, Equatable, Sendable {
    case intentRecorded = "intent_recorded"
    case staging
    case prepared
    case publishing
    case ready
    case failed
    case cancelled
    case reconciliationRequired = "reconciliation_required"
}

struct StageAImportDiagnostic: Codable, Equatable, Sendable {
    let sequence: Int
    let code: String
}

struct StageAImportRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let workspaceID: UUID
    let sourceKind: StageAImportSourceKind
    let sourceDisplayName: String
    let sourcePathSHA256: String
    let targetRelativePath: String
    let createdAt: Date
    var updatedAt: Date
    var phase: StageAImportPhase
    var entryCount: Int?
    var totalOutputBytes: UInt64?
    var errorCode: StageAImportError?
    var diagnostics: [StageAImportDiagnostic]

    var isReady: Bool { phase == .ready }
}

struct StageAWorkspaceMarker: Codable, Equatable, Sendable {
    static let fileName = ".wuji-stage-a-workspace.json"

    let importID: UUID
    let workspaceID: UUID
    let entryCount: Int
    let totalOutputBytes: UInt64
}

final class StageAWorkspaceStore: @unchecked Sendable {
    let rootURL: URL
    let recordsURL: URL
    let stagingRootURL: URL
    let workspacesRootURL: URL

    private let fileManager: FileManager
    private let policy: StageAImportPolicy
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        rootURL: URL,
        policy: StageAImportPolicy = .production,
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL
        self.policy = policy
        self.fileManager = fileManager
        recordsURL = rootURL.appendingPathComponent("ImportRecords", isDirectory: true)
        stagingRootURL = rootURL.appendingPathComponent("ImportStaging", isDirectory: true)
        workspacesRootURL = rootURL.appendingPathComponent("Workspaces", isDirectory: true)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    static func applicationStore(policy: StageAImportPolicy = .production) throws -> StageAWorkspaceStore {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return StageAWorkspaceStore(
            rootURL: applicationSupport.appendingPathComponent("WujiStageA", isDirectory: true),
            policy: policy
        )
    }

    func begin(
        importID: UUID,
        workspaceID: UUID,
        sourceKind: StageAImportSourceKind,
        sourceDisplayName: String,
        sourcePathSHA256: String,
        now: Date
    ) throws -> StageAImportRecord {
        try prepareRoots()
        let recordURL = recordURL(for: importID)
        guard !fileManager.fileExists(atPath: recordURL.path) else {
            throw StageAImportError.unsafeOverwrite
        }
        let target = "Workspaces/" + workspaceID.uuidString.lowercased()
        let record = StageAImportRecord(
            id: importID,
            workspaceID: workspaceID,
            sourceKind: sourceKind,
            sourceDisplayName: boundedDisplayName(sourceDisplayName),
            sourcePathSHA256: sourcePathSHA256,
            targetRelativePath: target,
            createdAt: now,
            updatedAt: now,
            phase: .intentRecorded,
            entryCount: nil,
            totalOutputBytes: nil,
            errorCode: nil,
            diagnostics: [StageAImportDiagnostic(sequence: 0, code: "intent_recorded")]
        )
        try persist(record)
        return record
    }

    func transition(
        _ record: StageAImportRecord,
        to phase: StageAImportPhase,
        plan: StageAImportPlan? = nil,
        error: StageAImportError? = nil,
        diagnosticCode: String,
        now: Date
    ) throws -> StageAImportRecord {
        var updated = record
        updated.phase = phase
        updated.updatedAt = now
        updated.entryCount = plan?.entries.count ?? updated.entryCount
        updated.totalOutputBytes = plan?.totalOutputBytes ?? updated.totalOutputBytes
        updated.errorCode = error
        updated.diagnostics = appendDiagnostic(
            diagnosticCode,
            to: updated.diagnostics
        )
        try persist(updated)
        return updated
    }

    func records() throws -> [StageAImportRecord] {
        try prepareRoots()
        return try fileManager.contentsOfDirectory(
            at: recordsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }
        .map { try decoder.decode(StageAImportRecord.self, from: Data(contentsOf: $0)) }
        .sorted { $0.createdAt < $1.createdAt }
    }

    func recover(now: Date = Date()) throws -> [StageAImportRecord] {
        var recovered: [StageAImportRecord] = []
        for record in try records() {
            let workspaceURL = workspaceURL(for: record.workspaceID)
            let marker = try validMarker(at: workspaceURL, for: record)
            switch record.phase {
            case .ready:
                if marker != nil {
                    recovered.append(record)
                } else {
                    recovered.append(try transition(
                        record,
                        to: .reconciliationRequired,
                        error: .externalResultUnknown,
                        diagnosticCode: "ready_workspace_missing",
                        now: now
                    ))
                }
            case .intentRecorded, .staging, .prepared, .publishing:
                if let marker {
                    var reconciled = record
                    reconciled.phase = .ready
                    reconciled.updatedAt = now
                    reconciled.entryCount = marker.entryCount
                    reconciled.totalOutputBytes = marker.totalOutputBytes
                    reconciled.errorCode = nil
                    reconciled.diagnostics = appendDiagnostic(
                        "published_marker_reconciled",
                        to: reconciled.diagnostics
                    )
                    try persist(reconciled)
                    recovered.append(reconciled)
                } else {
                    recovered.append(try transition(
                        record,
                        to: .reconciliationRequired,
                        error: .externalResultUnknown,
                        diagnosticCode: "incomplete_import_preserved",
                        now: now
                    ))
                }
            case .reconciliationRequired:
                if let marker {
                    var reconciled = record
                    reconciled.phase = .ready
                    reconciled.updatedAt = now
                    reconciled.entryCount = marker.entryCount
                    reconciled.totalOutputBytes = marker.totalOutputBytes
                    reconciled.errorCode = nil
                    reconciled.diagnostics = appendDiagnostic(
                        "published_marker_reconciled",
                        to: reconciled.diagnostics
                    )
                    try persist(reconciled)
                    recovered.append(reconciled)
                } else {
                    recovered.append(record)
                }
            case .failed, .cancelled:
                recovered.append(record)
            }
        }
        return recovered
    }

    func stagingURL(for importID: UUID) -> URL {
        stagingRootURL.appendingPathComponent(importID.uuidString.lowercased(), isDirectory: true)
    }

    func workspaceURL(for workspaceID: UUID) -> URL {
        workspacesRootURL.appendingPathComponent(workspaceID.uuidString.lowercased(), isDirectory: true)
    }

    func writeMarker(_ marker: StageAWorkspaceMarker, to stagingURL: URL) throws {
        let markerURL = stagingURL.appendingPathComponent(StageAWorkspaceMarker.fileName)
        guard !fileManager.fileExists(atPath: markerURL.path) else {
            throw StageAImportError.unsafeOverwrite
        }
        try encoder.encode(marker).write(to: markerURL, options: [.withoutOverwriting])
    }

    private func validMarker(
        at workspaceURL: URL,
        for record: StageAImportRecord
    ) throws -> StageAWorkspaceMarker? {
        let values = try? workspaceURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values?.isDirectory == true, values?.isSymbolicLink != true else { return nil }
        let markerURL = workspaceURL.appendingPathComponent(StageAWorkspaceMarker.fileName)
        guard fileManager.fileExists(atPath: markerURL.path) else { return nil }
        let marker = try decoder.decode(StageAWorkspaceMarker.self, from: Data(contentsOf: markerURL))
        guard marker.importID == record.id,
              marker.workspaceID == record.workspaceID,
              marker.entryCount == record.entryCount,
              marker.totalOutputBytes == record.totalOutputBytes else { return nil }
        return marker
    }

    private func prepareRoots() throws {
        try fileManager.createDirectory(at: recordsURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stagingRootURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: workspacesRootURL, withIntermediateDirectories: true)
    }

    private func recordURL(for importID: UUID) -> URL {
        recordsURL.appendingPathComponent(importID.uuidString.lowercased()).appendingPathExtension("json")
    }

    private func persist(_ record: StageAImportRecord) throws {
        let data = try encoder.encode(record)
        try data.write(to: recordURL(for: record.id), options: [.atomic])
    }

    private func appendDiagnostic(
        _ code: String,
        to existing: [StageAImportDiagnostic]
    ) -> [StageAImportDiagnostic] {
        let sanitized = code.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .prefix(96)
        let event = StageAImportDiagnostic(
            sequence: existing.count,
            code: String(String.UnicodeScalarView(sanitized))
        )
        let candidate = existing + [event]
        guard let encoded = try? encoder.encode(candidate),
              encoded.count <= policy.maximumDiagnosticBytes else {
            return existing
        }
        return candidate
    }

    private func boundedDisplayName(_ value: String) -> String {
        let clean = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        return String(String.UnicodeScalarView(clean)).prefix(160).description
    }
}
