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

final class DeepSeekProvider: CloudProvider, AgentInferenceProvider, @unchecked Sendable {
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
                stream: false,
                tools: nil,
                toolChoice: nil
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

    func infer(request: ProviderInferenceRequest, requestID: UUID) async -> ProviderInferenceOutcome {
        guard validate(request) else {
            return .failure(.invalidInput)
        }

        let attemptID = UUID()
        do {
            try await attemptStore.record(evidence(
                requestID: requestID,
                attemptID: attemptID,
                phase: .intentRecorded,
                resultCategory: .none
            ))
        } catch {
            return .failure(.evidenceWriteFailed)
        }

        let credential: ProviderCredential
        do {
            credential = try credentialSource.credential()
        } catch {
            return await finishInferenceFailure(
                .credentialUnavailable,
                category: .credentialUnavailable,
                requestID: requestID,
                attemptID: attemptID
            )
        }

        let body: Data
        do {
            let messages = request.messages.map(OpenAIChatMessage.init)
            let tools = request.tools.map {
                OpenAIToolDefinitionEnvelope(type: "function", function: $0)
            }
            body = try JSONEncoder().encode(OpenAIChatCompletionRequest(
                model: model,
                messages: messages,
                maxTokens: 256,
                stream: false,
                tools: tools,
                toolChoice: nil
            ))
            guard body.count <= ProviderLimits.maximumRequestBodyBytes else {
                return await finishInferenceFailure(
                    .invalidInput,
                    category: .invalidInput,
                    requestID: requestID,
                    attemptID: attemptID
                )
            }
        } catch {
            return await finishInferenceFailure(
                .invalidInput,
                category: .invalidInput,
                requestID: requestID,
                attemptID: attemptID
            )
        }

        let httpRequest = credential.withValue { secret in
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
            httpResponse = try await transport.send(httpRequest)
        } catch ProviderTransportError.responseTooLarge {
            return await finishInferenceFailure(
                .responseTooLarge,
                category: .responseTooLarge,
                requestID: requestID,
                attemptID: attemptID
            )
        } catch {
            try? await attemptStore.record(evidence(
                requestID: requestID,
                attemptID: attemptID,
                phase: .reconciliationRequired,
                resultCategory: .transportUnknown
            ))
            return .unknown(.reconciliationRequired)
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            return await finishInferenceFailure(
                .httpStatus(httpResponse.statusCode),
                category: .httpError,
                requestID: requestID,
                attemptID: attemptID
            )
        }
        guard !httpResponse.body.isEmpty else {
            return await finishInferenceFailure(
                .emptyResponse,
                category: .emptyResponse,
                requestID: requestID,
                attemptID: attemptID
            )
        }
        guard httpResponse.body.count <= ProviderLimits.maximumResponseBodyBytes,
              let decoded = try? JSONDecoder().decode(
                OpenAIChatCompletionResponse.self,
                from: httpResponse.body
              ),
              !decoded.id.isEmpty,
              decoded.choices.count == 1 else {
            return await finishInferenceFailure(
                .malformedResponse,
                category: .malformedResponse,
                requestID: requestID,
                attemptID: attemptID
            )
        }

        let choice = decoded.choices[0]
        switch classifyToolExchange(
            choice,
            allowedToolNames: Set(request.tools.map(\.name))
        ) {
        case let .toolCalls(calls, assistantContent, diagnostic):
            let assistant = ProviderTurnMessage(
                role: .assistant,
                content: assistantContent,
                toolCalls: calls
            )
            guard let batchData = try? JSONEncoder().encode(calls) else {
                return await finishInferenceFailure(
                    .invalidToolExchange,
                    category: .invalidToolExchange,
                    requestID: requestID,
                    attemptID: attemptID
                )
            }
            guard await recordInferenceSuccess(
                requestID: requestID,
                attemptID: attemptID,
                category: .toolCall,
                data: batchData,
                toolExchangeDiagnostic: diagnostic
            ) else {
                return .failure(.evidenceWriteFailed)
            }
            return .decision(.toolCalls(assistant, calls))
        case let .finish(content):
            let assistant = ProviderTurnMessage(role: .assistant, content: content)
            let contentData = Data(content.utf8)
            guard await recordInferenceSuccess(
                requestID: requestID,
                attemptID: attemptID,
                category: .finish,
                data: contentData
            ) else {
                return .failure(.evidenceWriteFailed)
            }
            return .decision(.finish(assistant))
        case let .rejected(diagnostic):
            return await finishInferenceFailure(
                .invalidToolExchange,
                category: .invalidToolExchange,
                requestID: requestID,
                attemptID: attemptID,
                toolExchangeDiagnostic: diagnostic
            )
        }
    }

