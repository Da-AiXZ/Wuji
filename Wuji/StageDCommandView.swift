import SwiftUI

struct StageDCommandProjection: Equatable, Sendable {
    let phase: String
    let command: String?
    let risk: String?
    let binding: String?
    let approval: String?
    let rootExit: Bool?
    let stdoutEOF: Bool?
    let stderrEOF: Bool?
    let processTree: String?
    let truncated: Bool?
    let verification: String?
    let completed: Bool

    static func make(
        record: StageDTaskRecord,
        approval: StageDApprovalProjection
    ) -> StageDCommandProjection {
        let terminal = record.attempts.last { $0.kind == .command && $0.phase != .intentRecorded }
        let command = terminal?.command ?? record.attempts.last(where: { $0.kind == .command })?.command
        let facts = terminal?.result?.facts.last
        return .init(
            phase: record.phase.rawValue,
            command: command?.parsed.original,
            risk: command?.risk.rawValue,
            binding: command.map { String($0.bindingSHA256.prefix(16)) },
            approval: approval.state?.rawValue ?? record.approvals.last?.state.rawValue,
            rootExit: facts?.rootExitObserved,
            stdoutEOF: facts?.stdoutEOFObserved,
            stderrEOF: facts?.stderrEOFObserved,
            processTree: facts?.processTreeState.rawValue,
            truncated: terminal?.result.map { $0.outputProjectionTruncated || (facts?.truncated ?? false) },
            verification: terminal?.result?.verification,
            completed: record.completion != nil
        )
    }
}

@MainActor
final class StageDCommandViewModel: ObservableObject {
    @Published var command = "pwd"
    @Published var cwd = "."
    @Published private(set) var task: StageDTaskRecord?
    @Published private(set) var approval = StageDApprovalProjection(state: nil, request: nil)
    @Published private(set) var risk: String?
    @Published private(set) var isRunning = false
    @Published var notice: String?

    private var prepared: StageBPreparedSession?
    private var store: StageDTaskStore?
    private var approvalTask: Task<Void, Never>?

    deinit { approvalTask?.cancel() }

    func load() async {
        do {
            let stageA = try StageAWorkspaceStore.applicationStore()
            let sessions = try StageBSessionStore.applicationStore()
            guard let session = try await sessions.records().last(where: {
                $0.phase == .completed && $0.completion != nil
            }) else {
                notice = "No completed workspace session"
                return
            }
            let restored = try await StageBSessionCoordinator(
                stageAStore: stageA,
                sessionStore: sessions
            ).restore(sessionID: session.id)
            let stageD = try StageDTaskStore.applicationStore()
            let existing = try await stageD.records().last { $0.sessionID == session.id }
            let record: StageDTaskRecord
            if let existing {
                record = existing
            } else {
                record = try await stageD.create(
                    session: restored.session,
                    workspace: restored.workspace,
                    ruleSet: restored.ruleSet,
                    write: nil,
                    expectation: .init(
                        kind: .successfulCommand,
                        relativePath: nil,
                        expectedSHA256: nil,
                        cloneTarget: nil,
                        cloneRemote: nil,
                        cloneHEAD: nil
                    )
                )
            }
            prepared = restored
            store = stageD
            task = record
            updateRisk()
            approvalTask?.cancel()
            approvalTask = Task { [weak self] in
                let stream = await StageDApprovalBroker.shared.projections()
                for await value in stream {
                    guard !Task.isCancelled else { break }
                    self?.approval = value
                    if let id = self?.task?.id, let stageD = self?.store {
                        self?.task = try? await stageD.snapshot(taskID: id)
                    }
                }
            }
        } catch {
            notice = "Stage D state is unavailable"
        }
    }

    func updateRisk() {
        guard let prepared, let task else { risk = nil; return }
        let policy = StageDCommandPolicy(
            workspaceIdentitySHA256: prepared.workspace.identitySHA256,
            write: task.write
        )
        switch policy.decide(command: command, cwd: cwd) {
        case let .authorized(value): risk = value.risk.rawValue
        case let .rejected(value, _): risk = value.rawValue
        case .unavailable: risk = StageDCommandRisk.unavailable.rawValue
        }
    }

    func runDirect() async { await run(model: false) }
    func runModel() async { await run(model: true) }

