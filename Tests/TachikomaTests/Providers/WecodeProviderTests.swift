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
            #expect(request.url?.path == "/openai/responses")
            let payload = Self.responsesStreamPayload(events: [
                Self.gpt5TextDelta("Hello "),
                Self.gpt5TextDelta("world"),
                Self.gpt5ToolCallAdded(id: "call_1", name: "see"),
                Self.gpt5ToolCallArgumentsDone(id: "call_1", arguments: "{\"mode\":\"screen\"}"),
                Self.gpt5Completed(),
            ])
            return NetworkMocking.streamResponse(for: request, data: payload)
        } operation: {
            let config = TestHelpers.createTestConfiguration(apiKeys: ["wecode": "test-key"])
            let provider = try WecodeProvider(modelId: "wecode", configuration: config)
            let stream = try await provider.streamText(request: Self.sampleRequest)

            var text = ""
            var toolCalls: [AgentToolCall] = []

            for try await delta in stream {
                switch delta.type {
                case .textDelta:
                    text += delta.content ?? ""
                case .toolCall:
                    if let toolCall = delta.toolCall {
                        toolCalls.append(toolCall)
                    }
                case .done, .toolResult, .reasoning:
                    break
                }
            }

            #expect(text == "Hello world")
            #expect(toolCalls.count == 1)
            #expect(toolCalls.first?.name == "see")
            #expect(toolCalls.first?.arguments["mode"]?.stringValue == "screen")
        }
    }

    @Test("Wecode provider aggregates streamed output")
    func generateTextAggregatesStream() async throws {
        try await NetworkMocking.withMockedNetwork { request in
            #expect(request.url?.path == "/openai/responses")
            let payload = Self.responsesStreamPayload(events: [
                Self.gpt5TextDelta("Hello"),
                Self.gpt5TextDelta(" world"),
                Self.gpt5Completed(),
            ])
            return NetworkMocking.streamResponse(for: request, data: payload)
        } operation: {
            let config = TestHelpers.createTestConfiguration(apiKeys: ["wecode": "test-key"])
            let provider = try WecodeProvider(modelId: "wecode", configuration: config)
            let response = try await provider.generateText(request: Self.sampleRequest)

            #expect(response.text == "Hello world")
            #expect(response.finishReason == .stop)
            #expect(response.usage == nil)
        }
    }

    @Test("Wecode provider surfaces stream errors for aggregation")
    func generateTextFailsOnStreamError() async throws {
        try await NetworkMocking.withMockedNetwork { request in
            #expect(request.url?.path == "/openai/responses")
            let payload = Data("{\"error\":{\"message\":\"stream failed\"}}".utf8)
            return NetworkMocking.streamResponse(for: request, data: payload, statusCode: 500)
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

    private static func responsesStreamPayload(events: [String]) -> Data {
        var data = Data()
        for event in events {
            data.append("data: ".utf8Data())
            data.append(event.utf8Data())
            data.append("\n\n".utf8Data())
        }
        data.append("data: [DONE]\n\n".utf8Data())
        return data
    }

    private static func gpt5TextDelta(_ delta: String) -> String {
        let payload: [String: Any] = [
            "type": "response.output_text.delta",
            "delta": delta,
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return String(data: data, encoding: .utf8)!
    }

    private static func gpt5ToolCallAdded(id: String, name: String) -> String {
        let payload: [String: Any] = [
            "type": "response.output_item.added",
            "item": [
                "type": "function_call",
                "id": id,
                "name": name,
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return String(data: data, encoding: .utf8)!
    }

    private static func gpt5ToolCallArgumentsDone(id: String, arguments: String) -> String {
        let payload: [String: Any] = [
            "type": "response.function_call_arguments.done",
            "item_id": id,
            "arguments": arguments,
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return String(data: data, encoding: .utf8)!
    }

    private static func gpt5Completed() -> String {
        let payload: [String: Any] = [
            "type": "response.completed",
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return String(data: data, encoding: .utf8)!
    }
}
#endif
