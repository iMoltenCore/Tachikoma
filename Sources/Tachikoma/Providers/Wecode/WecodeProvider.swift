import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Provider for Wecode streaming text generation.
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public final class WecodeProvider: ModelProvider {
    public let modelId: String
    public let baseURL: String?
    public let apiKey: String?
    public let capabilities: ModelCapabilities

    private let session: URLSession

    public init(
        modelId: String,
        configuration: TachikomaConfiguration,
        session: URLSession = .shared
    ) throws {
        self.modelId = modelId
        self.baseURL = configuration.getBaseURL(for: .wecode)
        self.session = session

        if let key = configuration.getAPIKey(for: .wecode) {
            self.apiKey = key
        } else {
            throw TachikomaError.authenticationFailed("WECODE_API_KEY not found")
        }

        self.capabilities = ModelCapabilities(
            supportsVision: false,
            supportsTools: true,
            supportsStreaming: true,
            contextLength: 128_000,
            maxOutputTokens: 4096,
        )
    }

    public func generateText(request: ProviderRequest) async throws -> ProviderResponse {
        let stream = try await self.streamText(request: request)
        var fullText = ""
        var toolCalls: [AgentToolCall] = []
        var usage: Usage?
        var finishReason: FinishReason = .stop

        for try await delta in stream {
            switch delta.type {
            case .textDelta:
                if let content = delta.content {
                    fullText += content
                }
            case .toolCall:
                if let toolCall = delta.toolCall {
                    toolCalls.append(toolCall)
                }
            case .done:
                usage = delta.usage
                finishReason = delta.finishReason ?? .stop
            case .toolResult, .reasoning:
                break
            }
        }

        if !toolCalls.isEmpty {
            finishReason = .toolCalls
        }

        return ProviderResponse(
            text: fullText,
            usage: usage,
            finishReason: finishReason,
            toolCalls: toolCalls.isEmpty ? nil : toolCalls
        )
    }

    public func streamText(request: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, Error> {
        let urlRequest = try self.makeRequest(for: request, streaming: true)
        let session = self.session

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    #if canImport(FoundationNetworking)
                    let (data, response) = try await session.data(for: urlRequest)
                    let httpResponse = try self.httpResponse(response)
                    guard 200..<300 ~= httpResponse.statusCode else {
                        let body = String(data: data, encoding: .utf8) ?? ""
                        throw TachikomaError.apiError(
                            "Wecode API request failed (HTTP \(httpResponse.statusCode)): \(body)")
                    }

                    var parser = WecodeStreamParser(
                        onText: { continuation.yield(TextStreamDelta.text($0)) },
                        onToolCall: { continuation.yield(TextStreamDelta.tool($0)) }
                    )
                    try parser.feed(data: data)
                    continuation.yield(parser.makeDoneDelta())
                    #else
                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    let httpResponse = try self.httpResponse(response)
                    guard 200..<300 ~= httpResponse.statusCode else {
                        var errorBody = ""
                        for try await line in bytes.lines {
                            errorBody += line
                            if errorBody.count >= 512 { break }
                        }
                        let message = errorBody.isEmpty ? "Unknown error" : errorBody
                        throw TachikomaError.apiError(
                            "Wecode API request failed (HTTP \(httpResponse.statusCode)): \(message)")
                    }

                    var parser = WecodeStreamParser(
                        onText: { continuation.yield(TextStreamDelta.text($0)) },
                        onToolCall: { continuation.yield(TextStreamDelta.tool($0)) }
                    )
                    for try await line in bytes.lines {
                        try parser.feed(line: line)
                    }
                    parser.finish()
                    continuation.yield(parser.makeDoneDelta())
                    #endif

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func makeRequest(for request: ProviderRequest, streaming: Bool) throws -> URLRequest {
        guard let baseURL else {
            throw TachikomaError.invalidConfiguration("Wecode base URL is missing")
        }
        guard let apiKey else {
            throw TachikomaError.authenticationFailed("WECODE_API_KEY not found")
        }

        let endpoint = streaming ? "/text/stream" : "/text"
        let normalizedBaseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: "\(normalizedBaseURL)\(endpoint)") else {
            throw TachikomaError.invalidConfiguration("Invalid Wecode base URL")
        }

        let body = try self.buildRequestBody(request, streaming: streaming)
        let encodedBody = try JSONEncoder().encode(body)

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = encodedBody
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if streaming {
            urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        }

        return urlRequest
    }

    private func buildRequestBody(_ request: ProviderRequest, streaming: Bool) throws -> WecodeTextRequest {
        let prompt = Self.renderPrompt(from: request.messages)
        let options = WecodeTextRequest.Options(
            temperature: request.settings.temperature,
            maxTokens: request.settings.maxTokens,
            topP: request.settings.topP,
            topK: request.settings.topK
        )
        let tools = try Self.convertTools(request.tools)

        return WecodeTextRequest(
            prompt: prompt,
            stream: streaming,
            model: self.modelId,
            options: options,
            tools: tools
        )
    }

    private static func renderPrompt(from messages: [ModelMessage]) -> String {
        let parts = messages.compactMap { message -> String? in
            let text = message.content.compactMap { content -> String? in
                switch content {
                case let .text(text):
                    return text
                case let .toolResult(result):
                    return Self.convertToolResultToString(result.result)
                default:
                    return nil
                }
            }.joined(separator: "\n")

            guard !text.isEmpty else { return nil }
            return "\(message.role.rawValue): \(text)"
        }

        return parts.joined(separator: "\n")
    }

    private static func convertTools(_ tools: [AgentTool]?) throws -> [WecodeTool]? {
        guard let tools, !tools.isEmpty else { return nil }
        return try tools.map(Self.convertTool)
    }

    private static func convertTool(_ tool: AgentTool) throws -> WecodeTool {
        var parameters: [String: Any] = [
            "type": "object",
            "properties": [:],
        ]

        var properties: [String: Any] = [:]
        for (key, prop) in tool.parameters.properties {
            var propDict: [String: Any] = [
                "type": prop.type.rawValue,
                "description": prop.description,
            ]
            if let enumValues = prop.enumValues {
                propDict["enum"] = enumValues
            }
            if let items = prop.items {
                var itemsDict: [String: Any] = ["type": items.type]
                if let itemDescription = items.description {
                    itemsDict["description"] = itemDescription
                }
                propDict["items"] = itemsDict
            }
            properties[key] = propDict
        }
        parameters["properties"] = properties

        if !tool.parameters.required.isEmpty {
            parameters["required"] = tool.parameters.required
        }

        return WecodeTool(
            name: tool.name,
            description: tool.description,
            parameters: parameters
        )
    }

    private func httpResponse(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TachikomaError.networkError(NSError(domain: "WecodeProvider", code: -1))
        }
        return httpResponse
    }

    private static func convertToolResultToString(_ result: AnyAgentToolValue) -> String {
        if result.isNull {
            return "null"
        } else if let value = result.boolValue {
            return String(value)
        } else if let value = result.intValue {
            return String(value)
        } else if let value = result.doubleValue {
            return String(value)
        } else if let value = result.stringValue {
            return value
        } else if let array = result.arrayValue {
            if
                let data = try? JSONEncoder().encode(array),
                let jsonString = String(data: data, encoding: .utf8)
            {
                return jsonString
            }
            return "[]"
        } else if let dict = result.objectValue {
            if
                let data = try? JSONEncoder().encode(dict),
                let jsonString = String(data: data, encoding: .utf8)
            {
                return jsonString
            }
            return "{}"
        } else {
            return "unknown"
        }
    }
}
