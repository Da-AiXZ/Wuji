import SwiftUI

@MainActor
final class ExecutorSelfTestViewModel: ObservableObject {
    enum State {
        case idle
        case running
        case finished([ExecutorSelfTestCase: ExecutorObservation])
    }

    @Published private(set) var state: State = .idle
    private let executor = ISHExecutor.shared

    func run() {
        if case .running = state { return }
        state = .running
        Task {
            var observations: [ExecutorSelfTestCase: ExecutorObservation] = [:]
            for testCase in [ExecutorSelfTestCase.success, .nonzero, .truncation] {
                observations[testCase] = await executor.execute(testCase, outputLimit: 4_096)
            }
            state = .finished(observations)
        }
    }
}

struct ExecutorSelfTestView: View {
    @StateObject private var model = ExecutorSelfTestViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("执行器自检")
                    .font(.headline)
                Spacer()
                Button(action: model.run) {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.bordered)
                .disabled(isRunning)
                .accessibilityLabel("运行执行器自检")
            }

            switch model.state {
            case .idle:
                Text("尚未运行")
                    .foregroundColor(.secondary)
            case .running:
                ProgressView()
            case .finished(let observations):
                ForEach(ExecutorSelfTestCase.allCases.filter { $0 != .cancellation }) { testCase in
                    if let observation = observations[testCase] {
                        HStack {
                            Text(label(for: testCase))
                            Spacer()
                            Image(systemName: observation.completionBarrierSatisfied ? "checkmark.circle" : "xmark.circle")
                        }
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }

    private var isRunning: Bool {
        if case .running = model.state { return true }
        return false
    }

    private func label(for testCase: ExecutorSelfTestCase) -> String {
        switch testCase {
        case .success: return "成功命令"
        case .nonzero: return "非零退出"
        case .truncation: return "输出上限"
        case .cancellation: return "取消"
        }
    }
}
