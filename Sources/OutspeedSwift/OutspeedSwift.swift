import AVFoundation
import Combine
import Foundation
import os.log
import WebRTC

/// Main class for OutspeedSwift package
public class OutspeedSDK {
    public static let version = "0.0.1"

    private enum Constants {
        static let defaultApiOrigin = "api.outspeed.com"
        static let defaultApiPathname = "/v1/convai/conversation?agent_id="
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
        public var prompt: String?

        public init(prompt: String? = nil) {
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
        public var agent: AgentConfig?
        public var tts: TTSConfig?

        public init(agent: AgentConfig? = nil, tts: TTSConfig? = nil) {
            self.agent = agent
            self.tts = tts
        }
    }

    public struct AgentConfig: Codable, Sendable {
        public var prompt: AgentPrompt?
        public var firstMessage: String?
        public var language: Language?

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
        public let signedUrl: String?
        public let agentId: String?
        public let overrides: ConversationConfigOverride?
        public let customLlmExtraBody: [String: LlmExtraBodyValue]?
        public let dynamicVariables: [String: DynamicVariableValue]?

        public init(signedUrl: String, overrides: ConversationConfigOverride? = nil, customLlmExtraBody: [String: LlmExtraBodyValue]? = nil, clientTools _: ClientTools = ClientTools(), dynamicVariables: [String: DynamicVariableValue]? = nil) {
            self.signedUrl = signedUrl
            agentId = nil
            self.overrides = overrides
            self.customLlmExtraBody = customLlmExtraBody
            self.dynamicVariables = dynamicVariables
        }

        public init(agentId: String, overrides: ConversationConfigOverride? = nil, customLlmExtraBody: [String: LlmExtraBodyValue]? = nil, clientTools _: ClientTools = ClientTools(), dynamicVariables: [String: DynamicVariableValue]? = nil) {
            self.agentId = agentId
            signedUrl = nil
            self.overrides = overrides
            self.customLlmExtraBody = customLlmExtraBody
            self.dynamicVariables = dynamicVariables
        }
    }

    public class Connection: @unchecked Sendable {
        public let socket: URLSessionWebSocketTask
        public let conversationId: String
        public let sampleRate: Int

        private init(socket: URLSessionWebSocketTask, conversationId: String, sampleRate: Int) {
            self.socket = socket
            self.conversationId = conversationId
            self.sampleRate = sampleRate
        }

