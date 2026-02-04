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

    private let responsesProvider: OpenAIResponsesProvider

    private static let supportedModelId = "gpt-5.2"

    public init(
        modelId: String,
        configuration: TachikomaConfiguration,
        session: URLSession = .shared
    ) throws {
        let resolvedModelId = try Self.resolveModelId(modelId)
        self.modelId = resolvedModelId
        self.baseURL = configuration.getBaseURL(for: .wecode)

        guard let baseURL else {
            throw TachikomaError.invalidConfiguration("Wecode base URL is missing")
        }

        guard let key = configuration.getAPIKey(for: .wecode) else {
            throw TachikomaError.authenticationFailed("WECODE_API_KEY not found")
        }
        self.apiKey = key

        let openAIConfig = TachikomaConfiguration(loadFromEnvironment: false)
        openAIConfig.setAPIKey(key, for: .openai)
        openAIConfig.setBaseURL(baseURL, for: .openai)
        self.responsesProvider = try OpenAIResponsesProvider(model: .gpt52, configuration: openAIConfig, session: session)

        self.capabilities = self.responsesProvider.capabilities
    }

    public func generateText(request: ProviderRequest) async throws -> ProviderResponse {
        // Wecode only exposes streaming via Responses API, so aggregate stream output.
        let stream = try await self.streamText(request: request)
        var fullText = ""
        var toolCalls: [AgentToolCall] = []

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
            case .done, .toolResult, .reasoning:
                break
            }
        }

        let finishReason: FinishReason = toolCalls.isEmpty ? .stop : .toolCalls
        return ProviderResponse(
            text: fullText,
            usage: nil,
            finishReason: finishReason,
            toolCalls: toolCalls.isEmpty ? nil : toolCalls
        )
    }

    public func streamText(request: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, Error> {
        try await self.responsesProvider.streamText(request: request)
    }

    private static func resolveModelId(_ modelId: String) throws -> String {
        let trimmed = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return Self.supportedModelId
        }
        let normalized = trimmed.lowercased()
        if normalized == "wecode" || normalized == Self.supportedModelId {
            return Self.supportedModelId
        }
        throw TachikomaError.invalidConfiguration("Wecode supports only gpt-5.2")
    }
}
