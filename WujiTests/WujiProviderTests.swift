import Foundation
import XCTest
@testable import Wuji

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class WujiProviderTests: XCTestCase {
    private let apiKey = "s2-test-key-never-persist"
    private let model = "deepseek-test"
    private let diagnosticResponseText = "diagnostic-response-text-never-persist"
    private let diagnosticID = "diagnostic-call-id-never-persist"
    private let diagnosticArguments = "{\"path\":\"diagnostic-arguments-never-persist\"}"

    override func tearDown() {
        S2MockURLProtocol.handler = nil
        super.tearDown()
    }

    func testEndpointValidationAndSafePathJoining() throws {
        XCTAssertEqual(
            try DeepSeekEndpoint(baseURL: "https://relay.example/v1/").chatCompletionsURL.absoluteString,
            "https://relay.example/v1/chat/completions"
        )
        XCTAssertEqual(
            try DeepSeekEndpoint(baseURL: "https://relay.example/v1/chat/completions").chatCompletionsURL.absoluteString,
            "https://relay.example/v1/chat/completions"
        )

        for rejected in [
            "http://relay.example/v1",
            "https://user:password@relay.example/v1",
            "https://relay.example/v1#fragment",
            "https://relay.example/v1?token=value",
            "https://relay.example/v1%2fescape"
        ] {
            XCTAssertThrowsError(try DeepSeekEndpoint(baseURL: rejected), rejected)
        }
    }

    func testURLProtocolCoversEndpointHeaderBodyAndSecretExclusion() async throws {
        let capture = URLRequestCapture()
        S2MockURLProtocol.handler = { request in
            capture.store(request)
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                self.responseBody(content: "bounded response")
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [S2MockURLProtocol.self]
        let transport = URLSessionProviderTransport(configuration: configuration)
        let directory = temporaryDirectory()
        let store = try FileProviderAttemptStore(directoryURL: directory)
        let credential = try ProviderCredential(apiKey)
        let provider = try DeepSeekProvider(
            baseURL: "https://relay.example/v1",
            model: model,
            credentialSource: StaticProviderCredentialSource(credential: credential),
            transport: transport,
            attemptStore: store,
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        let prompt = "fixed non-sensitive prompt"

        let outcome = await provider.complete(prompt: prompt, requestID: UUID())
        guard case let .response(completion) = outcome else {
            return XCTFail("expected response, got \(outcome)")
        }
        XCTAssertEqual(completion.text, "bounded response")
        XCTAssertFalse(String(describing: outcome).contains("bounded response"))

        let request = try XCTUnwrap(capture.request)
        XCTAssertEqual(request.url?.absoluteString, "https://relay.example/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(apiKey)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(capture.body)
        XCTAssertFalse(body.contains(Data(apiKey.utf8)))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, model)
        XCTAssertEqual(object["stream"] as? Bool, false)
        XCTAssertEqual(object["max_tokens"] as? Int, 64)

        let durableData = try Data(contentsOf: directory.appendingPathComponent("provider-attempts.jsonl"))
        let durableText = String(decoding: durableData, as: UTF8.self)
        XCTAssertFalse(durableText.contains(apiKey))
        XCTAssertFalse(durableText.contains(prompt))
        XCTAssertFalse(durableText.contains("bounded response"))
        XCTAssertTrue(durableText.contains("intent_recorded"))
        XCTAssertTrue(durableText.contains("succeeded"))
        XCTAssertFalse(String(describing: credential).contains(apiKey))
        XCTAssertFalse(String(describing: ProviderHTTPRequest(
            url: request.url!,
            headers: ["Authorization": "Bearer \(apiKey)"],
            body: body,
            timeout: 1
        )).contains(apiKey))
    }

    func testHTTPErrorIsProviderFailureWithoutBodyDisclosure() async throws {
        let body = Data("{\"error\":\"\(apiKey)\"}".utf8)
        let transport = MockProviderTransport(mode: .response(
            ProviderHTTPResponse(statusCode: 503, body: body)
        ))
        let store = RecordingAttemptStore()
        let provider = try makeProvider(transport: transport, store: store)

        let outcome = await provider.complete(prompt: "hello", requestID: UUID())

        XCTAssertEqual(outcome, .failure(.httpStatus(503)))
        XCTAssertFalse(String(describing: outcome).contains(apiKey))
        let sendCount = await transport.sendCount
        XCTAssertEqual(sendCount, 1)
    }

    func testMalformedAndEmptyResponsesAreRejected() async throws {
        let malformed = MockProviderTransport(mode: .response(
            ProviderHTTPResponse(statusCode: 200, body: Data("not-json".utf8))
        ))
        let malformedProvider = try makeProvider(
            transport: malformed,
            store: RecordingAttemptStore()
        )
        let malformedOutcome = await malformedProvider.complete(prompt: "hello", requestID: UUID())
        XCTAssertEqual(malformedOutcome, .failure(.malformedResponse))

        let empty = MockProviderTransport(mode: .response(
            ProviderHTTPResponse(statusCode: 200, body: Data())
        ))
        let emptyProvider = try makeProvider(
            transport: empty,
            store: RecordingAttemptStore()
        )
        let emptyOutcome = await emptyProvider.complete(prompt: "hello", requestID: UUID())
        XCTAssertEqual(emptyOutcome, .failure(.emptyResponse))
    }

    func testBodyAndOutputLimitsAreEnforced() async throws {
        S2MockURLProtocol.handler = { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Length": "512"]
                )!,
                Data(repeating: 0x41, count: 512)
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [S2MockURLProtocol.self]
        let boundedTransport = URLSessionProviderTransport(
            configuration: configuration,
            maximumResponseBytes: 128
        )
        let bodyProvider = try makeProvider(
            transport: boundedTransport,
            store: RecordingAttemptStore()
        )
        let bodyOutcome = await bodyProvider.complete(prompt: "hello", requestID: UUID())
        XCTAssertEqual(bodyOutcome, .failure(.responseTooLarge))

        let oversizedOutput = String(
            repeating: "x",
            count: ProviderLimits.maximumOutputBytes + 1
        )
        let outputTransport = MockProviderTransport(mode: .response(
            ProviderHTTPResponse(statusCode: 200, body: responseBody(content: oversizedOutput))
        ))
        let outputProvider = try makeProvider(
            transport: outputTransport,
            store: RecordingAttemptStore()
        )
        let outputOutcome = await outputProvider.complete(prompt: "hello", requestID: UUID())
        XCTAssertEqual(outputOutcome, .failure(.responseTooLarge))
    }

    func testToolCallsAreRejected() async throws {
        let body = Data("""
        {"id":"response-id","choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call-1","type":"function","function":{"name":"shell","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}
        """.utf8)
        let transport = MockProviderTransport(mode: .response(
            ProviderHTTPResponse(statusCode: 200, body: body)
        ))
        let provider = try makeProvider(
            transport: transport,
            store: RecordingAttemptStore()
        )

        let outcome = await provider.complete(prompt: "hello", requestID: UUID())
        XCTAssertEqual(outcome, .failure(.toolCallsRejected))
    }

    func testStructuredToolExchangeUsesTypedCallsRegardlessOfFinishReasonMetadata() async throws {
        let capture = URLRequestCapture()
        S2MockURLProtocol.handler = { request in
            capture.store(request)
            let body = Data("""
            {"id":"turn-id","choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call-list","type":"function","function":{"name":"list","arguments":"{\\\"path\\\":\\\"\\\"}"}}]},"finish_reason":"stop"}]}
            """.utf8)
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                body
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [S2MockURLProtocol.self]
        let directory = temporaryDirectory()
        let provider = try DeepSeekProvider(
            baseURL: "https://relay.example/v1",
            model: model,
            credentialSource: StaticProviderCredentialSource(
                credential: try ProviderCredential(apiKey)
            ),
            transport: URLSessionProviderTransport(configuration: configuration),
            attemptStore: try FileProviderAttemptStore(directoryURL: directory),
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        let request = ProviderInferenceRequest(
            messages: [
                ProviderTurnMessage(role: .system, content: "fixed system"),
                ProviderTurnMessage(role: .user, content: "fixed goal")
            ],
            tools: S3ToolPolicy.toolDefinitions,
            requireTool: true
        )

        let outcome = await provider.infer(request: request, requestID: UUID())

        guard case let .decision(.toolCall(assistant, call)) = outcome else {
            return XCTFail("expected typed tool call, got \(outcome)")
        }
        XCTAssertEqual(call.id, "call-list")
        XCTAssertEqual(call.name, "list")
        XCTAssertEqual(call.arguments, "{\"path\":\"\"}")
        XCTAssertEqual(assistant.toolCalls, [call])
        XCTAssertFalse(String(describing: outcome).contains(call.arguments))

        let captured = try XCTUnwrap(capture.request)
        XCTAssertEqual(captured.value(forHTTPHeaderField: "Authorization"), "Bearer \(apiKey)")
        let requestBody = try XCTUnwrap(capture.body)
        XCTAssertFalse(requestBody.contains(Data(apiKey.utf8)))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        XCTAssertNil(object["tool_choice"])
        XCTAssertEqual((object["tools"] as? [[String: Any]])?.count, 3)
        XCTAssertEqual((object["messages"] as? [[String: Any]])?.map { $0["role"] as? String }, ["system", "user"])

        let durable = try Data(contentsOf: directory.appendingPathComponent("provider-attempts.jsonl"))
        XCTAssertFalse(durable.contains(Data(apiKey.utf8)))
        XCTAssertFalse(durable.contains(Data(call.arguments.utf8)))
    }

    func testDiagnosticReasonNoToolCallsWithInvalidFinishOrContent() async throws {
        let diagnostic = try await assertRejectedToolExchange(
            body: diagnosticResponseBody(toolCalls: [], finishReason: "length"),
            reason: .noToolCallsWithInvalidFinishOrContent,
            toolNameValue: ""
        )
        XCTAssertEqual(diagnostic.toolCallCount, 0)
        XCTAssertTrue(diagnostic.assistantContentPresent)
        XCTAssertEqual(diagnostic.assistantContentByteCount, diagnosticResponseText.utf8.count)
    }

    func testDiagnosticReasonToolCallCount() async throws {
        let diagnostic = try await assertRejectedToolExchange(
            body: diagnosticResponseBody(toolCalls: [diagnosticToolCall(), diagnosticToolCall()]),
            reason: .toolCallCount,
            toolNameValue: "list"
        )
        XCTAssertEqual(diagnostic.toolCallCount, ProviderLimits.maximumToolCalls + 1)
    }

    func testDiagnosticReasonEnvelopeType() async throws {
        let diagnostic = try await assertRejectedToolExchange(
            body: diagnosticResponseBody(toolCalls: [diagnosticToolCall(type: "not_function")]),
            reason: .envelopeType,
            toolNameValue: "list"
        )
        XCTAssertFalse(diagnostic.envelopeTypeIsFunction)
    }

    func testDiagnosticReasonIDMissingOrInvalid() async throws {
        let diagnostic = try await assertRejectedToolExchange(
            body: diagnosticResponseBody(toolCalls: [diagnosticToolCall(id: nil)]),
            reason: .idMissingOrInvalid,
            toolNameValue: "list"
        )
        XCTAssertFalse(diagnostic.toolCallIDPresent)
        XCTAssertEqual(diagnostic.toolCallIDByteCount, 0)
    }

    func testDiagnosticReasonToolNameMissingOrInvalid() async throws {
        let diagnostic = try await assertRejectedToolExchange(
            body: diagnosticResponseBody(toolCalls: [diagnosticToolCall(name: nil)]),
            reason: .toolNameMissingOrInvalid,
            toolNameValue: ""
        )
        XCTAssertFalse(diagnostic.toolNamePresent)
        XCTAssertEqual(diagnostic.toolNameByteCount, 0)
    }

    func testDiagnosticReasonToolNameNotAllowed() async throws {
        let toolName = "network"
        let transport = MockProviderTransport(mode: .response(
            ProviderHTTPResponse(
                statusCode: 200,
                body: diagnosticResponseBody(toolCalls: [diagnosticToolCall(name: toolName)])
            )
        ))
        let store = RecordingAttemptStore()
        let provider = try makeProvider(transport: transport, store: store)
        let request = ProviderInferenceRequest(
            messages: [
                ProviderTurnMessage(role: .system, content: "fixed system"),
                ProviderTurnMessage(role: .user, content: "fixed goal")
            ],
            tools: S3ToolPolicy.toolDefinitions,
            requireTool: true
        )

        let outcome = await provider.infer(request: request, requestID: UUID())

        guard case let .decision(.toolCall(_, call)) = outcome else {
            return XCTFail("expected typed tool decision")
        }
        XCTAssertEqual(call.name, toolName)
        let sendCount = await transport.sendCount
        XCTAssertEqual(sendCount, 1)
        let records = await store.records
        XCTAssertEqual(records.map(\.phase), [.intentRecorded, .succeeded])
        XCTAssertEqual(records.last?.resultCategory, .toolCall)
        let diagnostic = try XCTUnwrap(records.last?.toolExchangeDiagnostic)
        XCTAssertEqual(diagnostic.reason, .toolNameNotAllowed)
        XCTAssertTrue(diagnostic.toolNamePresent)
        XCTAssertEqual(diagnostic.toolNameByteCount, toolName.utf8.count)

        let workspaceRoot = temporaryDirectory()
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceRoot) }
        let policy = S3ToolPolicy(workspace: try S3ApprovedWorkspace(rootURL: workspaceRoot))
        XCTAssertThrowsError(try policy.authorize(call)) { error in
            XCTAssertEqual(error as? S3PolicyError, .unknownTool)
        }

        let encoded = try JSONEncoder().encode(records)
        let durableText = String(decoding: encoded, as: UTF8.self)
        let descriptionText = String(describing: records)
        for value in [
            apiKey,
            diagnosticResponseText,
            "diagnostic-response-id-never-persist",
            diagnosticID,
            toolName,
            diagnosticArguments
        ] {
            XCTAssertFalse(durableText.contains(value), "forbidden durable value present")
            XCTAssertFalse(descriptionText.contains(value), "forbidden diagnostic value present")
        }
    }

    func testDiagnosticReasonArgumentsMissing() async throws {
        let diagnostic = try await assertRejectedToolExchange(
            body: diagnosticResponseBody(toolCalls: [diagnosticToolCall(arguments: nil)]),
            reason: .argumentsMissing,
            toolNameValue: "list"
        )
        XCTAssertFalse(diagnostic.argumentsPresent)
        XCTAssertEqual(diagnostic.argumentsByteCount, 0)
    }

    func testDiagnosticReasonArgumentsTooLarge() async throws {
        let oversized = diagnosticArguments
            + String(repeating: "x", count: ProviderLimits.maximumToolArgumentsBytes + 1)
        let diagnostic = try await assertRejectedToolExchange(
            body: diagnosticResponseBody(toolCalls: [diagnosticToolCall(arguments: oversized)]),
            reason: .argumentsTooLarge,
            toolNameValue: "list",
            argumentsValue: oversized
        )
        XCTAssertTrue(diagnostic.argumentsPresent)
        XCTAssertEqual(diagnostic.argumentsByteCount, ProviderLimits.maximumToolArgumentsBytes + 1)
    }

    func testDiagnosticReasonAssistantContentTooLarge() async throws {
        let oversized = diagnosticResponseText
            + String(repeating: "x", count: ProviderLimits.maximumOutputBytes + 1)
        let diagnostic = try await assertRejectedToolExchange(
            body: diagnosticResponseBody(
                toolCalls: [diagnosticToolCall()],
                content: oversized
            ),
            reason: .assistantContentTooLarge,
            toolNameValue: "list",
            responseTextValue: oversized
        )
        XCTAssertTrue(diagnostic.assistantContentPresent)
        XCTAssertEqual(diagnostic.assistantContentByteCount, ProviderLimits.maximumOutputBytes + 1)
    }

    func testUncertainTransportResultRequiresReconciliationAndNeverRetries() async throws {
        let transport = MockProviderTransport(mode: .networkFailure)
        let store = RecordingAttemptStore()
        let provider = try makeProvider(transport: transport, store: store)

        let outcome = await provider.complete(prompt: "hello", requestID: UUID())

        XCTAssertEqual(outcome, .unknown(.reconciliationRequired))
        let sendCount = await transport.sendCount
        XCTAssertEqual(sendCount, 1)
        let records = await store.records
        XCTAssertEqual(records.map(\.phase), [.intentRecorded, .reconciliationRequired])
        XCTAssertEqual(records.last?.resultCategory, .transportUnknown)
    }

    func testDurableIntentIsWrittenBeforeNetworkIO() async throws {
        let events = OrderedEventRecorder()
        let store = RecordingAttemptStore(events: events)
        let transport = MockProviderTransport(
            mode: .response(ProviderHTTPResponse(
                statusCode: 200,
                body: responseBody(content: "ok")
            )),
            events: events
        )
        let provider = try makeProvider(transport: transport, store: store)

        _ = await provider.complete(prompt: "hello", requestID: UUID())

        let orderedEvents = await events.values
        XCTAssertEqual(Array(orderedEvents.prefix(2)), ["store:intent_recorded", "network"])
    }

    func testProviderBoundaryIsReplaceable() async {
        let provider: CloudProvider = ReplacementCloudProvider()
        let outcome = await provider.complete(prompt: "ignored", requestID: UUID())

        guard case let .response(completion) = outcome else {
            return XCTFail("replacement provider did not satisfy boundary")
        }
        XCTAssertEqual(provider.providerID, "replacement")
        XCTAssertEqual(completion.text, "replacement response")
    }

    private func makeProvider(
        transport: ProviderTransport,
        store: ProviderAttemptRecording
    ) throws -> DeepSeekProvider {
        try DeepSeekProvider(
            baseURL: "https://relay.example/v1",
            model: model,
            credentialSource: StaticProviderCredentialSource(
                credential: try ProviderCredential(apiKey)
            ),
            transport: transport,
            attemptStore: store,
            now: { Date(timeIntervalSince1970: 1_000) }
        )
    }

    private func assertRejectedToolExchange(
        body: Data,
        reason: ProviderToolExchangeRejectionReason,
        toolNameValue: String,
        argumentsValue: String? = nil,
        responseTextValue: String? = nil
    ) async throws -> ProviderToolExchangeDiagnostic {
        let transport = MockProviderTransport(mode: .response(
            ProviderHTTPResponse(statusCode: 200, body: body)
        ))
        let store = RecordingAttemptStore()
        let provider = try makeProvider(transport: transport, store: store)
        let request = ProviderInferenceRequest(
            messages: [
                ProviderTurnMessage(role: .system, content: "fixed system"),
                ProviderTurnMessage(role: .user, content: "fixed goal")
            ],
            tools: S3ToolPolicy.toolDefinitions,
            requireTool: true
        )

        let outcome = await provider.infer(request: request, requestID: UUID())

        XCTAssertEqual(outcome, .failure(.invalidToolExchange))
        let sendCount = await transport.sendCount
        XCTAssertEqual(sendCount, 1)
        let records = await store.records
        XCTAssertEqual(records.map(\.phase), [.intentRecorded, .failed])
        XCTAssertEqual(records.last?.resultCategory, .invalidToolExchange)
        let diagnostic = try XCTUnwrap(records.last?.toolExchangeDiagnostic)
        XCTAssertEqual(diagnostic.reason, reason)

        let encoded = try JSONEncoder().encode(records)
        let durableText = String(decoding: encoded, as: UTF8.self)
        let descriptionText = String(describing: records)
        let forbidden = [
            apiKey,
            responseTextValue ?? diagnosticResponseText,
            "diagnostic-response-id-never-persist",
            diagnosticID,
            toolNameValue,
            argumentsValue ?? diagnosticArguments
        ].filter { !$0.isEmpty }
        for value in forbidden {
            XCTAssertFalse(durableText.contains(value), "forbidden durable value present")
            XCTAssertFalse(descriptionText.contains(value), "forbidden diagnostic value present")
        }
        return diagnostic
    }

    private func diagnosticToolCall(
        id: String? = "diagnostic-call-id-never-persist",
        type: String? = "function",
        name: String? = "list",
        arguments: String? = "{\"path\":\"diagnostic-arguments-never-persist\"}"
    ) -> [String: Any] {
        var function: [String: Any] = [:]
        if let name { function["name"] = name }
        if let arguments { function["arguments"] = arguments }
        var call: [String: Any] = ["function": function]
        if let id { call["id"] = id }
        if let type { call["type"] = type }
        return call
    }

    private func diagnosticResponseBody(
        toolCalls: [[String: Any]],
        content: Any? = nil,
        finishReason: String = "tool_calls"
    ) -> Data {
        let message: [String: Any] = [
            "role": "assistant",
            "content": content ?? diagnosticResponseText,
            "tool_calls": toolCalls
        ]
        let object: [String: Any] = [
            "id": "diagnostic-response-id-never-persist",
            "choices": [[
                "index": 0,
                "message": message,
                "finish_reason": finishReason
            ]]
        ]
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func responseBody(content: String) -> Data {
        let object: [String: Any] = [
            "id": "response-id",
            "choices": [[
                "index": 0,
                "message": [
                    "role": "assistant",
                    "content": content,
                    "tool_calls": []
                ],
                "finish_reason": "stop"
            ]]
        ]
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("WujiProviderTests-\(UUID().uuidString)", isDirectory: true)
    }
}

private final class URLRequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequest: URLRequest?
    private var storedBody: Data?

    var request: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return storedRequest
    }

    var body: Data? {
        lock.lock()
        defer { lock.unlock() }
        return storedBody
    }

    func store(_ request: URLRequest) {
        lock.lock()
        storedRequest = request
        storedBody = request.httpBody ?? Self.readBodyStream(request.httpBodyStream)
        lock.unlock()
    }

    private static func readBodyStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { return nil }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
}

private final class S2MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: ProviderTransportError.network)
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private actor OrderedEventRecorder {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}