        public static func create(config: SessionConfig) async throws -> Connection {
            let origin = ProcessInfo.processInfo.environment["OUTSPEED_API_URL"] ?? Constants.defaultApiOrigin

            guard let url = URL(string: origin + Constants.defaultApiPathname + config.agentId) else {
                throw OutspeedError.invalidURL
            }

            let session = URLSession(configuration: .default)
            let socket = session.webSocketTask(with: url)
            socket.resume()

            // Always send initialization event
            var initEvent: [String: Any] = ["type": "conversation_initiation_client_data"]

            // Add overrides if present
            if let overrides = config.overrides,
               let overridesDict = overrides.dictionary
            {
                initEvent["conversation_config_override"] = overridesDict
            }

            // Add custom body if present
            if let customBody = config.customLlmExtraBody {
                initEvent["custom_llm_extra_body"] = customBody.mapValues { $0.jsonValue }
            }

            // Add dynamic variables if present - Convert to JSON-compatible values
            if let dynamicVars = config.dynamicVariables {
                initEvent["dynamic_variables"] = dynamicVars.mapValues { $0.jsonValue }
            }

            let jsonData = try JSONSerialization.data(withJSONObject: initEvent)
            let jsonString = String(data: jsonData, encoding: .utf8)!
            try await socket.send(.string(jsonString))

            let configData = try await receiveInitialMessage(socket: socket)
            return Connection(socket: socket, conversationId: configData.conversationId, sampleRate: configData.sampleRate)
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

    public class Input {
        public let audioUnit: AudioUnit
        public var audioFormat: AudioStreamBasicDescription
        public var isRecording: Bool = false
        private var recordCallback: ((AVAudioPCMBuffer, Float) -> Void)?
        private var currentAudioLevel: Float = 0.0

        private init(audioUnit: AudioUnit, audioFormat: AudioStreamBasicDescription) {
            self.audioUnit = audioUnit
            self.audioFormat = audioFormat
        }

        public static func create(sampleRate: Double) async throws -> Input {
            // Define the Audio Component
            var audioComponentDesc = AudioComponentDescription(
                componentType: kAudioUnitType_Output,
                componentSubType: kAudioUnitSubType_VoiceProcessingIO, // For echo cancellation
                componentManufacturer: kAudioUnitManufacturer_Apple,
                componentFlags: 0,
                componentFlagsMask: 0
            )

            guard let audioComponent = AudioComponentFindNext(nil, &audioComponentDesc) else {
                throw OutspeedError.failedToCreateAudioComponent
            }

            var audioUnitOptional: AudioUnit?
            AudioComponentInstanceNew(audioComponent, &audioUnitOptional)
            guard let audioUnit = audioUnitOptional else {
                throw OutspeedError.failedToCreateAudioComponentInstance
            }

            // Create the Input instance
            let input = Input(audioUnit: audioUnit, audioFormat: AudioStreamBasicDescription())

            // Enable IO for recording
            var enableIO: UInt32 = 1
            AudioUnitSetProperty(audioUnit,
                                 kAudioOutputUnitProperty_EnableIO,
                                 kAudioUnitScope_Input,
                                 1,
                                 &enableIO,
                                 UInt32(MemoryLayout.size(ofValue: enableIO)))

            // Disable output
            var disableIO: UInt32 = 0
            AudioUnitSetProperty(audioUnit,
                                 kAudioOutputUnitProperty_EnableIO,
                                 kAudioUnitScope_Output,
                                 0,
                                 &disableIO,
                                 UInt32(MemoryLayout.size(ofValue: disableIO)))

            // Set the audio format
            var audioFormat = AudioStreamBasicDescription(
                mSampleRate: sampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 2,
                mFramesPerPacket: 1,
                mBytesPerFrame: 2,
                mChannelsPerFrame: 1,
                mBitsPerChannel: 16,
                mReserved: 0
            )

            AudioUnitSetProperty(audioUnit,
                                 kAudioUnitProperty_StreamFormat,
                                 kAudioUnitScope_Output,
                                 1, // Bus 1 (Output scope of input element)
                                 &audioFormat,
                                 UInt32(MemoryLayout<AudioStreamBasicDescription>.size))

            input.audioFormat = audioFormat

            // Set the input callback
            var inputCallbackStruct = AURenderCallbackStruct(
                inputProc: inputRenderCallback,
                inputProcRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(input).toOpaque())
            )
            AudioUnitSetProperty(audioUnit,
                                 kAudioOutputUnitProperty_SetInputCallback,
                                 kAudioUnitScope_Global,
                                 1, // Bus 1
                                 &inputCallbackStruct,
                                 UInt32(MemoryLayout<AURenderCallbackStruct>.size))

            // Initialize and start the audio unit
            AudioUnitInitialize(audioUnit)
            AudioOutputUnitStart(audioUnit)

            return input
        }

        public func setRecordCallback(_ callback: @escaping (AVAudioPCMBuffer, Float) -> Void) {
            recordCallback = callback
        }

        public func close() {
            AudioOutputUnitStop(audioUnit)
            AudioUnitUninitialize(audioUnit)
            AudioComponentInstanceDispose(audioUnit)
        }

        private static let inputRenderCallback: AURenderCallback = {
            inRefCon,
                ioActionFlags,
                inTimeStamp,
                _,
                inNumberFrames,
                _
                -> OSStatus in
            let input = Unmanaged<Input>.fromOpaque(inRefCon).takeUnretainedValue()
            let audioUnit = input.audioUnit

            let byteSize = Int(inNumberFrames) * MemoryLayout<Int16>.size
            let data = UnsafeMutableRawPointer.allocate(byteCount: byteSize, alignment: MemoryLayout<Int16>.alignment)
            var audioBuffer = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(byteSize),
                mData: data
            )
            var bufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: audioBuffer
            )

            let status = AudioUnitRender(audioUnit,
                                         ioActionFlags,
                                         inTimeStamp,
                                         1, // inBusNumber
                                         inNumberFrames,
                                         &bufferList)

