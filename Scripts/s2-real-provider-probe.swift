import Foundation

#if canImport(Darwin)
import Darwin
#endif

private struct ProbeSummary: Encodable {
    let requestID: String
    let resultCategory: String
    let responseByteCount: Int
    let responseSHA256: String

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case resultCategory = "result_category"
        case responseByteCount = "response_byte_count"
        case responseSHA256 = "response_sha256"
    }
}

@main
private struct S2RealProviderProbe {
    private static let prompt = "Reply with one short sentence confirming that the service is reachable."

    static func main() async {
        let environment = ProcessInfo.processInfo.environment
        guard let baseURL = environment["DEEPSEEK_BASE_URL"],
              let model = environment["DEEPSEEK_MODEL"],
              let apiKey = environment["DEEPSEEK_API_KEY"],
              !baseURL.isEmpty,
              !model.isEmpty,
              !apiKey.isEmpty,
              CommandLine.arguments.count == 2 else {
            emitFailure(category: "configuration_rejected", code: 20)
        }
        guard !CommandLine.arguments.contains(where: {
            $0.contains(baseURL) || $0.contains(model) || $0.contains(apiKey)
        }) else {
            emitFailure(category: "secret_in_process_arguments", code: 21)
        }

        let evidenceDirectory = URL(
            fileURLWithPath: CommandLine.arguments[1],
            isDirectory: true
        )
        let requestID = UUID()

        do {
            let credential = try ProviderCredential(apiKey)
            let store = try FileProviderAttemptStore(directoryURL: evidenceDirectory)
            let provider = try DeepSeekProvider(
                baseURL: baseURL,
                model: model,
                credentialSource: StaticProviderCredentialSource(credential: credential),
                transport: URLSessionProviderTransport(),
                attemptStore: store
            )
            let outcome = await provider.complete(prompt: prompt, requestID: requestID)
            switch outcome {
            case let .response(completion):
                guard completion.requestID == requestID,
                      completion.responseByteCount > 0,
                      completion.responseByteCount <= ProviderLimits.maximumOutputBytes,
                      completion.responseSHA256.count == 64,
                      !completion.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    emitFailure(category: "response_validation_failed", code: 22)
                }
                emit(ProbeSummary(
                    requestID: requestID.uuidString,
                    resultCategory: "response",
                    responseByteCount: completion.responseByteCount,
                    responseSHA256: completion.responseSHA256
                ))
            case .failure:
                emitFailure(category: "provider_failure", code: 23)
            case .unknown:
                emitFailure(category: "reconciliation_required", code: 24)
            }
        } catch {
            emitFailure(category: "configuration_rejected", code: 25)
        }
    }

    private static func emitFailure(category: String, code: Int32) -> Never {
        emit(ProbeSummary(
            requestID: "unavailable",
            resultCategory: category,
            responseByteCount: 0,
            responseSHA256: String(repeating: "0", count: 64)
        ))
        terminate(code)
    }

    private static func emit(_ summary: ProbeSummary) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var data = try? encoder.encode(summary) else {
            terminate(26)
        }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }

    private static func terminate(_ code: Int32) -> Never {
#if canImport(Darwin)
        Darwin.exit(code)
#else
        fatalError("S2 Provider probe terminated with code \(code)")
#endif
    }
}
