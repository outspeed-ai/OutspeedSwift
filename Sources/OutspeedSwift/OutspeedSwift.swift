import AVFoundation
import Combine
import Foundation
import os.log
import WebRTC
import SwiftUI
import UIKit



/// Main class for OutspeedSwift package
public class OutspeedSDK : ObservableObject {
    public static let version: String = "0.0.2"
    public init() {
        #if os(iOS)
        // Prevent usage on iOS versions newer than 18.3.1
        if #available(iOS 18.4, *) {
            fatalError("This build is not intended for iOS versions after 18.3.1")
        }
        #endif
    }

    public enum Role: String {
    case user
    case ai
    }


    public enum Mode: String {
        case speaking
        case listening
    }

    public struct ConversationItem: Identifiable {
        public let id: String       // item_id from the JSON
        public let role: String     // "user" / "assistant"
        public var text: String     // transcript

        public init(id: String, role: String, text: String) {
            self.id = id
            self.role = role
            self.text = text
        }
        
        public var roleSymbol: String {
            role.lowercased() == "user" ? "person.fill" : "sparkles"
        }
        
        public var roleColor: Color {
            role.lowercased() == "user" ? .blue : .purple
        }
    }

    public enum Status: String {
        case connecting
        case connected
        case disconnecting
        case disconnected
    }


    public struct Callbacks: Sendable {
    public var onConnect: @Sendable (String) -> Void = { _ in }
    public var onDisconnect: @Sendable () -> Void = {}
    public var onMessage: @Sendable (String, Role) -> Void = { _, _ in }
    public var onError: @Sendable (String, Any?) -> Void = { _, _ in }
    public var onStatusChange: @Sendable (Status) -> Void = { _ in }
    public var onModeChange: @Sendable (Mode) -> Void = { _ in }
    public var onVolumeUpdate: @Sendable (Float) -> Void = { _ in }

    public init() {}
}

    private enum Constants {
        static let inputSampleRate: Double = 16000
        static let sampleRate: Double = 16000
        static let ioBufferDuration: Double = 0.005
        static let volumeUpdateInterval: TimeInterval = 0.1
        static let fadeOutDuration: TimeInterval = 2.0
        static let bufferSize: AVAudioFrameCount = 1024

        // WebSocket message size limits
        static let maxWebSocketMessageSize = 1024 * 1024 // 1MB WebSocket limit
        static let safeMessageSize = 750 * 1024 // 750KB - safely under the limit
        static let maxRequestedMessageSize = 8 * 1024 * 1024 // 8MB - request larger buffer if available
    }

    // MARK: - Session Config Utilities

    public enum Language: String, Codable, Sendable {
        case en, ja, zh, de, hi, fr, ko, pt, it, es, id, nl, tr, pl, sv, bg, ro, ar, cs, el, fi, ms, da, ta, uk, ru, hu, no, vi
    }

    public struct AgentPrompt: Codable, Sendable {
        var prompt: String?

        init(prompt: String? = nil) {
            self.prompt = prompt
        }
    }

    public struct TTSConfig: Codable, Sendable {
        public var voiceId: String?

        private enum CodingKeys: String, CodingKey {
            case voiceId = "voice_id"
        }

        public init(voiceId: String? = nil) {
            self.voiceId = voiceId
        }
    }

    public struct ConversationConfigOverride: Codable, Sendable {
        var agent: AgentConfig?
        var tts: TTSConfig?

        public init(agent: AgentConfig? = nil, tts: TTSConfig? = nil) {
            self.agent = agent
            self.tts = tts
        }
    }

    public struct AgentConfig: Codable, Sendable {
        var prompt: AgentPrompt?
        var firstMessage: String?
        var language: Language?

        private enum CodingKeys: String, CodingKey {
            case prompt
            case firstMessage = "first_message"
            case language
        }

        public init(prompt: AgentPrompt? = nil, firstMessage: String? = nil, language: Language? = nil) {
            self.prompt = prompt
            self.firstMessage = firstMessage
            self.language = language
        }
    }

    public enum LlmExtraBodyValue: Codable, Sendable {
        case string(String)
        case number(Double)
        case boolean(Bool)
        case null
        case array([LlmExtraBodyValue])
        case dictionary([String: LlmExtraBodyValue])

        var jsonValue: Any {
            switch self {
            case let .string(str): return str
            case let .number(num): return num
            case let .boolean(bool): return bool
            case .null: return NSNull()
            case let .array(arr): return arr.map { $0.jsonValue }
            case let .dictionary(dict): return dict.mapValues { $0.jsonValue }
            }
        }
    }

    // MARK: - Connection

    public enum DynamicVariableValue: Sendable {
        case string(String)
        case number(Double)
        case boolean(Bool)
        case int(Int)

        var jsonValue: Any {
            switch self {
            case let .string(str): return str
            case let .number(num): return num
            case let .boolean(bool): return bool
            case let .int(int): return int
            }
        }
    }

    public struct SessionConfig: Sendable {
        let signedUrl: String?
        let agentId: String?
        let overrides: ConversationConfigOverride?
        let customLlmExtraBody: [String: LlmExtraBodyValue]?
        let dynamicVariables: [String: DynamicVariableValue]?

        public init(signedUrl: String, overrides: ConversationConfigOverride? = nil, customLlmExtraBody: [String: LlmExtraBodyValue]? = nil, dynamicVariables: [String: DynamicVariableValue]? = nil) {
            print("signedUrl, overrides, customLlmExtraBody, and dynamicVariables are not yet supported by OutspeedSwift. Ignoring them.")
            self.signedUrl = signedUrl
            agentId = nil
            self.overrides = overrides
            self.customLlmExtraBody = customLlmExtraBody
            self.dynamicVariables = dynamicVariables
        }

        public init(agentId: String, overrides: ConversationConfigOverride? = nil, customLlmExtraBody: [String: LlmExtraBodyValue]? = nil, dynamicVariables: [String: DynamicVariableValue]? = nil) {
            print("agentId, overrides, customLlmExtraBody, and dynamicVariables are not yet supported by OutspeedSwift. Ignoring them.")
            self.agentId = agentId
            signedUrl = nil
            self.overrides = overrides
            self.customLlmExtraBody = customLlmExtraBody
            self.dynamicVariables = dynamicVariables
        }
    }


    class Connection: @unchecked Sendable {
        let socket: URLSessionWebSocketTask
        let conversationId: String
        let sampleRate: Int

        private init(socket: URLSessionWebSocketTask, conversationId: String, sampleRate: Int) {
            self.socket = socket
            self.conversationId = conversationId
            self.sampleRate = sampleRate
        }

        private static func receiveInitialMessage(
            socket: URLSessionWebSocketTask
        ) async throws -> (conversationId: String, sampleRate: Int) {
            return try await withCheckedThrowingContinuation { continuation in
                socket.receive { result in
                    switch result {
                    case let .success(message):
                        switch message {
                        case let .string(text):
                            guard let data = text.data(using: .utf8),
                                  let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                                  let type = json["type"] as? String,
                                  type == "conversation_initiation_metadata",
                                  let metadata = json["conversation_initiation_metadata_event"] as? [String: Any],
                                  let conversationId = metadata["conversation_id"] as? String,
                                  let audioFormat = metadata["agent_output_audio_format"] as? String
                            else {
                                continuation.resume(throwing: OutspeedError.invalidInitialMessageFormat)
                                return
                            }

                            let sampleRate = Int(audioFormat.replacingOccurrences(of: "pcm_", with: "")) ?? 16000
                            continuation.resume(returning: (conversationId: conversationId, sampleRate: sampleRate))

                        case .data:
                            continuation.resume(throwing: OutspeedError.unexpectedBinaryMessage)

                        @unknown default:
                            continuation.resume(throwing: OutspeedError.unknownMessageType)
                        }
                    case let .failure(error):
                        continuation.resume(throwing: error)
                    }
                }
            }
        }

        public func close() {
            socket.cancel(with: .goingAway, reason: nil)
        }
    }

    // MARK: - Audio Input
    // MARK: - Conversation

    public class Conversation: @unchecked Sendable {
        public let connection: WebRTCManager
        private let callbacks: Callbacks

        private var inputVolumeUpdateTimer: Timer?
        private let inputVolumeUpdateInterval: TimeInterval = 0.1 // Update every 100ms
        private var currentInputVolume: Float = 0.0

        private var _mode: Mode = .listening
        private var _status: Status = .connecting

        private let logger = Logger(subsystem: "com.outspeed.OutspeedSDK", category: "Conversation")

        private func setupInputVolumeMonitoring() {
            DispatchQueue.main.async {
                self.inputVolumeUpdateTimer = Timer.scheduledTimer(withTimeInterval: self.inputVolumeUpdateInterval, repeats: true) { [weak self] _ in
                    guard let self = self else { return }
                    self.callbacks.onVolumeUpdate(self.currentInputVolume)
                }
            }
        }

        private init(connection: WebRTCManager, callbacks: Callbacks) {
            self.connection = connection
            self.callbacks = callbacks

            setupInputVolumeMonitoring()
        }

        /// Starts a new conversation session
        /// - Parameters:
        ///   - config: Session configuration
        ///   - callbacks: Callbacks for conversation events
        ///   - clientTools: Client tools callbacks (optional)
        ///   - apiKey: API key for the conversation
        /// - Returns: A started `Conversation` instance
        public static func startSession(config: SessionConfig, callbacks: Callbacks = Callbacks(), apiKey: String?, provider: Provider = .outspeed) async throws -> Conversation {
            // Step 2: Create the WebSocket connection
            #if os(iOS)
            // Prevent usage on iOS versions newer than 18.3.1
            if #available(iOS 18.4, *) {
                print("OutspeedSwift build is not intended for iOS versions after 18.3.1")
                fatalError("OutspeedSwift build is not intended for iOS versions after 18.3.1")
            }
            #endif


            let connection = WebRTCManager()

            if provider == .outspeed {
                guard let apiKey = apiKey ?? ProcessInfo.processInfo.environment["OUTSPEED_API_KEY"] else {
                    callbacks.onError("No API key provided. Please set OUTSPEED_API_KEY in your environment variables or pass an apiKey parameter.", nil)
                    throw OutspeedError.invalidConfiguration
                }
            }
            if provider == .openai {
                guard let apiKey = apiKey ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"] else {
                    callbacks.onError("No API key provided. Please set OPENAI_API_KEY in your environment variables or pass an apiKey parameter.", nil)
                    throw OutspeedError.invalidConfiguration
                }
            }

            print("Using API key: \(apiKey ?? "Not provided")")

            if callbacks.onModeChange != nil {
                print("onModeChange is not supported by OutspeedSwift. Ignoring it.")
            }
            if callbacks.onVolumeUpdate != nil {
                print("onVolumeUpdate is not supported by OutspeedSwift. Ignoring it.")
            }


            try connection.startConnection(config: config, apiKey: apiKey ?? "", callbacks: callbacks, provider: provider)

            // Step 5: Initialize the Conversation
            let conversation = Conversation(connection: connection, callbacks: callbacks)

            return conversation
        }

        // TODO: Implement this
        // private func sendWebSocketMessage(_ message: [String: Any]) {
        //     guard let data = try? JSONSerialization.data(withJSONObject: message),
        //           let string = String(data: data, encoding: .utf8)
        //     else {
        //         callbacks.onError("Failed to encode message", message)
        //         return
        //     }

        //     connection.socket.send(.string(string)) { [weak self] error in
        //         if let error = error {
        //             self?.logger.error("Failed to send WebSocket message: \(error.localizedDescription)")
        //             self?.callbacks.onError("Failed to send WebSocket message", error)
        //         }
        //     }
        // }


        // /// Send a contextual update event
        // public func sendContextualUpdate(_ text: String) {
        //     let event: [String: Any] = [
        //         "type": "contextual_update",
        //         "text": text
        //     ]
        //     sendWebSocketMessage(event)
        // }

        /// Ends the current conversation session
        public func endSession() {
            connection.stopConnection()

            DispatchQueue.main.async {
                self.inputVolumeUpdateTimer?.invalidate()
                self.inputVolumeUpdateTimer = nil
            }
        }

        /// Retrieves the conversation ID
        /// - Returns: Conversation identifier
        public func getId() -> String {
            connection.conversationId
        }

        /// Retrieves the input volume
        /// - Returns: Current input volume
        public func getInputVolume() -> Float {
            0
        }

    }

    // MARK: - Errors

    /// Defines errors specific to OutspeedSwift
    public enum OutspeedError: Error, LocalizedError {
        case invalidConfiguration
        case invalidURL
        case invalidInitialMessageFormat
        case unexpectedBinaryMessage
        case unknownMessageType
        case failedToCreateAudioFormat
        case failedToCreateAudioComponent
        case failedToCreateAudioComponentInstance

        public var errorDescription: String? {
            switch self {
            case .invalidConfiguration:
                return "Invalid configuration provided."
            case .invalidURL:
                return "The provided URL is invalid."
            case .failedToCreateAudioFormat:
                return "Failed to create the audio format."
            case .failedToCreateAudioComponent:
                return "Failed to create audio component."
            case .failedToCreateAudioComponentInstance:
                return "Failed to create audio component instance."
            case .invalidInitialMessageFormat:
                return "The initial message format is invalid."
            case .unexpectedBinaryMessage:
                return "Received an unexpected binary message."
            case .unknownMessageType:
                return "Received an unknown message type."
            }
        }
    }
}


extension Encodable {
    var dictionary: [String: Any]? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: .allowFragments)) as? [String: Any]
    }
}
