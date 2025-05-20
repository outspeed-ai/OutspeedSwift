// The Swift Programming Language
// https://docs.swift.org/swift-book

import AVFoundation
import Combine
import Foundation
import WebRTC
import os.log

/// Main class for OutspeedSwift package
public class OutspeedSDK {
    public static let version = "1.0.0"

    private enum Constants {
        static let defaultApiOrigin = "https://api.outspeed.com"
        static let inputSampleRate: Double = 16000
        static let sampleRate: Double = 16000
        static let ioBufferDuration: Double = 0.005
        static let volumeUpdateInterval: TimeInterval = 0.1
        static let fadeOutDuration: TimeInterval = 2.0
        static let bufferSize: AVAudioFrameCount = 1024
    }

    // MARK: - Session Config Utilities

    public enum Language: String, Codable, Sendable {
        case en, ja, zh, de, hi, fr, ko, pt, it, es, id, nl, tr, pl, sv
    }

    public struct SessionConfig: Sendable {
        public let apiKey: String
        public let modelName: String
        public let systemInstructions: String
        public let voice: String
        public let provider: Provider
        
        public init(
            apiKey: String,
            modelName: String? = nil,
            systemInstructions: String? = nil,
            voice: String? = nil,
            provider: Provider = .outspeed
        ) {
            self.apiKey = apiKey
            self.modelName = modelName ?? provider.defaultModel
            self.systemInstructions = systemInstructions ?? provider.defaultSystemMessage
            self.voice = voice ?? provider.defaultVoice
            self.provider = provider
        }
    }

    // MARK: - Audio Processing

    public class AudioProcessor {
        private var buffers: [Data] = []
        private var cursor: Int = 0
        private var currentBuffer: Data?
        private var wasInterrupted: Bool = false
        private var finished: Bool = false
        public var onProcess: ((Bool) -> Void)?

        public func process(outputs: inout [[Float]]) {
            var isFinished = false
            let outputChannel = 0
            var outputBuffer = outputs[outputChannel]
            var outputIndex = 0

            while outputIndex < outputBuffer.count {
                if currentBuffer == nil {
                    if buffers.isEmpty {
                        isFinished = true
                        break
                    }
                    currentBuffer = buffers.removeFirst()
                    cursor = 0
                }

                if let currentBuffer = currentBuffer {
                    let remainingSamples = currentBuffer.count / 2 - cursor
                    let samplesToWrite = min(remainingSamples, outputBuffer.count - outputIndex)

                    guard let int16ChannelData = currentBuffer.withUnsafeBytes({ $0.bindMemory(to: Int16.self).baseAddress }) else {
                        print("Failed to access Int16 channel data.")
                        break
                    }

                    for sampleIndex in 0 ..< samplesToWrite {
                        let sample = int16ChannelData[cursor + sampleIndex]
                        outputBuffer[outputIndex] = Float(sample) / 32768.0
                        outputIndex += 1
                    }

                    cursor += samplesToWrite

                    if cursor >= currentBuffer.count / 2 {
                        self.currentBuffer = nil
                    }
                }
            }

            outputs[outputChannel] = outputBuffer

            if finished != isFinished {
                finished = isFinished
                onProcess?(isFinished)
            }
        }

        public func handleMessage(_ message: [String: Any]) {
            guard let type = message["type"] as? String else { return }

            switch type {
            case "buffer":
                if let buffer = message["buffer"] as? Data {
                    wasInterrupted = false
                    buffers.append(buffer)
                }
            case "interrupt":
                wasInterrupted = true
            case "clearInterrupted":
                if wasInterrupted {
                    wasInterrupted = false
                    buffers.removeAll()
                    currentBuffer = nil
                }
            default:
                break
            }
        }
    }

    // MARK: - Connection

    public class Connection: @unchecked Sendable {
        public let conversationId: String
        public let sampleRate: Int
        
        // WebRTC components
        private let peerConnection: RTCPeerConnection
        private let dataChannel: RTCDataChannel
        private let audioTrack: RTCAudioTrack

        private init(peerConnection: RTCPeerConnection, 
                   dataChannel: RTCDataChannel, 
                   audioTrack: RTCAudioTrack, 
                   conversationId: String, 
                   sampleRate: Int) {
            self.peerConnection = peerConnection
            self.dataChannel = dataChannel
            self.audioTrack = audioTrack
            self.conversationId = conversationId
            self.sampleRate = sampleRate
        }

