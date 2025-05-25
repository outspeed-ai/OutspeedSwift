import Foundation

public enum Provider: String, Sendable {
    case openai
    case outspeed

    public var baseURL: String {
        switch self {
        case .openai:
            return "api.openai.com"
        case .outspeed:
            return "api.outspeed.com"
        }
    }

    public var modelOptions: [String] {
        switch self {
        case .openai:
            return [
                "gpt-4o-mini-realtime-preview-2024-12-17",
                "gpt-4o-realtime-preview-2024-12-17",
            ]
        case .outspeed:
            return ["Orpheus-3b"]
        }
    }

    public var voiceOptions: [String] {
        switch self {
        case .openai:
            return ["alloy", "ash", "ballad", "coral", "echo", "sage", "shimmer", "verse"]
        case .outspeed:
            return OutspeedSDK.OrpheusVoice.allCases.map { $0.rawValue }
        }
    }

    public var defaultModel: String {
        switch self {
        case .openai:
            return "gpt-4o-mini-realtime-preview-2024-12-17"
        case .outspeed:
            return "Orpheus-3b"
        }
    }

    public var defaultVoice: String {
        switch self {
        case .openai:
            return "alloy"
        case .outspeed:
            return OutspeedSDK.OrpheusVoice.default.rawValue
        }
    }

    public var defaultSystemMessage: String {
        switch self {
        case .openai:
            return
                "You are a helpful, witty, and friendly AI. Act like a human. Your voice and personality should be warm and engaging, with a lively and playful tone. Talk quickly."
        case .outspeed:
            return
                "You are a helpful, witty, and friendly AI. Act like a human. Your voice and personality should be warm and engaging, with a lively and playful tone. Talk quickly."
        }
    }
}
