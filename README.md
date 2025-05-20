# OutspeedSwift

A Swift SDK for the Outspeed API that enables real-time voice conversations using WebRTC technology.

## Features

- Real-time voice conversations with AI
- Support for both Outspeed and OpenAI providers
- WebRTC-based audio streaming
- Customizable voice and model selection
- Device-specific optimizations
- Comprehensive audio session management

## Installation

### Swift Package Manager

Add the following dependency to your `Package.swift` file:

```swift
.package(url: "https://github.com/yourusername/OutspeedSwift.git", from: "1.0.0")
```

And add `OutspeedSwift` to your target dependencies:

```swift
.target(
    name: "YourTarget",
    dependencies: ["OutspeedSwift"]),
```

## Requirements

- iOS 18.0+
- Swift 6.1+

## Usage

### Basic Setup

```swift
import OutspeedSwift

// Create a session configuration
let config = OutspeedSDK.SessionConfig(
    apiKey: "your-api-key",  // Replace with your actual API key
    systemInstructions: "You are a helpful, friendly assistant.",
    provider: .outspeed  // or .openai
)

// Create callbacks to handle events
let callbacks = OutspeedSDK.Callbacks()
callbacks.onMessage = { message, role in
    print("Received message from \(role.rawValue): \(message)")
}

callbacks.onError = { message, error in
    print("Error: \(message)")
}

callbacks.onStatusChange = { status in
    print("Status changed to: \(status.rawValue)")
}

// Start the conversation
Task {
    do {
        let conversation = try await OutspeedSDK.Conversation.startSession(
            config: config,
            callbacks: callbacks
        )

        // Send a message
        conversation.sendMessage("Hello, how are you today?")

        // When done with the conversation
        // conversation.endSession()
    } catch {
        print("Failed to start conversation: \(error)")
    }
}
```

### Customizing Voice and Model

```swift
// Create a session with custom voice and model
let config = OutspeedSDK.SessionConfig(
    apiKey: "your-api-key",
    modelName: "Orpheus-3b",           // Or any supported model
    systemInstructions: "You are a helpful assistant specialized in Swift programming.",
    voice: "tara",                    // Choose a voice from Provider.voiceOptions
    provider: .outspeed               // Use .openai for OpenAI models
)
```

### Handling Audio Volume

```swift
// Set up volume update callback
callbacks.onVolumeUpdate = { level in
    // Update UI with volume level (0.0 to 1.0)
    updateVolumeIndicator(level: level)
}
```

### Stopping and Starting Recording

```swift
// To pause recording (e.g., when user wants to stop speaking)
conversation.stopRecording()

// To resume recording
conversation.startRecording()
```

### Ending a Conversation

```swift
// When done with the conversation
conversation.endSession()
```

## Advanced Usage

### Provider Selection

The SDK supports two providers: Outspeed and OpenAI.

```swift
// Get available models for a provider
let availableModels = Provider.outspeed.modelOptions

// Get available voices for a provider
let availableVoices = Provider.openai.voiceOptions
```

### Session Configurations

For specific use cases, you can configure all aspects of the session:

```swift
// Custom configuration
let config = OutspeedSDK.SessionConfig(
    apiKey: "your-api-key",
    modelName: "custom-model-name",
    systemInstructions: "Detailed instructions for the AI...",
    voice: "selected-voice",
    provider: .outspeed
)
```

## License

This project is licensed under the MIT License - see the LICENSE file for details.
