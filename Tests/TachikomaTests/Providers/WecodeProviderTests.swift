import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import Tachikoma

#if os(Linux)
@Suite("Wecode Provider Tests", .disabled("URLProtocol mocking unavailable on Linux"))
struct WecodeProviderTests {}
#else

@Suite("Wecode Provider Tests", .serialized)
struct WecodeProviderTests {
    @Test("Wecode provider streams text and tool events")
    func streamTextEmitsDeltas() async throws {
        try await NetworkMocking.withMockedNetwork { request in
            #expect(request.url?.path.hasSuffix("/text/stream") == true)
            let payload = Self.ssePayload(events: [
                Self.streamEvent(type: "text", content: "Hello ", toolCall: nil, usage: nil, finishReason: nil),
                Self.streamEvent(type: "text", content: "world", toolCall: nil, usage: nil, finishReason: nil),
                Self.streamEvent(
                    type: "tool",
                    content: nil,
                    toolCall: [
                        "id": "call_1",
                        "name": "see",
                        "arguments": ["mode": "screen"],
                    ],
                    usage: nil,
                    finishReason: nil
                ),
                Self.streamEvent(
                    type: "done",
                    content: nil,
                    toolCall: nil,
                    usage: ["inputTokens": 4, "outputTokens": 2],
                    finishReason: "stop"
                ),
            ])
            return NetworkMocking.streamResponse(for: request, data: payload)
        } operation: {
            let config = TestHelpers.createTestConfiguration(apiKeys: ["wecode": "test-key"])
            let provider = try WecodeProvider(modelId: "wecode", configuration: config)
            let stream = try await provider.streamText(request: Self.sampleRequest)

            var text = ""
            var toolCalls: [AgentToolCall] = []
            var finishReason: FinishReason?
            var usage: Usage?

            for try await delta in stream {
                switch delta.type {
                case .textDelta:
                    text += delta.content ?? ""
                case .toolCall:
                    if let toolCall = delta.toolCall {
                        toolCalls.append(toolCall)
                    }
                case .done:
                    usage = delta.usage
                    finishReason = delta.finishReason
                case .toolResult, .reasoning:
                    break
                }
            }

            #expect(text == "Hello world")
            #expect(toolCalls.count == 1)
            #expect(toolCalls.first?.name == "see")
            #expect(toolCalls.first?.arguments["mode"]?.stringValue == "screen")
            #expect(finishReason == .toolCalls)
            #expect(usage?.inputTokens == 4)
            #expect(usage?.outputTokens == 2)
        }
    }

    @Test("Wecode provider aggregates streamed output")
    func generateTextAggregatesStream() async throws {
        try await NetworkMocking.withMockedNetwork { request in
            #expect(request.url?.path.hasSuffix("/text/stream") == true)
            let payload = Self.ssePayload(events: [
                Self.streamEvent(type: "text", content: "Hello", toolCall: nil, usage: nil, finishReason: nil),
                Self.streamEvent(type: "text", content: " world", toolCall: nil, usage: nil, finishReason: nil),
                Self.streamEvent(
                    type: "done",
                    content: nil,
                    toolCall: nil,
                    usage: ["inputTokens": 3, "outputTokens": 2],
                    finishReason: "stop"
                ),
            ])
            return NetworkMocking.streamResponse(for: request, data: payload)
        } operation: {
            let config = TestHelpers.createTestConfiguration(apiKeys: ["wecode": "test-key"])
            let provider = try WecodeProvider(modelId: "wecode", configuration: config)
            let response = try await provider.generateText(request: Self.sampleRequest)

            #expect(response.text == "Hello world")
            #expect(response.finishReason == .stop)
            #expect(response.usage?.inputTokens == 3)
            #expect(response.usage?.outputTokens == 2)
        }
    }

    @Test("Wecode provider surfaces stream errors for aggregation")
    func generateTextFailsOnStreamError() async throws {
        try await NetworkMocking.withMockedNetwork { request in
            #expect(request.url?.path.hasSuffix("/text/stream") == true)
            let payload = Self.ssePayload(events: [
                Self.streamEvent(
                    type: "error",
                    content: nil,
                    toolCall: nil,
                    usage: nil,
                    finishReason: nil,
                    error: "stream failed"
                ),
            ])
            return NetworkMocking.streamResponse(for: request, data: payload)
        } operation: {
            let config = TestHelpers.createTestConfiguration(apiKeys: ["wecode": "test-key"])
            let provider = try WecodeProvider(modelId: "wecode", configuration: config)
            await #expect(throws: TachikomaError.self) {
                _ = try await provider.generateText(request: Self.sampleRequest)
            }
        }
    }

    private static var sampleRequest: ProviderRequest {
        ProviderRequest(messages: [ModelMessage(role: .user, content: [.text("hello")])])
    }

    private static func ssePayload(events: [String]) -> Data {
        var data = Data()
        for event in events {
            data.append("data: ".utf8Data())
            data.append(event.utf8Data())
            data.append("\n\n".utf8Data())
        }
        data.append("data: [DONE]\n\n".utf8Data())
        return data
    }

    private static func streamEvent(
        type: String,
        content: String?,
        toolCall: [String: Any]?,
        usage: [String: Any]?,
        finishReason: String?,
        error: String? = nil
    ) -> String {
        var payload: [String: Any] = ["type": type]
        if let content {
            payload["content"] = content
        }
        if let toolCall {
            payload["toolCall"] = toolCall
        }
        if let usage {
            payload["usage"] = usage
        }
        if let finishReason {
            payload["finishReason"] = finishReason
        }
        if let error {
            payload["error"] = error
        }

        let data = try! JSONSerialization.data(withJSONObject: payload)
        return String(data: data, encoding: .utf8)!
    }
}
#endif
