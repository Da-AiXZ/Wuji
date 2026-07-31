import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct ProviderHTTPRequest: @unchecked Sendable, CustomStringConvertible {
    let url: URL
    let headers: [String: String]
    let body: Data
    let timeout: TimeInterval

    var description: String {
        "ProviderHTTPRequest(method: POST, endpoint: redacted, bodyBytes: \(body.count), headers: redacted)"
    }
}

struct ProviderHTTPResponse: Sendable {
    let statusCode: Int
    let body: Data
}

enum ProviderTransportError: Error, Equatable, CustomStringConvertible {
    case responseTooLarge
    case invalidHTTPResponse
    case network

    var description: String {
        switch self {
        case .responseTooLarge:
            return "provider response exceeded transport limit"
        case .invalidHTTPResponse:
            return "provider returned a non-HTTP response"
        case .network:
            return "provider transport result is uncertain"
        }
    }
}

protocol ProviderTransport: Sendable {
    func send(_ request: ProviderHTTPRequest) async throws -> ProviderHTTPResponse
}

struct DeepSeekEndpoint: Equatable, Sendable {
    let chatCompletionsURL: URL

    init(baseURL: String) throws {
        guard baseURL.utf8.count <= 2_048,
              var components = URLComponents(string: baseURL),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              components.query == nil else {
            throw ProviderConfigurationError.invalidBaseURL
        }

        let encodedPath = components.percentEncodedPath
        let lowerEncodedPath = encodedPath.lowercased()
        guard !encodedPath.contains("\\"),
              !lowerEncodedPath.contains("%2f"),
              !lowerEncodedPath.contains("%5c") else {
            throw ProviderConfigurationError.invalidBaseURL
        }

        var pathParts = components.path.split(separator: "/").map(String.init)
        guard pathParts.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw ProviderConfigurationError.invalidBaseURL
        }
        if pathParts.suffix(2).map({ $0.lowercased() }) != ["chat", "completions"] {
            pathParts.append("chat")
            pathParts.append("completions")
        }
        components.path = "/" + pathParts.joined(separator: "/")
        components.percentEncodedQuery = nil

        guard let endpoint = components.url,
              endpoint.scheme?.lowercased() == "https",
              endpoint.host?.lowercased() == components.host?.lowercased() else {
            throw ProviderConfigurationError.invalidBaseURL
        }
        chatCompletionsURL = endpoint
    }
}

final class URLSessionProviderTransport: ProviderTransport, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let maximumResponseBytes: Int

    init(
        configuration: URLSessionConfiguration = .ephemeral,
        maximumResponseBytes: Int = ProviderLimits.maximumResponseBodyBytes
    ) {
        self.configuration = configuration
        self.maximumResponseBytes = maximumResponseBytes
    }

    func send(_ request: ProviderHTTPRequest) async throws -> ProviderHTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = request.timeout
        urlRequest.httpBody = request.body
        urlRequest.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.headers.forEach { urlRequest.setValue($0.value, forHTTPHeaderField: $0.key) }

        let collector = BoundedResponseCollector(
            configuration: configuration,
            maximumResponseBytes: maximumResponseBytes
        )
        return try await collector.perform(urlRequest)
    }
}

private final class BoundedResponseCollector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let maximumResponseBytes: Int
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ProviderHTTPResponse, Error>?
    private var response: HTTPURLResponse?
    private var body = Data()
    private var terminalError: ProviderTransportError?
    private var session: URLSession?

    init(configuration: URLSessionConfiguration, maximumResponseBytes: Int) {
        self.configuration = configuration
        self.maximumResponseBytes = maximumResponseBytes
    }

    func perform(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            let session = URLSession(
                configuration: configuration,
                delegate: self,
                delegateQueue: nil
            )
            self.session = session
            lock.unlock()
            session.dataTask(with: request).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let httpResponse = response as? HTTPURLResponse else {
            terminalError = .invalidHTTPResponse
            completionHandler(.cancel)
            return
        }
        self.response = httpResponse
        if response.expectedContentLength > Int64(maximumResponseBytes) {
            terminalError = .responseTooLarge
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if body.count > maximumResponseBytes - data.count {
            terminalError = .responseTooLarge
            dataTask.cancel()
            return
        }
        body.append(data)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        let terminalError = self.terminalError
        let response = self.response
        let body = self.body
        self.session?.finishTasksAndInvalidate()
        self.session = nil
        lock.unlock()

        if let terminalError {
            continuation.resume(throwing: terminalError)
        } else if error != nil {
            continuation.resume(throwing: ProviderTransportError.network)
        } else if let response {
            continuation.resume(returning: ProviderHTTPResponse(
                statusCode: response.statusCode,
                body: body
            ))
        } else {
            continuation.resume(throwing: ProviderTransportError.invalidHTTPResponse)
        }
    }
}

