import SwiftUI

@MainActor
final class StageCApprovalViewModel: ObservableObject {
    @Published private(set) var task: StageCTaskRecord?
    @Published private(set) var projection = StageCApprovalProjection(state: .idle, request: nil)
    @Published private(set) var isRunning = false
    @Published var notice: String?

    private let importRecord: StageAImportRecord
    private let sessionID: UUID
    private var approvalTask: Task<Void, Never>?

    init(importRecord: StageAImportRecord, sessionID: UUID) {
        self.importRecord = importRecord
        self.sessionID = sessionID
    }

    deinit { approvalTask?.cancel() }

    func load() async {
        do {
            let store = try StageCTaskStore.applicationStore()
            let records = try await store.records()
            task = records.last {
                $0.sessionID == sessionID && $0.importID == importRecord.id
            }
            approvalTask?.cancel()
            approvalTask = Task { [weak self] in
                let stream = await StageCApprovalBroker.shared.projections()
                for await projection in stream {
                    guard !Task.isCancelled else { break }
                    self?.projection = projection
                    if let taskID = projection.request?.taskID {
                        self?.task = try? await store.snapshot(taskID: taskID)
                    }
                }
            }
        } catch {
            notice = "Stage C state is unavailable"
        }
    }

    func run() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        do {
            let stageAStore = try StageAWorkspaceStore.applicationStore()
            let sessionStore = try StageBSessionStore.applicationStore()
            let prepared = try await StageBSessionCoordinator(
                stageAStore: stageAStore,
                sessionStore: sessionStore
            ).restore(sessionID: sessionID)
            guard prepared.session.phase == .completed,
                  let target = prepared.session.completion?.relativePath else {
                throw StageCError.invalidBinding
            }
            let taskStore = try StageCTaskStore.applicationStore()
            let record: StageCTaskRecord
            let records = try await taskStore.records()
            if let existing = records.last(where: { $0.sessionID == sessionID }) {
                record = existing
            } else {
                record = try await taskStore.create(
                    session: prepared.session,
                    workspace: prepared.workspace,
                    ruleSet: prepared.ruleSet,
                    targetRelativePath: target
                )
            }
            task = record
            let configuration = DeepSeekSecureConfigurationStore()
            let providerDirectory = taskStore.rootURL
                .appendingPathComponent("Provider", isDirectory: true)
                .appendingPathComponent(record.id.uuidString.lowercased(), isDirectory: true)
            let provider = try configuration.makeProvider(
                transport: URLSessionProviderTransport(),
                attemptStore: FileProviderAttemptStore(directoryURL: providerDirectory)
            )
            let agent = StageCEditingAgent(
                provider: provider,
                readExecutor: try ISHStageBReadOnlyExecutor.bundled(workspace: prepared.workspace),
                editExecutor: try ISHStageCEditExecutor.bundled(workspace: prepared.workspace),
                approvalAuthorizer: StageCApprovalBroker.shared,
                taskStore: taskStore,
                task: record,
                session: prepared.session,
                workspace: prepared.workspace,
                ruleSet: prepared.ruleSet
            )
            let outcome = await agent.run()
            task = try await taskStore.snapshot(taskID: record.id)
            switch outcome {
            case .completed: notice = "Bounded edit completed"
            case .pendingApproval: notice = "Approval requires explicit confirmation"
            case .rejected: notice = "Edit rejected"
            case .reconciliationRequired: notice = "Edit requires reconciliation"
            case .failed: notice = "Stage C stopped"
            }
        } catch {
            notice = "Stage C could not start"
        }
    }

    func approve() {
        guard let request = projection.request else { return }
        Task { await StageCApprovalBroker.shared.approve(requestID: request.requestID, nonce: request.nonce) }
    }

    func reject() {
        guard let request = projection.request else { return }
        Task { await StageCApprovalBroker.shared.reject(requestID: request.requestID, nonce: request.nonce) }
    }
}

struct StageCApprovalView: View {
    @StateObject private var viewModel: StageCApprovalViewModel

    init(importRecord: StageAImportRecord, sessionID: UUID) {
        _viewModel = StateObject(wrappedValue: StageCApprovalViewModel(
            importRecord: importRecord,
            sessionID: sessionID
        ))
    }

    var body: some View {
        Form {
            Section("Bounded Edit") {
                if let proposal = viewModel.task?.proposal {
                    LabeledContent("Target", value: proposal.relativePath)
                    LabeledContent("Risk", value: "Modify existing text")
                    Text(proposal.diff)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    if viewModel.projection.request == nil,
                       viewModel.task?.phase == .pendingApproval {
                        Button { Task { await viewModel.run() } } label: {
                            Label("Resume approval", systemImage: "checkmark.shield")
                        }
                        .disabled(viewModel.isRunning)
                    }
                } else {
                    Button { Task { await viewModel.run() } } label: {
                        Label("Prepare edit proposal", systemImage: "square.and.pencil")
                    }
                    .disabled(viewModel.isRunning)
                }
            }
            if let request = viewModel.projection.request {
                Section("Approval") {
                    LabeledContent("State", value: viewModel.projection.state.rawValue)
                    LabeledContent("Expires", value: request.expiresAt.formatted())
                    HStack {
                        Button("Approve") { viewModel.approve() }.buttonStyle(.borderedProminent)
                        Button("Reject", role: .destructive) { viewModel.reject() }.buttonStyle(.bordered)
                    }
                }
            }
            if let task = viewModel.task {
                Section("Durable State") {
                    LabeledContent("State", value: task.phase.rawValue)
                    LabeledContent("Workspace", value: String(task.workspaceIdentitySHA256.prefix(12)))
                }
            }
        }
        .navigationTitle("Stage C Approval")
        .task { await viewModel.load() }
        .overlay { if viewModel.isRunning { ProgressView() } }
        .alert("Wuji", isPresented: Binding(
            get: { viewModel.notice != nil },
            set: { if !$0 { viewModel.notice = nil } }
        )) {
            Button("OK") { viewModel.notice = nil }
        } message: {
            Text(viewModel.notice ?? "")
        }
    }
}
