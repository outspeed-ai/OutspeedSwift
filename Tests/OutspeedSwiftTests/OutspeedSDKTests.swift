import XCTest
@testable import OutspeedSwift

final class OutspeedSDKTests: XCTestCase {
    func testSDKInitialization() {
        // Just verify that we can create an instance without crashing
        XCTAssertNotNil(OutspeedSDK.version)
    }
    
    func testSessionConfigCreation() {
        // Test creating a session config with defaults
        let config = OutspeedSDK.SessionConfig(
            apiKey: "test-api-key"
        )
        
        XCTAssertEqual(config.apiKey, "test-api-key")
        XCTAssertEqual(config.provider, .outspeed)
        XCTAssertEqual(config.modelName, Provider.outspeed.defaultModel)
        XCTAssertEqual(config.voice, Provider.outspeed.defaultVoice)
        XCTAssertEqual(config.systemInstructions, Provider.outspeed.defaultSystemMessage)
    }
    
    func testSessionConfigWithCustomParameters() {
        // Test creating a session config with custom parameters
        let config = OutspeedSDK.SessionConfig(
            apiKey: "test-api-key",
            modelName: "custom-model",
            systemInstructions: "Custom instructions",
            voice: "custom-voice",
            provider: .openai
        )
        
        XCTAssertEqual(config.apiKey, "test-api-key")
        XCTAssertEqual(config.provider, .openai)
        XCTAssertEqual(config.modelName, "custom-model")
        XCTAssertEqual(config.voice, "custom-voice")
        XCTAssertEqual(config.systemInstructions, "Custom instructions")
    }
    
    // This test is marked as disabled because it would require actual API credentials
    // and would attempt to establish a real connection
    func testDisabled_ConversationStartSession() async {
        // This is how you would start a conversation in a real app
        // Replace with your actual API key
        let apiKey = "your-api-key-here"
        
        var statusChanged = false
        var connected = false
        
        // Create callbacks
        let callbacks = OutspeedSDK.Callbacks()
        callbacks.onStatusChange = { status in
            statusChanged = true
            if status == .connected {
                connected = true
            }
        }
        
        callbacks.onMessage = { message, role in
            print("Received message from \(role): \(message)")
        }
        
        callbacks.onError = { message, error in
            print("Error: \(message), details: \(String(describing: error))")
        }
        
        // Create session config
        let config = OutspeedSDK.SessionConfig(
            apiKey: apiKey,
            systemInstructions: "You are a helpful assistant.",
            provider: .outspeed
        )
        
        do {
            // Start the conversation
            let conversation = try await OutspeedSDK.Conversation.startSession(
                config: config,
                callbacks: callbacks
            )
            
            // Send a message
            conversation.sendMessage("Hello, how are you today?")
            
            // Wait a bit for the response
            try await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
            
            // End the conversation
            conversation.endSession()
            
            XCTAssertTrue(statusChanged)
            
        } catch {
            XCTFail("Failed to start conversation: \(error)")
        }
    }
} 