            if status == noErr {
                let frameCount = Int(inNumberFrames)
                guard let audioFormat = AVAudioFormat(
                    commonFormat: .pcmFormatInt16,
                    sampleRate: input.audioFormat.mSampleRate,
                    channels: 1,
                    interleaved: true
                ) else {
                    data.deallocate()
                    return noErr
                }
                guard let pcmBuffer = AVAudioPCMBuffer(
                    pcmFormat: audioFormat,
                    frameCapacity: AVAudioFrameCount(frameCount)
                ) else {
                    data.deallocate()
                    return noErr
                }
                pcmBuffer.frameLength = AVAudioFrameCount(frameCount)
                let dataPointer = data.assumingMemoryBound(to: Int16.self)
                if let channelData = pcmBuffer.int16ChannelData {
                    memcpy(channelData[0], dataPointer, byteSize)
                }

                // Compute RMS value for volume level
                var rms: Float = 0.0
                for i in 0 ..< frameCount {
                    let sample = Float(dataPointer[i]) / Float(Int16.max)
                    rms += sample * sample
                }
                rms = sqrt(rms / Float(frameCount))

                // Call the callback with the audio buffer and current audio level
                input.recordCallback?(pcmBuffer, rms)
            }

            data.deallocate()
            return status
        }
    }

    // MARK: - Output

    public class Output {
        public let engine: AVAudioEngine
        public let playerNode: AVAudioPlayerNode
        public let mixer: AVAudioMixerNode
        let audioQueue: DispatchQueue
        let audioFormat: AVAudioFormat

