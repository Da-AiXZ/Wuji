import SwiftUI

@MainActor
final class StageAViewModel: ObservableObject {
    @Published private(set) var records: [StageAImportRecord] = []
    @Published private(set) var isImporting = false
    @Published private(set) var isConfigured = false
    @Published var isImporterPresented = false
    @Published var isSettingsPresented = false
    @Published var notice: String?

    private var importer: StageAWorkspaceImporter?
    private let configurationStore: DeepSeekSecureConfigurationStore

    init(configurationStore: DeepSeekSecureConfigurationStore = DeepSeekSecureConfigurationStore()) {
        self.configurationStore = configurationStore
    }

    func load() async {
        do {
            let importer = try applicationImporter()
            records = try await importer.recover()
            isConfigured = (try? configurationStore.load()) != nil
        } catch {
            notice = "无法读取本地工作区状态"
        }
    }

    func importSelection(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result, urls.count == 1, let url = urls.first else {
            if case .success = result {
                notice = "请选择一个文件夹或 ZIP"
            }
            return
        }
        Task { await importURL(url) }
    }

    func saveConfiguration(baseURL: String, model: String, apiKey: String) -> Bool {
        do {
            try configurationStore.save(baseURL: baseURL, model: model, apiKey: apiKey)
            isConfigured = true
            notice = "DeepSeek 配置已安全保存"
            return true
        } catch {
            isConfigured = false
            notice = "DeepSeek 配置未保存"
            return false
        }
    }

    func existingConfiguration() -> DeepSeekConfiguration? {
        try? configurationStore.load()
    }

    private func importURL(_ url: URL) async {
        guard !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        do {
            let importer = try applicationImporter()
            let kind: StageAImportSourceKind =
                url.pathExtension.caseInsensitiveCompare("zip") == .orderedSame ? .zip : .folder
            let result = await importer.importItem(at: url, expectedKind: kind)
            records = try await importer.recover()
            if result.phase == .ready {
                notice = "工作区导入完成"
            } else if result.phase == .reconciliationRequired {
                notice = "导入结果需要调和"
            } else {
                notice = "导入未完成"
            }
        } catch {
            notice = "导入状态无法持久化"
        }
    }

    private func applicationImporter() throws -> StageAWorkspaceImporter {
        if let importer { return importer }
        let store = try StageAWorkspaceStore.applicationStore()
        let created = StageAWorkspaceImporter(store: store)
        importer = created
        return created
    }
}
