import SwiftUI

@MainActor
final class S4ApprovalViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case pending(S4ApprovalRequest)
        case approved(S4ApprovalRequest)
        case rejected(S4ApprovalRequest)
        case running
        case reconciliationRequired
        case completed
        case failed
    }

    @Published private(set) var state: State = .idle
    private let broker: S4ApprovalBroker
    private let executionBroker: S4ExecutionProjectionBroker

    init(
        broker: S4ApprovalBroker = .shared,
        executionBroker: S4ExecutionProjectionBroker = .shared
    ) {
        self.broker = broker
        self.executionBroker = executionBroker
    }

    func observeExecution() async {
        for await projection in await executionBroker.projections() {
            switch projection {
            case .running: state = .running
            case .reconciliationRequired: state = .reconciliationRequired
            case .completed: state = .completed
            case .failed: state = .failed
            }
        }
    }

    func observe() async {
        for await projection in await broker.projections() {
            switch projection.state {
            case .idle:
                state = .idle
            case .pendingApproval:
                if let request = projection.request { state = .pending(request) }
            case .approved:
                if let request = projection.request { state = .approved(request) }
            case .rejected:
                if let request = projection.request { state = .rejected(request) }
            }
        }
    }

    func approve() {
        guard case let .pending(request) = state else { return }
        Task { await broker.approve(requestID: request.requestID, nonce: request.nonce) }
    }

    func reject() {
        guard case let .pending(request) = state else { return }
        Task { await broker.reject(requestID: request.requestID, nonce: request.nonce) }
    }

}

struct S4ApprovalView: View {
    @StateObject private var model: S4ApprovalViewModel

    @MainActor
    init() {
        _model = StateObject(wrappedValue: S4ApprovalViewModel())
    }

    @MainActor
    init(model: S4ApprovalViewModel) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Task modification", systemImage: "checkmark.shield")
                .font(.headline)

            switch model.state {
            case .idle:
                status("No pending modification", icon: "pause.circle")
            case let .pending(request):
                approvalDetails(request)
                HStack(spacing: 12) {
                    Button(action: model.reject) {
                        Label("Reject", systemImage: "xmark")
                    }
                    .buttonStyle(.bordered)

                    Button(action: model.approve) {
                        Label("Approve", systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                }
            case let .approved(request):
                approvalDetails(request)
                status("Approved", icon: "checkmark.circle.fill")
            case let .rejected(request):
                approvalDetails(request)
                status("Rejected", icon: "xmark.circle.fill")
            case .running:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Running")
                }
            case .reconciliationRequired:
                status("Reconciliation required", icon: "exclamationmark.triangle.fill")
            case .completed:
                status("Completed", icon: "checkmark.seal.fill")
            case .failed:
                status("Failed", icon: "xmark.octagon.fill")
            }
        }
        .padding(.vertical, 8)
        .task { await model.observe() }
        .task { await model.observeExecution() }
    }

    @ViewBuilder
    private func approvalDetails(_ request: S4ApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            detail("Task", S4TaskContract.packageID)
            detail("File", request.relativePath)
            detail("Change", "STATUS=pending -> STATUS=verified")
            detail("Verify", request.verificationProfile.rawValue)
        }
        .font(.subheadline)
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundColor(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private func status(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon).foregroundColor(.secondary)
    }
}