    private func run(model: Bool) async {
        guard !isRunning, let prepared, let store, let task else { return }
        isRunning = true
        defer { isRunning = false }
        do {
            let executor = try ISHStageDCommandExecutor.bundled(
                workspace: prepared.workspace,
                cloneRootURL: store.cloneRootURL
            )
            let provider: AgentInferenceProvider?
            if model {
                provider = try DeepSeekSecureConfigurationStore().makeProvider(
                    transport: URLSessionProviderTransport(),
                    attemptStore: FileProviderAttemptStore(directoryURL: store.rootURL
                        .appendingPathComponent("Provider", isDirectory: true)
                        .appendingPathComponent(task.id.uuidString.lowercased(), isDirectory: true))
                )
            } else {
                provider = nil
            }
            let agent = StageDCommandAgent(
                provider: provider,
                executor: executor,
                approvalAuthorizer: StageDApprovalBroker.shared,
                store: store,
                task: task,
                policy: StageDCommandPolicy(
                    workspaceIdentitySHA256: prepared.workspace.identitySHA256,
                    write: task.write
                ),
                requireProvider: model
            )
            let outcome = model
                ? await agent.runModelCommand()
                : await agent.run(command: command, cwd: cwd)
            self.task = try await store.snapshot(taskID: task.id)
            switch outcome {
            case .completed: notice = "Command completed"
            case .pendingApproval: notice = "Approval required"
            case .rejected: notice = "Command rejected"
            case .failed: notice = "Command stopped"
            case .reconciliationRequired: notice = "Command requires reconciliation"
            }
        } catch {
            notice = "Stage D could not start"
        }
    }

    func approve() {
        guard let request = approval.request else { return }
        Task { await StageDApprovalBroker.shared.approve(requestID: request.requestID, nonce: request.nonce) }
    }

    func reject() {
        guard let request = approval.request else { return }
        Task { await StageDApprovalBroker.shared.reject(requestID: request.requestID, nonce: request.nonce) }
    }

    var projection: StageDCommandProjection? {
        task.map { StageDCommandProjection.make(record: $0, approval: approval) }
    }
}

struct StageDCommandView: View {
    @StateObject private var viewModel = StageDCommandViewModel()

    var body: some View {
        Form {
            Section("Command") {
                TextField("Command", text: $viewModel.command)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                    .onChange(of: viewModel.command) { _ in viewModel.updateRisk() }
                TextField("Working directory", text: $viewModel.cwd)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: viewModel.cwd) { _ in viewModel.updateRisk() }
                if let risk = viewModel.risk {
                    LabeledContent("Risk", value: risk)
                }
                HStack {
                    Button { Task { await viewModel.runDirect() } } label: {
                        Label("Run", systemImage: "play.fill")
                    }
                    .disabled(viewModel.isRunning || viewModel.task == nil)
                    Button { Task { await viewModel.runModel() } } label: {
                        Label("Model", systemImage: "sparkles")
                    }
                    .disabled(viewModel.isRunning || viewModel.task == nil)
                }
            }
            if let request = viewModel.approval.request {
                Section("Approval") {
                    LabeledContent("Command", value: request.command)
                    LabeledContent("Risk", value: request.risk.rawValue)
                    LabeledContent("Binding", value: String(request.bindingSHA256.prefix(16)))
                    LabeledContent("Expires", value: request.expiresAt.formatted())
                    HStack {
                        Button("Approve") { viewModel.approve() }.buttonStyle(.borderedProminent)
                        Button("Reject", role: .destructive) { viewModel.reject() }.buttonStyle(.bordered)
                    }
                }
            }
            if let projection = viewModel.projection {
                Section("Execution") {
                    LabeledContent("State", value: projection.phase)
                    if let command = projection.command { LabeledContent("Command", value: command) }
                    if let binding = projection.binding { LabeledContent("Binding", value: binding) }
                    if let rootExit = projection.rootExit { LabeledContent("Root exit", value: String(rootExit)) }
                    if let tree = projection.processTree { LabeledContent("Process tree", value: tree) }
                    if let truncated = projection.truncated { LabeledContent("Truncated", value: String(truncated)) }
                    if let verification = projection.verification {
                        Text(verification).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle("Development Environment")
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
