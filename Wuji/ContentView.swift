import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var viewModel: StageAViewModel
    private let taskState = WujiTaskState.empty

    @MainActor
    init(viewModel: StageAViewModel = StageAViewModel()) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("工作区") {
                    if viewModel.records.isEmpty {
                        Label(taskState.statusText, systemImage: "tray")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(viewModel.records) { record in
                            WorkspaceImportRow(record: record)
                        }
                    }
                    if viewModel.isImporting {
                        HStack {
                            ProgressView()
                            Text("正在导入")
                        }
                    }
                }

                Section("模型") {
                    LabeledContent("DeepSeek") {
                        Text(viewModel.isConfigured ? "已配置" : "未配置")
                            .foregroundColor(viewModel.isConfigured ? .primary : .secondary)
                    }
                }

                Section {
                    DisclosureGroup("验证控件") {
                        ExecutorSelfTestView()
                        Divider()
                        S4ApprovalView()
                    }
                }
            }
            .navigationTitle("无极")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        viewModel.isImporterPresented = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                    .disabled(viewModel.isImporting)
                    .accessibilityLabel("导入工作区")

                    Button {
                        viewModel.isSettingsPresented = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("DeepSeek 设置")
                }
            }
            .fileImporter(
                isPresented: $viewModel.isImporterPresented,
                allowedContentTypes: [.folder, .zip],
                allowsMultipleSelection: false,
                onCompletion: viewModel.importSelection
            )
            .sheet(isPresented: $viewModel.isSettingsPresented) {
                DeepSeekSettingsView(viewModel: viewModel)
            }
            .task { await viewModel.load() }
            .alert("无极", isPresented: Binding(
                get: { viewModel.notice != nil },
                set: { if !$0 { viewModel.notice = nil } }
            )) {
                Button("好") { viewModel.notice = nil }
            } message: {
                Text(viewModel.notice ?? "")
            }
        }
    }
}

private struct WorkspaceImportRow: View {
    let record: StageAImportRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: record.sourceKind == .zip ? "doc.zipper" : "folder")
                    .foregroundColor(.secondary)
                Text("来源: \(record.sourceDisplayName)")
                    .lineLimit(1)
                Spacer()
                Text(statusText)
                    .font(.caption)
                    .foregroundColor(statusColor)
            }
            Text("目标: \(record.targetRelativePath)")
                .font(.caption.monospaced())
                .foregroundColor(.secondary)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        switch record.phase {
        case .ready: return "就绪"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        case .reconciliationRequired: return "待调和"
        case .intentRecorded, .staging, .prepared, .publishing: return "处理中"
        }
    }

    private var statusColor: Color {
        switch record.phase {
        case .ready: return .green
        case .failed: return .red
        case .reconciliationRequired: return .orange
        default: return .secondary
        }
    }
}