        private init(engine: AVAudioEngine, playerNode: AVAudioPlayerNode, mixer: AVAudioMixerNode, audioFormat: AVAudioFormat) {
            self.engine = engine
            self.playerNode = playerNode
            self.mixer = mixer
            self.audioFormat = audioFormat
            audioQueue = DispatchQueue(label: "com.outspeed.audioQueue", qos: .userInteractive)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleInterruption),
                name: .AVAudioEngineConfigurationChange,
                object: engine
            )
        }

        public static func create(sampleRate: Double) async throws -> Output {
            let engine = AVAudioEngine()
            let playerNode = AVAudioPlayerNode()
            let mixer = AVAudioMixerNode()

            engine.attach(playerNode)
            engine.attach(mixer)

            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
                throw OutspeedError.failedToCreateAudioFormat
            }
            engine.connect(playerNode, to: mixer, format: format)
            engine.connect(mixer, to: engine.mainMixerNode, format: format)

            return Output(engine: engine, playerNode: playerNode, mixer: mixer, audioFormat: format)
        }

        public func close() {
            engine.stop()
            // see AVAudioEngine documentation
            playerNode.stop()
        }

        public func startPlaying() throws {
            try engine.start()
            playerNode.play()
        }

        @objc private func handleInterruption() throws {
            engine.connect(playerNode, to: mixer, format: audioFormat)
            engine.connect(mixer, to: engine.mainMixerNode, format: audioFormat)
            try startPlaying()
        }
    }

    // MARK: - Conversation

    public enum Role: String {
        case user
        case ai
    }

    public enum Mode: String {
        case speaking
        case listening
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

    public class Conversation: @unchecked Sendable {
        private let connection: WebRTCManager
        private let callbacks: Callbacks

        private let modeLock = NSLock()
        private let statusLock = NSLock()
        private let volumeLock = NSLock()
        private let lastInterruptTimestampLock = NSLock()
        private let isProcessingInputLock = NSLock()

        private var inputVolumeUpdateTimer: Timer?
        private let inputVolumeUpdateInterval: TimeInterval = 0.1 // Update every 100ms
        private var currentInputVolume: Float = 0.0

        private var _mode: Mode = .listening
        private var _status: Status = .connecting
        private var _volume: Float = 1.0
        private var _lastInterruptTimestamp: Int = 0
        private var _isProcessingInput: Bool = true

        private var mode: Mode {
            get { modeLock.withLock { _mode } }
            set { modeLock.withLock { _mode = newValue } }
        }

        private var status: Status {
            get { statusLock.withLock { _status } }
            set { statusLock.withLock { _status = newValue } }
        }

        private var volume: Float {
            get { volumeLock.withLock { _volume } }
            set { volumeLock.withLock { _volume = newValue } }
        }

        private var lastInterruptTimestamp: Int {
            get { lastInterruptTimestampLock.withLock { _lastInterruptTimestamp } }
            set { lastInterruptTimestampLock.withLock { _lastInterruptTimestamp = newValue } }
        }

        private var isProcessingInput: Bool {
            get { isProcessingInputLock.withLock { _isProcessingInput } }
            set { isProcessingInputLock.withLock { _isProcessingInput = newValue } }
        }

        private var audioBuffers: [AVAudioPCMBuffer] = []
        private let audioBufferLock = NSLock()

        private var previousSamples: [Int16] = Array(repeating: 0, count: 10)
        private var isFirstBuffer = true

        private var outputBuffers: [[Float]] = [[]]

        private let logger = Logger(subsystem: "com.outspeed.OutspeedSDK", category: "Conversation")

        private func setupInputVolumeMonitoring() {
            DispatchQueue.main.async {
                self.inputVolumeUpdateTimer = Timer.scheduledTimer(withTimeInterval: self.inputVolumeUpdateInterval, repeats: true) { [weak self] _ in
                    guard let self = self else { return }
                    self.callbacks.onVolumeUpdate(self.currentInputVolume)
                }
            }
        }

        private init(connection: Connection, callbacks: Callbacks) {
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
        public static func startSession(config: SessionConfig, callbacks: Callbacks = Callbacks(), apiKey: String) async throws -> Conversation {
            // Step 2: Create the WebSocket connection
            let connection = WebRTCManager()

            try connection.startConnection(apiKey: apiKey, callbacks: callbacks)

            // Step 5: Initialize the Conversation
            let conversation = Conversation(connection: connection, callbacks: callbacks)

            return conversation
        }

        public var conversationVolume: Float {
            get {
                return volume
            }
            set {
                volume = newValue
                output.mixer.volume = newValue
            }
        }


        private func sendWebSocketMessage(_ message: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: message),
                  let string = String(data: data, encoding: .utf8)
            else {
                callbacks.onError("Failed to encode message", message)
                return
            }

            connection.socket.send(.string(string)) { [weak self] error in
                if let error = error {
                    self?.logger.error("Failed to send WebSocket message: \(error.localizedDescription)")
                    self?.callbacks.onError("Failed to send WebSocket message", error)
                }
            }
        }


        private func updateVolume(_ buffer: AVAudioPCMBuffer) {
            guard let channelData = buffer.floatChannelData else { return }

            var sum: Float = 0
            let channelCount = Int(buffer.format.channelCount)

            for channel in 0 ..< channelCount {
                let data = channelData[channel]
                for i in 0 ..< Int(buffer.frameLength) {
                    sum += abs(data[i])
                }
            }

            let average = sum / Float(buffer.frameLength * buffer.format.channelCount)
            let meterLevel = 20 * log10(average)

            // Normalize the meter level to a 0-1 range
            currentInputVolume = max(0, min(1, (meterLevel + 50) / 50))
        }


        private func updateMode(_ newMode: Mode) {
            guard mode != newMode else { return }
            mode = newMode
            callbacks.onModeChange(newMode)
        }

        private func updateStatus(_ newStatus: Status) {
            guard status != newStatus else { return }
            status = newStatus
            callbacks.onStatusChange(newStatus)
        }

        /// Send a contextual update event
        public func sendContextualUpdate(_ text: String) {
            let event: [String: Any] = [
                "type": "contextual_update",
                "text": text
            ]
            sendWebSocketMessage(event)
        }

        /// Ends the current conversation session
        public func endSession() {
            guard status == .connected else { return }

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

        /// Retrieves the output volume
        /// - Returns: Current output volume
        public func getOutputVolume() -> Float {
            output.mixer.volume
        }

        /// Starts recording audio input
        public func startRecording() {
            isProcessingInput = true
        }

        /// Stops recording audio input
        public func stopRecording() {
            isProcessingInput = false
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

extension NSLock {
    /// Executes a closure within a locked context
    /// - Parameter body: Closure to execute
    /// - Returns: Result of the closure
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

private extension Data {
    /// Initializes `Data` from an array of Int16
    /// - Parameter buffer: Array of Int16 values
    init(buffer: [Int16]) {
        self = buffer.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

extension Encodable {
    var dictionary: [String: Any]? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: .allowFragments)) as? [String: Any]
    }
}