    private func classifyToolExchange(
        _ choice: OpenAIChatChoice,
        allowedToolNames: Set<String>
    ) -> OpenAIToolExchangeClassification {
        let calls = choice.message.toolCalls
        guard !calls.isEmpty else {
            guard choice.finishReason == "stop",
                  let content = choice.message.content,
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  content.utf8.count <= ProviderLimits.maximumOutputBytes else {
                return .rejected(diagnostic(
                    .noToolCallsWithInvalidFinishOrContent,
                    choice: choice,
                    envelope: nil
                ))
            }
            return .finish(content)
        }

        guard calls.count <= ProviderLimits.maximumToolCalls else {
            return .rejected(diagnostic(.toolCallCount, choice: choice, envelope: calls.first))
        }
        guard choice.message.content.map({ $0.utf8.count <= ProviderLimits.maximumOutputBytes }) ?? true else {
            return .rejected(diagnostic(.assistantContentTooLarge, choice: choice, envelope: calls.first))
        }
        var ids = Set<String>()
        var typedCalls: [ProviderTurnToolCall] = []
        typedCalls.reserveCapacity(calls.count)
        var compatibilityDiagnostic: ProviderToolExchangeDiagnostic?
        for envelope in calls {
            guard envelope.type == "function" else {
                return .rejected(diagnostic(.envelopeType, choice: choice, envelope: envelope))
            }
            guard let id = envelope.id,
                  validIdentifier(id, maximumBytes: ProviderLimits.maximumToolCallIDBytes) else {
                return .rejected(diagnostic(.idMissingOrInvalid, choice: choice, envelope: envelope))
            }
            guard ids.insert(id).inserted else {
                return .rejected(diagnostic(.idDuplicate, choice: choice, envelope: envelope))
            }
            guard let name = envelope.function?.name,
                  validToolName(name) else {
                return .rejected(diagnostic(.toolNameMissingOrInvalid, choice: choice, envelope: envelope))
            }
            guard let arguments = envelope.function?.arguments,
                  !arguments.isEmpty else {
                return .rejected(diagnostic(.argumentsMissing, choice: choice, envelope: envelope))
            }
            guard arguments.utf8.count <= ProviderLimits.maximumToolArgumentsBytes else {
                return .rejected(diagnostic(.argumentsTooLarge, choice: choice, envelope: envelope))
            }
            if compatibilityDiagnostic == nil, !allowedToolNames.contains(name) {
                compatibilityDiagnostic = diagnostic(
                    .toolNameNotAllowed,
                    choice: choice,
                    envelope: envelope
                )
            }
            typedCalls.append(ProviderTurnToolCall(id: id, name: name, arguments: arguments))
        }
        return .toolCalls(
            typedCalls,
            assistantContent: choice.message.content,
            diagnostic: compatibilityDiagnostic
        )
    }

