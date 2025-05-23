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
.package(url: "https://github.com/outspeed-ai/OutspeedSwift", from: "0.0.2")
```

And add `OutspeedSDK` to your target dependencies:

```swift
.target(
    name: "YourTarget",
    dependencies: ["OutspeedSDK"]),
```

### Xcode

1. Open Your Project in Xcode
   - Navigate to your project directory and open it in Xcode.
2. Add Package Dependency
   - Go to `File` > `Add Packages...`
3. Enter Repository URL in the Search Bar
   - Input the following URL: `https://github.com/outspeed-ai/OutspeedSwift`
4. Select Version
5. Import the SDK
   ```swift
   import OutspeedSDK
   ```
6. Ensure `NSMicrophoneUsageDescription` is added to your Info.plist to explain microphone access.

## Requirements

- iOS >=18.0
- Swift 6.1+

## Usage

### Basic Setup

```swift
import OutspeedSDK

// Create a session configuration
let config = OutspeedSDK.SessionConfig( agentId : "testagent")

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

OutspeedSDK is fully compatible with Elevenlabs Swift SDK specifications (some features might not be fully supported yet.)

To switch from ElevenLabsSDK:

1. Replace all occurrences of "ElevenLabsSDK" with "OutspeedSDK". So for example:

```swift
import ElevenLabsSDK

let config = ElevenLabsSDK.SessionConfig( agentId : "testagent")
```

becomes

```swift
import OutspeedSDK

let config = OutspeedSDK.SessionConfig( agentId : "testagent")
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
    apiKey: "<YOUR_OUTSPEED_API_KEY>"
)
```

## Examples

You can find examples of the SDK here: https://github.com/outspeed-ai/outspeed-swift-examples
