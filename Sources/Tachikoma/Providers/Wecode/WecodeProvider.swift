import Foundation

/// Provider wrapper for Wecode's OpenAI Responses proxy.
///
/// Notes:
/// - Wecode endpoint only supports streaming responses.
/// - For non-stream callers, this provider uses streaming and joins deltas.
/// - API key is read from WECODE_API_KEY.
@available(
    macOS 13.0,
    iOS 16.0,
    watchOS 9.0,
    tvOS 16.0,
    *
)
public struct WecodeProvider: ModelProvider {
    public let modelId: String
    public let baseURL: String?
    public let apiKey: String?
    public let capabilities: ModelCapabilities
    private let model: LanguageModel.Wecode
    private let openai_provider: OpenAIResponsesProvider
    
    public init(
        model: LanguageModel.Wecode = .gpt52,
        configuration: TachikomaConfiguration,
        apiKey: String? = nil
    ) throws {
        self.model = model
        // Keep modelId consistent with other providers (provider selection is separate).
        self.modelId = model.modelId
        self.baseURL = configuration.getBaseURL(for: .wecode) ?? "https://api.wecode.zone/openai"

        if let key = configuration.getAPIKey(for: .wecode) {
            self.apiKey = key
        } else {
            throw TachikomaError.authenticationFailed("WECODE_API_KEY not found")
        }


        let openai_config = TachikomaConfiguration(loadFromEnvironment: true)
        // OpenAIResponsesProvider appends "/responses"; normalize baseURL accordingly.
        openai_config.setBaseURL(self.baseURL!, for: .openai)
        // OpenAIResponsesProvider expects the OpenAI provider key in TachikomaConfiguration.
        openai_config.setAPIKey(self.apiKey!, for: .openai)
        self.openai_provider = try OpenAIResponsesProvider(model: self.model.openai, configuration: openai_config)
        
        self.capabilities = self.openai_provider.capabilities
    }

    public func generateText(
        request: ProviderRequest
    ) async throws -> ProviderResponse {
        // The upstream requires streaming. For non-stream callers, stream and join deltas.
        let stream = try await self.streamText(
            request: request
        )
        var text = ""
        for try await delta in stream {
            if delta.type == .textDelta, let content = delta.content {
                text += content
            }
            if delta.type == .done {
                break
            }
        }
        return ProviderResponse(
            text: text
        )
    }

    public func streamText(
        request: ProviderRequest
    ) async throws -> AsyncThrowingStream<
        TextStreamDelta,
        any Error
    > {
        return try await self.openai_provider.streamText(request: request)
    }
}