final class DeepSeekProvider: CloudProvider, @unchecked Sendable {
    let providerID = "deepseek"

    private let endpoint: DeepSeekEndpoint
    private let model: String
    private let modelSHA256: String
    private let credentialSource: ProviderCredentialSource
    private let transport: ProviderTransport
    private let attemptStore: ProviderAttemptRecording
    private let now: @Sendable () -> Date

    init(
        baseURL: String,
        model: String,
        credentialSource: ProviderCredentialSource,
        transport: ProviderTransport,
        attemptStore: ProviderAttemptRecording,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        let modelBytes = model.lengthOfBytes(using: .utf8)
        guard modelBytes > 0,
              modelBytes <= ProviderLimits.maximumModelBytes,
              model == model.trimmingCharacters(in: .whitespacesAndNewlines),
              model.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw ProviderConfigurationError.invalidModel
        }
        endpoint = try DeepSeekEndpoint(baseURL: baseURL)
        self.model = model
        modelSHA256 = ProviderDigest.sha256Hex(model)
        self.credentialSource = credentialSource
        self.transport = transport
        self.attemptStore = attemptStore
        self.now = now
    }

    func complete(prompt: String, requestID: UUID) async -> ProviderOutcome {
        guard prompt.lengthOfBytes(using: .utf8) > 0,
              prompt.lengthOfBytes(using: .utf8) <= ProviderLimits.maximumPromptBytes,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.invalidInput)
        }

        let attemptID = UUID()
        let intent = evidence(
            requestID: requestID,
            attemptID: attemptID,
            phase: .intentRecorded,
            resultCategory: .none
        )
        do {
            try await attemptStore.record(intent)
        } catch {
            return .failure(.evidenceWriteFailed)
        }

        let credential: ProviderCredential
        do {
            credential = try credentialSource.credential()
        } catch {
            return await finishFailure(
                .credentialUnavailable,
                category: .credentialUnavailable,
                requestID: requestID,
                attemptID: attemptID
            )
        }

        let body: Data
        do {
            body = try JSONEncoder().encode(OpenAIChatCompletionRequest(
                model: model,
                messages: [OpenAIChatMessage(role: "user", content: prompt)],
                maxTokens: 64,
                stream: false
            ))
        } catch {
            return await finishFailure(
                .invalidInput,
                category: .invalidInput,
                requestID: requestID,
                attemptID: attemptID
            )
        }

        let request = credential.withValue { secret in
            ProviderHTTPRequest(
                url: endpoint.chatCompletionsURL,
                headers: [
                    "Authorization": "Bearer \(secret)",
                    "Content-Type": "application/json",
                    "Accept": "application/json"
                ],
                body: body,
                timeout: ProviderLimits.requestTimeoutSeconds
            )
        }

        let httpResponse: ProviderHTTPResponse
        do {
            httpResponse = try await transport.send(request)
        } catch ProviderTransportError.responseTooLarge {
            return await finishFailure(
                .responseTooLarge,
                category: .responseTooLarge,
                requestID: requestID,
                attemptID: attemptID
            )
        } catch {
            let unknownEvidence = evidence(
                requestID: requestID,
                attemptID: attemptID,
                phase: .reconciliationRequired,
                resultCategory: .transportUnknown
            )
            try? await attemptStore.record(unknownEvidence)
            return .unknown(.reconciliationRequired)
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            return await finishFailure(
                .httpStatus(httpResponse.statusCode),
                category: .httpError,
                requestID: requestID,
                attemptID: attemptID
            )
        }
        guard !httpResponse.body.isEmpty else {
            return await finishFailure(
                .emptyResponse,
                category: .emptyResponse,
                requestID: requestID,
                attemptID: attemptID
            )
        }
        guard httpResponse.body.count <= ProviderLimits.maximumResponseBodyBytes else {
            return await finishFailure(
                .responseTooLarge,
                category: .responseTooLarge,
                requestID: requestID,
                attemptID: attemptID
            )
        }

        let decoded: OpenAIChatCompletionResponse
        do {
            decoded = try JSONDecoder().decode(OpenAIChatCompletionResponse.self, from: httpResponse.body)
        } catch {
            return await finishFailure(
                .malformedResponse,
                category: .malformedResponse,
                requestID: requestID,
                attemptID: attemptID
            )
        }
        guard !decoded.id.isEmpty,
              !decoded.choices.isEmpty,
              decoded.choices.count <= ProviderLimits.maximumChoices else {
            return await finishFailure(
                .malformedResponse,
                category: .malformedResponse,
                requestID: requestID,
                attemptID: attemptID
            )
        }
        let choice = decoded.choices[0]
        guard choice.message.toolCalls.isEmpty,
              choice.finishReason != "tool_calls" else {
            return await finishFailure(
                .toolCallsRejected,
                category: .toolCallsRejected,
                requestID: requestID,
                attemptID: attemptID
            )
        }
        guard let content = choice.message.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return await finishFailure(
                .emptyResponse,
                category: .emptyResponse,
                requestID: requestID,
                attemptID: attemptID
            )
        }
        let outputData = Data(content.utf8)
        guard outputData.count <= ProviderLimits.maximumOutputBytes else {
            return await finishFailure(
                .responseTooLarge,
                category: .responseTooLarge,
                requestID: requestID,
                attemptID: attemptID
            )
        }

        let responseSHA256 = ProviderDigest.sha256Hex(outputData)
        let successEvidence = evidence(
            requestID: requestID,
            attemptID: attemptID,
            phase: .succeeded,
            resultCategory: .response,
            responseByteCount: outputData.count,
            responseSHA256: responseSHA256
        )
        do {
            try await attemptStore.record(successEvidence)
        } catch {
            return .failure(.evidenceWriteFailed)
        }
        return .response(ProviderCompletion(
            requestID: requestID,
            text: content,
            responseByteCount: outputData.count,
            responseSHA256: responseSHA256
        ))
    }

    private func finishFailure(
        _ failure: ProviderFailure,
        category: ProviderAttemptResultCategory,
        requestID: UUID,
        attemptID: UUID
    ) async -> ProviderOutcome {
        do {
            try await attemptStore.record(evidence(
                requestID: requestID,
                attemptID: attemptID,
                phase: .failed,
                resultCategory: category
            ))
            return .failure(failure)
        } catch {
            return .failure(.evidenceWriteFailed)
        }
    }

    private func evidence(
        requestID: UUID,
        attemptID: UUID,
        phase: ProviderAttemptPhase,
        resultCategory: ProviderAttemptResultCategory,
        responseByteCount: Int? = nil,
        responseSHA256: String? = nil
    ) -> ProviderAttemptEvidence {
        ProviderAttemptEvidence(
            requestID: requestID,
            attemptID: attemptID,
            providerID: providerID,
            modelSHA256: modelSHA256,
            recordedAt: now(),
            phase: phase,
            resultCategory: resultCategory,
            responseByteCount: responseByteCount,
            responseSHA256: responseSHA256
        )
    }
}

private struct OpenAIChatCompletionRequest: Encodable {
    let model: String
    let messages: [OpenAIChatMessage]
    let maxTokens: Int
    let stream: Bool

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case maxTokens = "max_tokens"
        case stream
    }
}

private struct OpenAIChatMessage: Codable {
    let role: String
    let content: String
}

private struct OpenAIChatCompletionResponse: Decodable {
    let id: String
    let choices: [OpenAIChatChoice]
}

private struct OpenAIChatChoice: Decodable {
    let index: Int
    let message: OpenAIChatResponseMessage
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case index
        case message
        case finishReason = "finish_reason"
    }
}

private struct OpenAIChatResponseMessage: Decodable {
    let role: String
    let content: String?
    let toolCalls: [OpenAIToolCallEnvelope]

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCalls = "tool_calls"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(String.self, forKey: .role)
        content = try container.decodeIfPresent(String.self, forKey: .content)
        toolCalls = try container.decodeIfPresent([OpenAIToolCallEnvelope].self, forKey: .toolCalls) ?? []
    }
}

private struct OpenAIToolCallEnvelope: Decodable {
    let id: String?
    let type: String?
}