        public static func create(config: SessionConfig) async throws -> Connection {
            // Initialize WebRTC factory
            let factory = RTCPeerConnectionFactory()
            
            // Set up RTCConfiguration with ICE servers
            let rtcConfig = RTCConfiguration()
            rtcConfig.iceServers = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
            
            // Create peer connection
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            guard let peerConnection = factory.peerConnection(with: rtcConfig, constraints: constraints, delegate: nil) else {
                throw OutspeedError.failedToCreateDataChannel
            }
            
            // Create data channel
            let dataChannelConfig = RTCDataChannelConfiguration()
            guard let dataChannel = peerConnection.dataChannel(forLabel: "oai-events", configuration: dataChannelConfig) else {
                throw OutspeedError.failedToCreateDataChannel
            }
            
            // Create audio track
            let audioConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            let audioSource = factory.audioSource(with: audioConstraints)
            let audioTrack = factory.audioTrack(with: audioSource, trackId: "audio0")
            
            // Create a media stream and add the audio track
            let streamId = "stream-\(UUID().uuidString)"
            let mediaStream = factory.mediaStream(withStreamId: streamId)
            mediaStream.addAudioTrack(audioTrack)
            
            // Add the media stream to the peer connection
            peerConnection.add(audioTrack, streamIds: [streamId])
            
            // Generate a conversation ID
            let conversationId = UUID().uuidString
            
            // Create and return the Connection object
            return Connection(
                peerConnection: peerConnection,
                dataChannel: dataChannel,
                audioTrack: audioTrack,
                conversationId: conversationId,
                sampleRate: Int(Constants.sampleRate)
            )
        }

        public func close() {
            peerConnection.close()
        }
        