    private func diagnostic(
        _ reason: ProviderToolExchangeRejectionReason,
        choice: OpenAIChatChoice,
        envelope: OpenAIResponseToolCallEnvelope?
    ) -> ProviderToolExchangeDiagnostic {
        let function = envelope?.function
        return ProviderToolExchangeDiagnostic(
            reason: reason,
            toolCallCount: capped(
                choice.message.toolCalls.count,
                maximum: ProviderLimits.maximumToolCalls
            ),
            finishReasonPresent: choice.finishReason != nil,
            finishReasonByteCount: capped(
                choice.finishReason?.utf8.count ?? 0,
                maximum: ProviderLimits.maximumToolNameBytes
            ),
            assistantContentPresent: choice.message.content != nil,
            assistantContentByteCount: capped(
                choice.message.content?.utf8.count ?? 0,
                maximum: ProviderLimits.maximumOutputBytes
            ),
            envelopeTypeIsFunction: envelope?.type == "function",
            toolCallIDPresent: envelope?.id != nil,
            toolCallIDByteCount: capped(
                envelope?.id?.utf8.count ?? 0,
                maximum: ProviderLimits.maximumToolCallIDBytes
            ),
            toolNamePresent: function?.name != nil,
            toolNameByteCount: capped(
                function?.name?.utf8.count ?? 0,
                maximum: ProviderLimits.maximumToolNameBytes
            ),
            argumentsPresent: function?.arguments != nil,
            argumentsByteCount: capped(
                function?.arguments?.utf8.count ?? 0,
                maximum: ProviderLimits.maximumToolArgumentsBytes
            )
        )
    }

    private func capped(_ value: Int, maximum: Int) -> Int {
        min(value, maximum + 1)
    }

    private func validate(_ request: ProviderInferenceRequest) -> Bool {
        guard !request.messages.isEmpty,
              request.messages.count <= ProviderLimits.maximumTurnMessages,
              !request.tools.isEmpty,
              request.tools.count <= ProviderLimits.maximumToolDefinitions,
              Set(request.tools.map(\.name)).count == request.tools.count else {
            return false
        }
        for tool in request.tools {
            guard validToolName(tool.name),
                  !tool.descriptionText.isEmpty,
                  tool.descriptionText.utf8.count <= 512,
                  tool.parameters.type == "object",
                  tool.parameters.properties.count <= 4,
                  tool.parameters.additionalProperties == false,
                  Set(tool.parameters.required).isSubset(of: Set(tool.parameters.properties.keys)) else {
                return false
            }
        }
        var pendingToolCallIDs = Set<String>()
        var seenToolCallIDs = Set<String>()
        for message in request.messages {
            guard message.content.map({ $0.utf8.count <= ProviderLimits.maximumTurnMessageBytes }) ?? true,
                  message.toolCalls.count <= ProviderLimits.maximumToolCalls else {
                return false
            }
            switch message.role {
            case .system, .user:
                guard pendingToolCallIDs.isEmpty,
                      message.content?.isEmpty == false,
                      message.toolCalls.isEmpty,
                      message.toolCallID == nil else { return false }
            case .assistant:
                guard pendingToolCallIDs.isEmpty,
                      message.toolCallID == nil,
                      message.content?.isEmpty == false || !message.toolCalls.isEmpty else {
                    return false
                }
                var assistantIDs = Set<String>()
                for call in message.toolCalls {
                    guard validIdentifier(call.id, maximumBytes: ProviderLimits.maximumToolCallIDBytes),
                          assistantIDs.insert(call.id).inserted,
                          seenToolCallIDs.insert(call.id).inserted,
                          validToolName(call.name),
                          !call.arguments.isEmpty,
                          call.arguments.utf8.count <= ProviderLimits.maximumToolArgumentsBytes else {
                        return false
                    }
                }
                pendingToolCallIDs = assistantIDs
            case .tool:
                guard message.content?.isEmpty == false,
                      message.toolCalls.isEmpty,
                      let toolCallID = message.toolCallID,
                      validIdentifier(toolCallID, maximumBytes: ProviderLimits.maximumToolCallIDBytes),
                      pendingToolCallIDs.remove(toolCallID) != nil else {
                    return false
                }
            }
        }
        return pendingToolCallIDs.isEmpty
    }

