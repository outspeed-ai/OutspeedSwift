import Foundation

struct Property: Codable, Sendable {
    var description: String?
    var type: String
}

struct Parameters: Codable, Sendable {
    var type: String
    var properties: [String: Property]
    var required: [String]
}

struct Tool: Codable, Sendable {
    var type: String // "function"
    var name: String
    var description: String?
    var parameters: Parameters
}

struct SessionConfig: Codable, Sendable {
    // Model can be one of three values
    var model: String // "Orpheus-3b" | "gpt-4o-realtime-preview-2024-12-17" | "gpt-4o-mini-realtime-preview-2024-12-17"
    
    // Voice depends on the model
    var voice: String // For Orpheus-3b: "tara" | "leah" | "jess" | "leo" | "dan" | "mia" | "zac" | "zoe" | "julia"
                      // For OpenAI models: "alloy" | "ash" | "ballad" | "coral" | "echo" | "sage" | "shimmer" | "verse"
    
    // Input audio transcription configuration
    var input_audio_transcription_model: String? // For Orpheus-3b: "whisper-v3-turbo"
                                                // For OpenAI models: "gpt-4o-transcribe" | "gpt-4o-mini-transcribe" | "whisper-1"
    
    // Base configuration fields
    let modalities: [String]
    let temperature: Double
    let instructions: String
    
    // Tools configuration
    let tools: [String: Tool]
    
    // Turn detection configuration
    let turn_detection_type: String // "server_vad" | "semantic_vad"
    
    enum CodingKeys: String, CodingKey {
        case model
        case voice
        case input_audio_transcription_model
        case modalities
        case temperature
        case instructions
        case tools
        case turn_detection_type
    }
}
