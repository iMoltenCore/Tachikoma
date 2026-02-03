import Foundation

struct WecodeStreamParser {
    private let onText: (String) -> Void
    private let onToolCall: (AgentToolCall) -> Void
    private(set) var usage: Usage?
    private(set) var finishReason: FinishReason?
    private(set) var sawToolCall: Bool = false

    init(
        onText: @escaping (String) -> Void,
        onToolCall: @escaping (AgentToolCall) -> Void
    ) {
        self.onText = onText
        self.onToolCall = onToolCall
    }

    mutating func feed(line: String) throws {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return }
        let payload = trimmed.dropFirst(5).drop { $0 == " " }
        try self.process(payload: String(payload))
    }

    mutating func feed(data: Data) throws {
        guard let body = String(data: data, encoding: .utf8) else {
            return
        }
        let lines = body.components(separatedBy: .newlines)
        for line in lines {
            try self.feed(line: line)
        }
    }

    mutating func finish() {}

    mutating func process(payload: String) throws {
        guard payload != "[DONE]" else { return }
        guard let data = payload.data(using: .utf8) else { return }
        let event = try JSONDecoder().decode(WecodeStreamEvent.self, from: data)

        switch event.type.lowercased() {
        case "text":
            if let content = event.content, !content.isEmpty {
                self.onText(content)
            }
        case "tool":
            if let toolCall = event.toolCall?.asAgentToolCall() {
                self.sawToolCall = true
                self.onToolCall(toolCall)
            }
        case "done":
            self.finishReason = Self.mapFinishReason(event.finishReason)
            self.usage = event.usage?.asUsage()
        case "error":
            let message = event.error ?? "Wecode stream error"
            throw TachikomaError.apiError(message)
        default:
            break
        }
    }

    func makeDoneDelta() -> TextStreamDelta {
        let finalReason: FinishReason? = if self.sawToolCall { .toolCalls } else { self.finishReason }
        return TextStreamDelta.done(usage: self.usage, finishReason: finalReason)
    }

    private static func mapFinishReason(_ reason: String?) -> FinishReason? {
        guard let reason else { return nil }
        switch reason.lowercased() {
        case "stop":
            return .stop
        case "length", "max_tokens":
            return .length
        case "tool_calls", "toolcalls":
            return .toolCalls
        case "content_filter":
            return .contentFilter
        case "error":
            return .error
        case "cancelled", "canceled":
            return .cancelled
        default:
            return .other
        }
    }
}