    private func validToolName(_ value: String) -> Bool {
        guard validIdentifier(value, maximumBytes: ProviderLimits.maximumToolNameBytes) else {
            return false
        }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.lowercaseLetters.contains($0)
                || CharacterSet.decimalDigits.contains($0)
                || $0 == "_"
        }
    }

    private func validIdentifier(_ value: String, maximumBytes: Int) -> Bool {
        let count = value.utf8.count
        return count > 0
            && count <= maximumBytes
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    private func finishInferenceFailure(
        _ failure: ProviderFailure,
        category: ProviderAttemptResultCategory,
        requestID: UUID,
        attemptID: UUID,
        toolExchangeDiagnostic: ProviderToolExchangeDiagnostic? = nil
    ) async -> ProviderInferenceOutcome {
        do {
            try await attemptStore.record(evidence(
                requestID: requestID,
                attemptID: attemptID,
                phase: .failed,
                resultCategory: category,
                toolExchangeDiagnostic: toolExchangeDiagnostic
            ))
            return .failure(failure)
        } catch {
            return .failure(.evidenceWriteFailed)
        }
    }

    private func recordInferenceSuccess(
        requestID: UUID,
        attemptID: UUID,
        category: ProviderAttemptResultCategory,
        data: Data,
        toolExchangeDiagnostic: ProviderToolExchangeDiagnostic? = nil
    ) async -> Bool {
        do {
            try await attemptStore.record(evidence(
                requestID: requestID,
                attemptID: attemptID,
                phase: .succeeded,
                resultCategory: category,
                responseByteCount: data.count,
                responseSHA256: ProviderDigest.sha256Hex(data),
                toolExchangeDiagnostic: toolExchangeDiagnostic
            ))
            return true
        } catch {
            return false
        }
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
        responseSHA256: String? = nil,
        toolExchangeDiagnostic: ProviderToolExchangeDiagnostic? = nil
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
            responseSHA256: responseSHA256,
            toolExchangeDiagnostic: toolExchangeDiagnostic
        )
    }
}

private struct OpenAIChatCompletionRequest: Encodable {
    let model: String
    let messages: [OpenAIChatMessage]
    let maxTokens: Int
    let stream: Bool
    let tools: [OpenAIToolDefinitionEnvelope]?
    let toolChoice: String?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case maxTokens = "max_tokens"
        case stream
        case tools
        case toolChoice = "tool_choice"
    }
}

private struct OpenAIChatMessage: Codable {
    let role: String
    let content: String?
    let toolCalls: [OpenAIToolCallEnvelope]?
    let toolCallID: String?

    init(role: String, content: String) {
        self.role = role
        self.content = content
        toolCalls = nil
        toolCallID = nil
    }

    init(_ message: ProviderTurnMessage) {
        role = message.role.rawValue
        content = message.content
        toolCalls = message.toolCalls.isEmpty ? nil : message.toolCalls.map {
            OpenAIToolCallEnvelope(
                id: $0.id,
                type: "function",
                function: OpenAIToolFunction(name: $0.name, arguments: $0.arguments)
            )
        }
        toolCallID = message.toolCallID
    }

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
    }
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
    let toolCalls: [OpenAIResponseToolCallEnvelope]

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCalls = "tool_calls"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(String.self, forKey: .role)
        content = try container.decodeIfPresent(String.self, forKey: .content)
        toolCalls = try container.decodeIfPresent([OpenAIResponseToolCallEnvelope].self, forKey: .toolCalls) ?? []
    }
}

private struct OpenAIToolDefinitionEnvelope: Codable {
    let type: String
    let function: ProviderToolDefinition
}

private struct OpenAIToolCallEnvelope: Codable {
    let id: String
    let type: String
    let function: OpenAIToolFunction
}

private struct OpenAIResponseToolCallEnvelope: Decodable {
    let id: String?
    let type: String?
    let function: OpenAIResponseToolFunction?
}

private struct OpenAIResponseToolFunction: Decodable {
    let name: String?
    let arguments: String?
}

private struct OpenAIToolFunction: Codable {
    let name: String
    let arguments: String
}

private enum OpenAIToolExchangeClassification {
    case toolCalls(
        [ProviderTurnToolCall],
        assistantContent: String?,
        diagnostic: ProviderToolExchangeDiagnostic?
    )
    case finish(String)
    case rejected(ProviderToolExchangeDiagnostic)
}