private actor RecordingAttemptStore: ProviderAttemptRecording {
    private(set) var records: [ProviderAttemptEvidence] = []
    private let events: OrderedEventRecorder?

    init(events: OrderedEventRecorder? = nil) {
        self.events = events
    }

    func record(_ evidence: ProviderAttemptEvidence) async throws {
        records.append(evidence)
        await events?.append("store:\(evidence.phase.rawValue)")
    }
}

private actor MockProviderTransport: ProviderTransport {
    enum Mode: Sendable {
        case response(ProviderHTTPResponse)
        case networkFailure
    }

    private(set) var sendCount = 0
    private let mode: Mode
    private let events: OrderedEventRecorder?

    init(mode: Mode, events: OrderedEventRecorder? = nil) {
        self.mode = mode
        self.events = events
    }

    func send(_ request: ProviderHTTPRequest) async throws -> ProviderHTTPResponse {
        sendCount += 1
        await events?.append("network")
        switch mode {
        case let .response(response):
            return response
        case .networkFailure:
            throw ProviderTransportError.network
        }
    }
}

private struct ReplacementCloudProvider: CloudProvider {
    let providerID = "replacement"

    func complete(prompt: String, requestID: UUID) async -> ProviderOutcome {
        let text = "replacement response"
        return .response(ProviderCompletion(
            requestID: requestID,
            text: text,
            responseByteCount: text.utf8.count,
            responseSHA256: ProviderDigest.sha256Hex(text)
        ))
    }
}
