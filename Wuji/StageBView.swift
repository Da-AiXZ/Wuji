import SwiftUI

@MainActor
final class StageBViewModel: ObservableObject {
    struct ObservationRow: Identifiable, Equatable {
        let id: UUID
        let tool: String
        let path: String
    }

    @Published var goalText = ""
    @Published var exactQuery = ""
    @Published private(set) var sessions: [StageBSessionRecord] = []
    @Published private(set) var selectedSession: StageBSessionRecord?
    @Published private(set) var observations: [ObservationRow] = []
    @Published private(set) var isRunning = false
    @Published var notice: String?

    let importRecord: StageAImportRecord
    private let limits: StageBLimits
    private let configurationStore: DeepSeekSecureConfigurationStore
    private var stageAStore: StageAWorkspaceStore?
    private var sessionStore: StageBSessionStore?

    init(
        importRecord: StageAImportRecord,
        limits: StageBLimits = .production,
        configurationStore: DeepSeekSecureConfigurationStore = DeepSeekSecureConfigurationStore()
    ) {
        self.importRecord = importRecord
        self.limits = limits
        self.configurationStore = configurationStore
    }

    func load() async {
        do {
            let store = (try await stores()).session
            sessions = (try await store.records()).filter { $0.importID == importRecord.id }
            if let latest = sessions.last {
                try await select(latest, store: store)
            }
        } catch {
            notice = "Session state unavailable"
        }
    }

    func start() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        do {
            let goal = try StageBGoal(text: goalText, exactQuery: exactQuery, limits: limits)
            let values = try await stores()
            let coordinator = StageBSessionCoordinator(
                stageAStore: values.stageA,
                sessionStore: values.session,
                limits: limits
            )
            let prepared = try await coordinator.create(importID: importRecord.id, goal: goal)
            let outcome = try await run(prepared, store: values.session)
            try await refresh(after: outcome, sessionID: prepared.session.id, store: values.session)
        } catch {
            notice = "Read-only session could not start"
        }
    }

    func resume(_ record: StageBSessionRecord) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        do {
            let values = try await stores()
            let coordinator = StageBSessionCoordinator(
                stageAStore: values.stageA,
                sessionStore: values.session,
                limits: limits
            )
            let prepared = try await coordinator.restore(sessionID: record.id)
            let outcome = try await run(prepared, store: values.session)
            try await refresh(after: outcome, sessionID: record.id, store: values.session)
        } catch {
            notice = "Session requires reconciliation"
        }
    }

    private func stores() async throws -> (stageA: StageAWorkspaceStore, session: StageBSessionStore) {
        if let stageAStore, let sessionStore { return (stageAStore, sessionStore) }
        let createdStageA = try StageAWorkspaceStore.applicationStore()
        let createdSession = try StageBSessionStore.applicationStore(limits: limits)
        stageAStore = createdStageA
        sessionStore = createdSession
        return (createdStageA, createdSession)
    }

    private func run(
        _ prepared: StageBPreparedSession,
        store: StageBSessionStore
    ) async throws -> StageBLoopOutcome {
        let directory = store.rootURL
            .appendingPathComponent("Sessions", isDirectory: true)
            .appendingPathComponent(prepared.session.id.uuidString.lowercased(), isDirectory: true)
        let providerStore = try FileProviderAttemptStore(directoryURL: directory)
        let provider = try configurationStore.makeProvider(
            transport: URLSessionProviderTransport(),
            attemptStore: providerStore
        )
        let executor = try ISHStageBReadOnlyExecutor.bundled(
            workspace: prepared.workspace,
            limits: limits
        )
        let agent = StageBReadOnlyAgent(
            provider: provider,
            executor: executor,
            policy: StageBReadOnlyPolicy(
                workspace: prepared.workspace,
                ruleSet: prepared.ruleSet,
                limits: limits
            ),
            sessionStore: store,
            workspace: prepared.workspace,
            ruleSet: prepared.ruleSet,
            limits: limits
        )
        return await agent.run(sessionID: prepared.session.id)
    }

    private func refresh(
        after outcome: StageBLoopOutcome,
        sessionID: UUID,
        store: StageBSessionStore
    ) async throws {
        let snapshot = try await store.snapshot(sessionID: sessionID)
        try await select(snapshot.session, store: store)
        switch outcome {
        case .completed: notice = "Read-only session completed"
        case .reconciliationRequired: notice = "Session requires reconciliation"
        case .failure: notice = "Read-only session stopped"
        }
    }

    private func select(_ record: StageBSessionRecord, store: StageBSessionStore) async throws {
        let snapshot = try await store.snapshot(sessionID: record.id)
        selectedSession = snapshot.session
        goalText = snapshot.session.goal.text
        exactQuery = snapshot.session.goal.exactQuery
        observations = snapshot.attempts.compactMap { evidence in
            guard let observation = evidence.observation else { return nil }
            return ObservationRow(
                id: evidence.operationID,
                tool: observation.tool.rawValue,
                path: observation.relativePath.isEmpty ? "." : observation.relativePath
            )
        }
        sessions = (try await store.records()).filter { $0.importID == importRecord.id }
    }
}