        public func sendData(_ data: Data) {
            let buffer = RTCDataBuffer(data: data, isBinary: false)
            dataChannel.sendData(buffer)
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
        private let connection: Connection
        private let input: Input
        private let output: Output
        private let callbacks: Callbacks
        private let config: SessionConfig
        private let webRTCManager: WebRTCManager

        private let modeLock = NSLock()
        private let statusLock = NSLock()
        private let volumeLock = NSLock()
        private let isProcessingInputLock = NSLock()

        private var inputVolumeUpdateTimer: Timer?
        private let inputVolumeUpdateInterval: TimeInterval = 0.1 // Update every 100ms
        private var currentInputVolume: Float = 0.0

        private var _mode: Mode = .listening
        private var _status: Status = .connecting
        private var _volume: Float = 1.0
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

        private var isProcessingInput: Bool {
            get { isProcessingInputLock.withLock { _isProcessingInput } }
            set { isProcessingInputLock.withLock { _isProcessingInput = newValue } }
        }

        private var audioBuffers: [AVAudioPCMBuffer] = []
        private let audioBufferLock = NSLock()

        private let audioProcessor = OutspeedSDK.AudioProcessor()
        private var outputBuffers: [[Float]] = [[]]

        private let logger = Logger(subsystem: "com.outspeed.OutspeedSDK", category: "Conversation")

        private init(connection: Connection, input: Input, output: Output, webRTCManager: WebRTCManager, callbacks: Callbacks, config: SessionConfig) {
            self.connection = connection
            self.input = input
            self.output = output
            self.webRTCManager = webRTCManager
            self.callbacks = callbacks
            self.config = config

            // Set the onProcess callback
            audioProcessor.onProcess = { [weak self] finished in
                guard let self = self else { return }
                if finished {
                    self.updateMode(.listening)
                }
            }

            setupAudioProcessing()
            setupInputVolumeMonitoring()
        }

        /// Starts a new conversation session
        /// - Parameters:
        ///   - config: Session configuration
        ///   - callbacks: Callbacks for conversation events
        /// - Returns: A started `Conversation` instance
        public static func startSession(config: SessionConfig, callbacks: Callbacks = Callbacks()) async throws -> Conversation {
            // Step 1: Configure the audio session
            try OutspeedSDK.configureAudioSession()

            // Step 2: Create the WebRTC manager
            let webRTCManager = WebRTCManager(apiKey: config.apiKey )
            
            // Step 3: Create the WebRTC connection
            let connection = try await Connection.create(config: config)

            // Step 4: Create the audio input
            let input = try await Input.create(sampleRate: Constants.inputSampleRate)

            // Step 5: Create the audio output
            let output = try await Output.create(sampleRate: Double(connection.sampleRate))

            // Step 6: Initialize the Conversation
            let conversation = Conversation(
                connection: connection, 
                input: input, 
                output: output, 
                webRTCManager: webRTCManager,
                callbacks: callbacks, 
                config: config
            )

            // Step 7: Start playing audio (implicitly activates session and engine)
            try output.startPlaying()
            conversation.logger.info("Audio engine started.")
            
            // Step 7.5: Apply speaker output override for older devices if needed
            DeviceUtility.applySpeakerOverrideIfNeeded()

            // Step 8: Start WebRTC connection
            webRTCManager.startConnection(
                apiKey: config.apiKey,
                modelName: config.modelName,
                systemMessage: config.systemInstructions,
                voice: config.voice,
                provider: config.provider
            )

            // Step 9: Start recording
            conversation.startRecording()

            return conversation
        }

        private func setupInputVolumeMonitoring() {
            DispatchQueue.main.async {
                self.inputVolumeUpdateTimer = Timer.scheduledTimer(withTimeInterval: self.inputVolumeUpdateInterval, repeats: true) { [weak self] _ in
                    guard let self = self else { return }
                    self.callbacks.onVolumeUpdate(self.currentInputVolume)
                }
            }
        }

        private func setupAudioProcessing() {
            input.setRecordCallback { [weak self] buffer, rms in
                guard let self = self, self.isProcessingInput else { return }
                
                // Convert buffer to format needed by WebRTC
                if let int16ChannelData = buffer.int16ChannelData {
                    let frameCount = Int(buffer.frameLength)
                    let totalBytes = frameCount * MemoryLayout<Int16>.size
                    let data = Data(bytes: int16ChannelData[0], count: totalBytes)
                    
                    // Send the audio data to the WebRTC connection
                    self.webRTCManager.sendAudioData(data)
                }
                
                // Update volume level
                self.currentInputVolume = rms
                
                // Notify volume changes if needed
                DispatchQueue.main.async {
                    self.callbacks.onVolumeUpdate(rms)
                }
            }
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

        /// Send a text message
        public func sendMessage(_ text: String) {
            webRTCManager.outgoingMessage = text
            webRTCManager.sendMessage()
        }

        /// Ends the current conversation session
        public func endSession() {
            guard status == .connected else { return }

            updateStatus(.disconnecting)
            webRTCManager.stopConnection()
            connection.close()
            input.close()
            output.close()
            updateStatus(.disconnected)

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

    /// Defines errors specific to OutspeedSDK
    public enum OutspeedError: Error, LocalizedError {
        case invalidConfiguration
        case invalidURL
        case failedToCreateAudioFormat
        case failedToCreateAudioComponent
        case failedToCreateAudioComponentInstance
        case failedToCreateDataChannel

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
            case .failedToCreateDataChannel:
                return "Failed to create WebRTC data channel."
            }
        }
    }

    // MARK: - Audio Session Configuration

    private static func configureAudioSession() throws {
        let audioSession = AVAudioSession.sharedInstance()
        let logger = Logger(subsystem: "com.outspeed.OutspeedSDK", category: "AudioSession")

        do {
            // Configure with .voiceChat mode
            let sessionMode: AVAudioSession.Mode = .voiceChat
            logger.info("Configuring session with category: .playAndRecord, mode: .voiceChat")
            try audioSession.setCategory(.playAndRecord, mode: sessionMode, options: [.defaultToSpeaker, .allowBluetooth])

            // Keep preferred settings
            try audioSession.setPreferredIOBufferDuration(Constants.ioBufferDuration)
            logger.debug("Set preferred IO buffer duration to \(Constants.ioBufferDuration)")

            try audioSession.setPreferredSampleRate(Constants.inputSampleRate)
            logger.debug("Set preferred sample rate to \(Constants.inputSampleRate)")

            // Set input gain if possible
            if audioSession.isInputGainSettable {
                try audioSession.setInputGain(1.0)
                logger.debug("Set input gain to 1.0")
            } else {
                logger.debug("Input gain is not settable.")
            }

            // Activate the session
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            logger.info("Audio session configured and activated.")

        } catch {
            logger.error("Failed to configure audio session: \(error.localizedDescription)")
            print("OutspeedSDK: Failed to configure audio session: \(error.localizedDescription)")
            throw error
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
