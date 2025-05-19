import Foundation

enum Provider: String {
    case openai
    case outspeed
    
    var baseURL: String {
        switch self {
        case .openai:
            return "api.openai.com"
        case .outspeed:
            return "api.outspeed.com"
        }
    }
    
    var modelOptions: [String] {
        switch self {
        case .openai:
            return [
                "gpt-4o-mini-realtime-preview-2024-12-17",
                "gpt-4o-realtime-preview-2024-12-17"
            ]
        case .outspeed:
            return ["Orpheus-3b"]
        }
    }
    
    var voiceOptions: [String] {
        switch self {
        case .openai:
            return ["alloy", "ash", "ballad", "coral", "echo", "sage", "shimmer", "verse"]
        case .outspeed:
            return ["tara", "leah", "jess", "leo", "dan", "mia", "zac", "zoe", "julia"]
        }
    }
    
    var defaultModel: String {
        switch self {
        case .openai:
            return "gpt-4o-mini-realtime-preview-2024-12-17"
        case .outspeed:
            return "Orpheus-3b"
        }
    }
    
    var defaultVoice: String {
        switch self {
        case .openai:
            return "alloy"
        case .outspeed:
            return "tara"
        }
    }
    
    var defaultSystemMessage: String {
        switch self {
        case .openai:
            return "You are a helpful, witty, and friendly AI. Act like a human. Your voice and personality should be warm and engaging, with a lively and playful tone. Talk quickly."
        case .outspeed:
            return "You are a helpful, witty, and friendly AI. Act like a human. Your voice and personality should be warm and engaging, with a lively and playful tone. Talk quickly."
        }
    }
} 
