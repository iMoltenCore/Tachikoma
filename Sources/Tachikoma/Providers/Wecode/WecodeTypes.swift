import Foundation

// MARK: - Request/Response Types

struct WecodeTextRequest: Encodable {
    let prompt: String
    let stream: Bool?
    let model: String?
    let options: Options?
    let tools: [WecodeTool]?

    struct Options: Encodable {
        let temperature: Double?
        let maxTokens: Int?
        let topP: Double?
        let topK: Int?

        enum CodingKeys: String, CodingKey {
            case temperature
            case maxTokens = "max_tokens"
            case topP = "top_p"
            case topK = "top_k"
        }
    }
}

struct WecodeTool: Encodable {
    let name: String
    let description: String
    let parameters: [String: Any]

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        try container.encode(self.name, forKey: DynamicCodingKey(stringValue: "name")!)
        try container.encode(self.description, forKey: DynamicCodingKey(stringValue: "description")!)

        var paramsContainer = container.nestedContainer(
            keyedBy: DynamicCodingKey.self,
            forKey: DynamicCodingKey(stringValue: "parameters")!
        )
        try encodeAnyValue(self.parameters, to: &paramsContainer)
    }
}

struct WecodeStreamEvent: Decodable {
    let type: String
    let content: String?
    let toolCall: WecodeToolCall?
    let usage: WecodeUsage?
    let finishReason: String?
    let error: String?
}

struct WecodeUsage: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?
    let totalTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens
        case outputTokens
        case totalTokens
        case inputTokensSnake = "input_tokens"
        case outputTokensSnake = "output_tokens"
        case totalTokensSnake = "total_tokens"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let input = try container.decodeIfPresent(Int.self, forKey: .inputTokens)
            ?? container.decodeIfPresent(Int.self, forKey: .inputTokensSnake)
        let output = try container.decodeIfPresent(Int.self, forKey: .outputTokens)
            ?? container.decodeIfPresent(Int.self, forKey: .outputTokensSnake)
        let total = try container.decodeIfPresent(Int.self, forKey: .totalTokens)
            ?? container.decodeIfPresent(Int.self, forKey: .totalTokensSnake)

        self.inputTokens = input
        self.outputTokens = output
        self.totalTokens = total
    }

    func asUsage() -> Usage? {
        let input = self.inputTokens ?? 0
        let output = self.outputTokens ?? max(0, (self.totalTokens ?? 0) - input)
        if input == 0, output == 0, self.totalTokens == nil { return nil }
        return Usage(inputTokens: input, outputTokens: output)
    }
}

struct WecodeToolCall: Decodable {
    let id: String?
    let name: String
    let arguments: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case arguments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)

        if let args = try? container.decode([String: JSONValue].self, forKey: .arguments) {
            self.arguments = args
            return
        }

        if let raw = try? container.decode(String.self, forKey: .arguments) {
            self.arguments = Self.decodeArguments(from: raw)
            return
        }

        self.arguments = nil
    }

    func asAgentToolCall() -> AgentToolCall? {
        var parsedArguments: [String: AnyAgentToolValue] = [:]
        for (key, value) in self.arguments ?? [:] {
            do {
                parsedArguments[key] = try AnyAgentToolValue.fromJSON(value.value)
            } catch {
                continue
            }
        }

        return AgentToolCall(
            id: self.id ?? UUID().uuidString,
            name: self.name,
            arguments: parsedArguments
        )
    }

    private static func decodeArguments(from raw: String) -> [String: JSONValue]? {
        guard let data = raw.data(using: .utf8) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json.compactMapValues { JSONValue(value: $0) }
    }
}
