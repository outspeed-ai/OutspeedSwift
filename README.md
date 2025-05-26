# OutspeedSwift

Swift SDK for the Outspeed Live API that enables real-time voice conversations using WebRTC.

## Features

- Real-time voice conversations with AI
- Support for both Outspeed and OpenAI providers
- WebRTC-based audio streaming
- Customizable voice and model selection

## Installation

1. Open Your Project in Xcode
2. Go to `File` > `Add Packages...`
3. Enter Repository URL in the Search Bar: `https://github.com/outspeed-ai/OutspeedSwift`
4. Select Version
5. Import the SDK

   ```swift
   import OutspeedSDK
   ```

> [!IMPORTANT]
> Ensure `NSMicrophoneUsageDescription` is added to your Info.plist to explain microphone access.

## Requirements

- iOS 15.2 or later
- Swift 6.1+

## Usage

### Basic Setup

```swift
import OutspeedSDK

// Create a session configuration
let config = OutspeedSDK.SessionConfig()

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
            apiKey: "<YOUR_OUTSPEED_API_KEY>"
        )

        // When done with the conversation
        conversation.endSession()
    } catch {
        print("Failed to start conversation: \(error)")
    }
}
```

## ElevenLabs Swift Compatibilty

OutspeedSDK is fully compatible with Elevenlabs Swift SDK specifications, although some features might not be fully supported yet.

To switch from ElevenLabsSDK:

1. Replace all occurrences of "ElevenLabsSDK" with "OutspeedSDK". So for example:

   ```swift
   import ElevenLabsSDK

   let config = ElevenLabsSDK.SessionConfig(agentId: "testagent")
   ```

   becomes

   ```swift
   import OutspeedSDK

   let config = OutspeedSDK.SessionConfig(agentId: "testagent") // you can even skip agentId
   ```

2. Add your Outspeed API key to `startSession`:

   ```swift

   let conversation = try await ElevenLabsSDK.Conversation.startSession(
       config: config,
       callbacks: callbacks
   )
   ```

   becomes

   ```swift

   let conversation = try await OutspeedSDK.Conversation.startSession(
       config: config,
       callbacks: callbacks
       apiKey: "<YOUR_OUTSPEED_API_KEY>" // required
   )
   ```

### Configuring System Prompt, First Message, and Voice

You can customize the AI's behavior, initial message, and voice using configuration objects:

```swift
// Configure the AI agent's behavior and initial message (ElevenLabs compatible)
let agentConfig = OutspeedSDK.AgentConfig(
    prompt: "You are a helpful assistant with a witty personality.",
    firstMessage: "Hey there, how can I help you with Outspeed today?"
)

// Configure voice selection (also ElevenLabs compatible)
let ttsConfig = OutspeedSDK.TTSConfig(voiceId: OutspeedSDK.OrpheusVoice.zac.rawValue)

// Create session configuration with overrides
let config = OutspeedSDK.SessionConfig(
    overrides: OutspeedSDK.ConversationConfigOverride(
        agent: agentConfig,
        tts: ttsConfig
    )
)

// Set up callbacks
var callbacks = OutspeedSDK.Callbacks()
callbacks.onMessage = { message, role in
    print("Received message from \(role.rawValue): \(message)")
}

callbacks.onError = { message, error in
    print("Error: \(message)")
}

callbacks.onStatusChange = { status in
    print("Status changed to: \(status.rawValue)")
}

// Start the conversation with custom configuration
Task {
    do {
        let conversation = try await OutspeedSDK.Conversation.startSession(
            config: config,
            callbacks: callbacks,
            apiKey: "<YOUR_OUTSPEED_API_KEY>",
        )
    } catch {
        print("Failed to start conversation: \(error)")
    }
}
```

#### Configuration Options

- **AgentConfig**: Customize the AI's behavior and initial response

  - `prompt`: System instructions that define the AI's personality and behavior
  - `firstMessage`: Optional initial message the AI will speak when the conversation starts

- **TTSConfig**: Configure voice settings

  - `voiceId`: Select from available voices (e.g., `OutspeedSDK.OrpheusVoice.zac.rawValue`)

> [!NOTE]
> All configuration objects (`AgentConfig`, `TTSConfig`, and `ConversationConfigOverride`) are fully compatible with ElevenLabs SDK specifications.

## Examples

You can find examples of the SDK here: https://github.com/outspeed-ai/outspeed-swift-examples
