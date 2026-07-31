import CryptoKit
import Foundation

enum ISHExecutorError: Error, LocalizedError {
    case missingRootFS
    case rootFSSize(Int)
    case rootFSHash(String)
    case preparation(String)

    var errorDescription: String? {
        switch self {
        case .missingRootFS:
            return "缺少固定rootfs"
        case .rootFSSize:
            return "rootfs长度校验失败"
        case .rootFSHash:
            return "rootfs哈希校验失败"
        case .preparation:
            return "iSH初始化失败"
        }
    }
}

final class ISHExecutor: ISHSelfTestExecuting, @unchecked Sendable {
    static let shared = ISHExecutor()

    private static let rootFSSize = 3_851_686
    private static let rootFSHash = "f31202c4070c4ef7de9e157e1bd01cb4da3a2150035d74ea5372c5e86f1efac1"
    private let preparationLock = NSLock()
    private var prepared = false

    private init() {}

    func execute(_ testCase: ExecutorSelfTestCase, outputLimit: Int = 4_096) async -> ExecutorObservation {
        do {
            try prepareIfNeeded()
        } catch {
            return unknownObservation(error.localizedDescription)
        }

        return await Task.detached(priority: .userInitiated) {
            guard let rawResult = wuji_ish_run_self_test(
                WujiISHSelfTestCase(rawValue: testCase.rawValue),
                numericCast(max(0, outputLimit))
            ) else {
                return self.unknownObservation("结果分配失败")
            }
            defer { wuji_ish_result_free(rawResult) }

            let error = String(cString: wuji_ish_result_error(rawResult))
            let finalState: ExecutorFinalState
            switch wuji_ish_result_final_kind(rawResult) {
            case WUJI_ISH_FINAL_EXITED:
                finalState = .exited(wuji_ish_result_final_value(rawResult))
            case WUJI_ISH_FINAL_SIGNALED:
                finalState = .signaled(wuji_ish_result_final_value(rawResult))
            default:
                finalState = .unknown(error.isEmpty ? "最终状态未知" : error)
            }

            let cancellationDelivery: CancellationDelivery?
            switch wuji_ish_result_cancel_delivery(rawResult) {
            case WUJI_ISH_CANCEL_SIGNAL_SENT:
                cancellationDelivery = .signalSent
            case WUJI_ISH_CANCEL_NO_ACTIVE_TASK:
                cancellationDelivery = .noActiveTask
            default:
                cancellationDelivery = nil
            }

            return ExecutorObservation(
                stdout: String(cString: wuji_ish_result_stdout(rawResult)),
                stderr: String(cString: wuji_ish_result_stderr(rawResult)),
                rootExitObserved: wuji_ish_result_root_exited(rawResult),
                stdoutEOFObserved: wuji_ish_result_stdout_eof(rawResult),
                stderrEOFObserved: wuji_ish_result_stderr_eof(rawResult),
                truncated: wuji_ish_result_truncated(rawResult),
                cancellationRequested: wuji_ish_result_cancellation_requested(rawResult),
                cancellationDelivery: cancellationDelivery,
                finalState: finalState
            )
        }.value
    }

    func requestCancellation() -> CancellationReceipt {
        let delivery = wuji_ish_request_cancel() == WUJI_ISH_CANCEL_SIGNAL_SENT
            ? CancellationDelivery.signalSent
            : CancellationDelivery.noActiveTask
        return CancellationReceipt(requested: true, delivery: delivery)
    }

    private func prepareIfNeeded() throws {
        preparationLock.lock()
        defer { preparationLock.unlock() }
        if prepared { return }

        guard let archiveURL = Bundle.main.url(forResource: "rootfs", withExtension: "tar.gz") else {
            throw ISHExecutorError.missingRootFS
        }
        let data = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
        guard data.count == Self.rootFSSize else {
            throw ISHExecutorError.rootFSSize(data.count)
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == Self.rootFSHash else {
            throw ISHExecutorError.rootFSHash(digest)
        }

        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let rootURL = applicationSupport.appendingPathComponent("WujiS1Root", isDirectory: true)
        var errorBuffer = [CChar](repeating: 0, count: 512)
        let status = archiveURL.path.withCString { archivePath in
            rootURL.path.withCString { rootPath in
                wuji_ish_prepare(archivePath, rootPath, &errorBuffer, errorBuffer.count)
            }
        }
        guard status == 0 else {
            throw ISHExecutorError.preparation(String(cString: errorBuffer))
        }
        prepared = true
    }

    private func unknownObservation(_ reason: String) -> ExecutorObservation {
        ExecutorObservation(
            stdout: "",
            stderr: "",
            rootExitObserved: false,
            stdoutEOFObserved: false,
            stderrEOFObserved: false,
            truncated: false,
            cancellationRequested: false,
            cancellationDelivery: nil,
            finalState: .unknown(reason)
        )
    }
}