struct StageBSessionView: View {
    @StateObject private var viewModel: StageBViewModel

    init(importRecord: StageAImportRecord) {
        _viewModel = StateObject(wrappedValue: StageBViewModel(importRecord: importRecord))
    }

    var body: some View {
        Form {
            Section("Goal") {
                TextField("Goal", text: $viewModel.goalText, axis: .vertical)
                    .lineLimit(2...5)
                TextField("Exact query", text: $viewModel.exactQuery)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    Task { await viewModel.start() }
                } label: {
                    Label("Run read-only session", systemImage: "play.fill")
                }
                .disabled(
                    viewModel.isRunning
                        || viewModel.goalText.isEmpty
                        || viewModel.exactQuery.isEmpty
                )
            }

            if let selected = viewModel.selectedSession {
                Section("Session") {
                    LabeledContent("State", value: selected.phase.rawValue)
                    LabeledContent("Workspace", value: shortHash(selected.workspaceIdentitySHA256))
                    if let completion = selected.completion {
                        LabeledContent("Result", value: completion.relativePath)
                        NavigationLink {
                            StageCApprovalView(
                                importRecord: viewModel.importRecord,
                                sessionID: selected.id
                            )
                        } label: {
                            Label("Open bounded edit", systemImage: "square.and.pencil")
                        }
                    }
                }
                Section("Rules") {
                    ForEach(selected.rules, id: \.relativePath) { rule in
                        Label(rule.relativePath, systemImage: "doc.text")
                    }
                }
            }

            if !viewModel.observations.isEmpty {
                Section("Observations") {
                    ForEach(viewModel.observations) { observation in
                        LabeledContent(observation.tool, value: observation.path)
                    }
                }
            }

            if !viewModel.sessions.isEmpty {
                Section("Sessions") {
                    ForEach(viewModel.sessions) { session in
                        Button {
                            Task { await viewModel.resume(session) }
                        } label: {
                            HStack {
                                Text(session.goal.text).lineLimit(1)
                                Spacer()
                                Text(session.phase.rawValue).foregroundColor(.secondary)
                            }
                        }
                        .disabled(viewModel.isRunning)
                    }
                }
            }
        }
        .navigationTitle("Read-Only Session")
        .task { await viewModel.load() }
        .overlay {
            if viewModel.isRunning { ProgressView() }
        }
        .alert("Wuji", isPresented: Binding(
            get: { viewModel.notice != nil },
            set: { if !$0 { viewModel.notice = nil } }
        )) {
            Button("OK") { viewModel.notice = nil }
        } message: {
            Text(viewModel.notice ?? "")
        }
    }

    private func shortHash(_ value: String) -> String {
        String(value.prefix(12))
    }
}
