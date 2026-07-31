import Foundation

enum ExecutorSelfTestCase: Int32, CaseIterable, Identifiable, Sendable {
    case success = 0
    case nonzero = 1
    case truncation = 2
    case cancellation = 3

    var id: Int32 { rawValue }
}

enum ExecutorFinalState: Equatable, Sendable {
    case exited(Int32)
    case signaled(Int32)
    case unknown(String)
}

enum CancellationDelivery: Equatable, Sendable {
    case signalSent
    case noActiveTask
}

struct CancellationReceipt: Equatable, Sendable {
    let requested: Bool
    let delivery: CancellationDelivery
}

struct ExecutorObservation: Equatable, Sendable {
    let stdout: String
    let stderr: String
    let rootExitObserved: Bool
    let stdoutEOFObserved: Bool
    let stderrEOFObserved: Bool
    let truncated: Bool
    let cancellationRequested: Bool
    let cancellationDelivery: CancellationDelivery?
    let finalState: ExecutorFinalState

    var completionBarrierSatisfied: Bool {
        rootExitObserved && stdoutEOFObserved && stderrEOFObserved
    }
}

protocol ISHSelfTestExecuting: Sendable {
    func execute(_ testCase: ExecutorSelfTestCase, outputLimit: Int) async -> ExecutorObservation
    func requestCancellation() -> CancellationReceipt
}
