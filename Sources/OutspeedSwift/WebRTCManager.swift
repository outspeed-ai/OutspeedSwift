import WebRTC
// Include necessary imports
import Foundation
import AVFoundation
import SwiftUI

import os

let logger = Logger(subsystem: "com.outspeed.outspeed-swift", category: "WebRTCManager")    

// MARK: - WebRTCManager
public class WebRTCManager: NSObject, ObservableObject {
    // UI State
    @Published public var connectionStatus: OutspeedSDK.Status = .disconnected
    @Published public var eventTypeStr: String = ""
    
    // Basic conversation text
    @Published public var conversation: [OutspeedSDK.ConversationItem] = []
    @Published public var outgoingMessage: String = ""
    
    // We'll store items by item_id for easy updates
    private var conversationMap: [String : OutspeedSDK.ConversationItem] = [:]
    
    // Model & session config
    private var modelName: String = "gpt-4o-mini-realtime-preview-2024-12-17"
    private var systemInstructions: String = ""
    private var voice: String = "alloy"
    private var provider: Provider = .openai
    
    // WebRTC references
    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    private var audioTrack: RTCAudioTrack?
    
    // Outspeed WebSocket reference
    private var outspeedWebSocket: URLSessionWebSocketTask?
    
    // Buffer for ICE candidates when WebSocket is not ready
    private var pendingIceCandidates: [RTCIceCandidate] = []
    
    // Flag to track if a layout update is in progress
    private var isUpdatingUI = false
    private var callbacks = OutspeedSDK.Callbacks()
    public var conversationId: String = ""
    
    // MARK: - Public Properties
    // MARK: - Public Methods
    
    /// Start a WebRTC connection using a standard API key for local testing.
    public func startConnection(
        config: OutspeedSDK.SessionConfig,
        apiKey: String,
        callbacks: OutspeedSDK.Callbacks,
        provider: Provider = .openai
    ) {

        self.connectionStatus = .connecting
        self.callbacks.onStatusChange(.connecting)

        conversation.removeAll()
        conversationMap.removeAll()
        
        // Store the callbacks
        self.callbacks = callbacks
        
        // Store updated config
        self.provider = provider
        
        setupPeerConnection()
        setupLocalAudio()
        configureAudioSession()
        
        guard let peerConnection = peerConnection else { 
            self.connectionStatus = .disconnected
            self.callbacks.onStatusChange(.disconnected)
            self.callbacks.onDisconnect()
            return 
        }
        
        // Create a Data Channel for sending/receiving events
        let config = RTCDataChannelConfiguration()
        if let channel = peerConnection.dataChannel(forLabel: "oai-events", configuration: config) {
            dataChannel = channel
            dataChannel?.delegate = self
        }
        
        // Create an SDP offer
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: ["levelControl": "true"],
            optionalConstraints: nil
        )
        peerConnection.offer(for: constraints) { [weak self] sdp, error in
            guard let self = self,
                  let sdp = sdp,
                  error == nil else {
                self?.callbacks.onError("Failed to create offer: \(String(describing: error))", nil)
                print("Failed to create offer: \(String(describing: error))")
                self?.connectionStatus = .disconnected
                self?.callbacks.onStatusChange(.disconnected)
                self?.callbacks.onDisconnect()
                return
            }
            // Set local description
            peerConnection.setLocalDescription(sdp) { [weak self] error in
                guard let self = self, error == nil else {
                    self?.callbacks.onError("Failed to set local description: \(String(describing: error))", nil)
                    print("Failed to set local description: \(String(describing: error))")
                    self?.connectionStatus = .disconnected
                    self?.callbacks.onStatusChange(.disconnected)
                    self?.callbacks.onDisconnect()
                    return
                }
                
                // Capture only the SDP string (a Sendable value) to avoid capturing the non-Sendable peerConnection reference.
                guard let localSdp = peerConnection.localDescription?.sdp else {
                    self.callbacks.onError("Failed to obtain local SDP", nil)
                    self.connectionStatus = .disconnected
                    self.callbacks.onStatusChange(.disconnected)
                    self.callbacks.onDisconnect()
                    return
                }
                
                Task { @MainActor [weak self, localSdp] in
                    // Create an immutable local copy of callbacks to prevent data races
                    let localCallbacks = self?.callbacks
                    do {
                        // Handle connection based on provider
                        switch self?.provider {
                        case .openai:
                            let answerSdp = try await self?.fetchRemoteSDPOpenAI(apiKey: apiKey, localSdp: localSdp)
                            if let answerSdp = answerSdp {
                                await self?.setRemoteDescription(answerSdp)
                            } else {
                                localCallbacks?.onError("Failed to get SDP answer from server", nil)
                            }
                        case .outspeed:
                            // First get ephemeral key
                            let ephemeralKey = try await self?.getEphemeralKeyOutspeed(apiKey: apiKey)
                            if let ephemeralKey = ephemeralKey {
                                // Then establish WebRTC connection
                                try await self?.fetchRemoteSDPOutspeed(ephemeralKey: ephemeralKey, localSdp: localSdp)
                            } else {
                                localCallbacks?.onError("Failed to get ephemeral key from server", nil)
                            }
                        case .none:
                            localCallbacks?.onError("Provider not set", nil)
                        }
                    } catch {
                        // Use the local copy of callbacks here
                        localCallbacks?.onError("Error in connection process: \(error)", nil)
                        print("Error in connection process: \(error)")
                        self?.connectionStatus = .disconnected
                        localCallbacks?.onStatusChange(.disconnected)
                        localCallbacks?.onDisconnect()
                    }
                }
            }
        }
    }
    
    func stopConnection() {
        peerConnection?.close()
        peerConnection = nil
        dataChannel = nil
        audioTrack = nil
        
        // Cancel any active WebSocket
        outspeedWebSocket?.cancel(with: .normalClosure, reason: nil)
        outspeedWebSocket = nil
        
        // DispatchQueue.main.async { [weak self] in
        //     self?.connectionStatus = .disconnected
        //     self?.callbacks.onStatusChange(.disconnected)
        // }
    }
    
    /// Sends a custom "conversation.item.create" event
    public func sendMessage() {
        guard let dc = dataChannel,
              !outgoingMessage.trimmingCharacters(in: .whitespaces).isEmpty else {
            return
        }
        
        let realtimeEvent: [String: Any] = [
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [
                    [
                        "type": "input_text",
                        "text": outgoingMessage
                    ]
                ]
            ]
        ]
        if let jsonData = try? JSONSerialization.data(withJSONObject: realtimeEvent) {
            let buffer = RTCDataBuffer(data: jsonData, isBinary: false)
            dc.sendData(buffer)
            self.outgoingMessage = ""
            createResponse()
        }
    }
    
    /// Sends a "response.create" event
    func createResponse() {
        guard let dc = dataChannel else { return }
        
        let realtimeEvent: [String: Any] = [ "type": "response.create" ]
        if let jsonData = try? JSONSerialization.data(withJSONObject: realtimeEvent) {
            let buffer = RTCDataBuffer(data: jsonData, isBinary: false)
            dc.sendData(buffer)
        }
    }
    
    /// Called automatically when data channel opens, or you can manually call it.
    /// Updates session configuration with the latest instructions and voice.
    @MainActor
    func sendSessionUpdate() {
        guard let dc = dataChannel, dc.readyState == .open else {
            print("Data channel is not open. Cannot send session.update.")
            return
        }
        
        // Create a local copy of callbacks to prevent data races
        let localCallbacks = self.callbacks
        
        // Declare sessionUpdate outside of conditional blocks
        let sessionUpdate: [String: Any]
        
        if provider == .outspeed {
            sessionUpdate = [
                "type": "session.update",
                "session": [
                    "modalities": ["text", "audio"],  // Enable both text and audio
                    "instructions": systemInstructions,
                    "voice": "tara",
                    "input_audio_transcription": [
                        "model": provider == .openai ? "whisper-1" : "whisper-v3-turbo"
                    ],
                    "turn_detection": [
                        "type": "server_vad",
                        "rms_threshold": 0.0,
                    ]
                ]
            ]
        } else {
            sessionUpdate = [
                "type": "session.update",
                "session": [
                    "modalities": ["text", "audio"],  // Enable both text and audio
                    "instructions": systemInstructions,
                    "voice": voice,
                    "input_audio_transcription": [
                        "model": provider == .openai ? "whisper-1" : "whisper-v3-turbo"
                    ],
                    "turn_detection": [
                        "type": "server_vad",
                    ]
                ]
            ]
        }
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: sessionUpdate)
            let buffer = RTCDataBuffer(data: jsonData, isBinary: false)
            dc.sendData(buffer)
            print("session.update event sent.")
        } catch {
            print("Failed to serialize session.update JSON: \(error)")
            localCallbacks.onError("Failed to serialize session.update JSON: \(error)", nil)
        }
    }
    
    // MARK: - Private Methods
    
    private func setupPeerConnection() {
        let config = RTCConfiguration()
        // Configure ICE servers with public STUN servers
        config.iceServers = [
            RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"]),
            RTCIceServer(urlStrings: ["stun:stun1.l.google.com:19302"])
        ]
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let factory = RTCPeerConnectionFactory()
        peerConnection = factory.peerConnection(with: config, constraints: constraints, delegate: self)
    }
    
    private func configureAudioSession() {
        // Create a local copy of callbacks to prevent data races
        let localCallbacks = self.callbacks
        
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth, .duckOthers])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            try audioSession.overrideOutputAudioPort(.speaker) // because some phones might not respect .defaultToSpeaker option & play through earpiece
        } catch {
            print("Failed to configure AVAudioSession: \(error)")
            localCallbacks.onError("Failed to configure AVAudioSession: \(error)", nil)
        }
    }
    
    private func setupLocalAudio() {
        guard let peerConnection = peerConnection else { return }
        let factory = RTCPeerConnectionFactory()
        
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "googEchoCancellation": "true",
                "googAutoGainControl": "true",
                "googNoiseSuppression": "true",
                "googHighpassFilter": "true",
            ],
            optionalConstraints: nil
        )
        
        let audioSource = factory.audioSource(with: constraints)
        
        let localAudioTrack = factory.audioTrack(with: audioSource, trackId: "local_audio")
        peerConnection.add(localAudioTrack, streamIds: ["local_stream"])
        audioTrack = localAudioTrack
    }
    
    private func setRemoteDescription(_ sdp: String) async {
        let answer = RTCSessionDescription(type: .answer, sdp: sdp)
        // Create a local copy of callbacks
        let localCallbacks = self.callbacks
        peerConnection?.setRemoteDescription(answer) { [weak self] error in
            DispatchQueue.main.async {
                if let error {
                    print("Failed to set remote description: \(error)")
//                    self?.connectionStatus = .disconnected
                    localCallbacks.onStatusChange(.disconnected)
                    localCallbacks.onError("Failed to set remote description: \(error)", nil)
                } else {
//                    self?.connectionStatus = .connected
                    localCallbacks.onStatusChange(.connected)
                }
            }
        }
    }
    
    /// Get ephemeral key from Outspeed server
    private func getEphemeralKeyOutspeed(apiKey: String) async throws -> String {
        let outspeed_url = ProcessInfo.processInfo.environment["OUTSPEED_API_URL"] ?? provider.baseURL
        let baseUrl = "https://\(outspeed_url)/v1/realtime/sessions"
        guard let url = URL(string: baseUrl) else {
            throw URLError(.badURL)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        let sessionConfig: [String: Any]
        if provider == .outspeed {
            // Create session configuration
            sessionConfig = [
                "model": "Orpheus-3b",
                "modalities": ["text", "audio"],
                "instructions": systemInstructions,
                "voice": "tara",
                "input_audio_format": "pcm16",
                "output_audio_format": "pcm16",
                "input_audio_transcription": [
                    "model": "whisper-v3-turbo"
                ],
                "turn_detection": [
                    "type": "server_vad",
                    "rms_threshold": 0.0,
                ]
            ]
        } else {
            sessionConfig = [
                "model": modelName,
                "modalities": ["text", "audio"],
                "instructions": systemInstructions,
                "voice": voice,
                "input_audio_format": "pcm16",
                "output_audio_format": "pcm16",
                "input_audio_transcription": [
                    "model": "whisper-v3-turbo"
                ],
                "turn_detection": [
                    "type": "server_vad",
                ]
            ]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: sessionConfig)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        // Log the raw server response
        if let responseString = String(data: data, encoding: .utf8) {
            print("[Outspeed] getEphemeralKeyOutspeed server response: \(responseString)")
        }
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "WebRTCManager.getEphemeralKeyOutspeed",
                          code: code,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid server response"])
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let clientSecret = json["client_secret"] as? [String: Any],
              let value = clientSecret["value"] as? String else {
            throw NSError(domain: "WebRTCManager.getEphemeralKeyOutspeed",
                          code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid response format"])
        }
        
        print("[Outspeed] Received clientSecret: \(value)")
        return value
    }
    
    /// Handle OpenAI SDP exchange
    private func fetchRemoteSDPOpenAI(apiKey: String?, localSdp: String) async throws -> String {
        let baseUrl = "https://\(provider.baseURL)/v1/realtime"
        guard let url = URL(string: "\(baseUrl)?model=\(modelName)") else {
            throw URLError(.badURL)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        print("[Outspeed] Sending SDP to OpenAI: \(localSdp)")
        request.httpBody = localSdp.data(using: .utf8)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "WebRTCManager.fetchRemoteSDPOpenAI",
                          code: code,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid server response"])
        }
        
        guard let answerSdp = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "WebRTCManager.fetchRemoteSDPOpenAI",
                          code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Unable to decode SDP"])
        }
        
        print("[Outspeed] Received SDP from OpenAI: \(answerSdp)")

        return answerSdp
    }
    
    /// Handle Outspeed WebSocket-based SDP exchange
    private func fetchRemoteSDPOutspeed(ephemeralKey: String, localSdp: String) async throws {
        let wsUrl = "wss://\(provider.baseURL)/v1/realtime/ws?client_secret=\(ephemeralKey)"
        guard let url = URL(string: wsUrl) else {
            throw URLError(.badURL)
        }

        print("[Outspeed] Connecting to WebSocket URL: \(wsUrl)")

        let webSocket = URLSession.shared.webSocketTask(with: url)
        // Store WebSocket reference for ICE candidate sending
        self.outspeedWebSocket = webSocket
        // Clear any pending candidates from previous connection attempts
        
        print("[Outspeed] WebSocket connection initiated")
        webSocket.resume() // Starts the asynchronous connection process
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            
            func receiveMessage() {
                webSocket.receive { [weak self] result in
                    guard let self = self else {
                        print("[Outspeed][WebSocket] Self is nil, aborting receiveMessage.")
                        continuation.resume(throwing: NSError(domain: "WebRTCManager.fetchRemoteSDPOutspeed", code: -2, userInfo: [NSLocalizedDescriptionKey: "WebRTCManager deallocated during WebSocket operation"]))
                        return
                    }

                    switch result {
                    case .success(let message):
                        switch message {
                        case .string(let text):
                            guard let data = text.data(using: .utf8),
                                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                                  let type = json["type"] as? String else {
                                print("[Outspeed][WebSocket] Failed to parse received JSON string.")
                                receiveMessage() 
                                return
                            }

                            switch type {
                            case "pong":
                                print("[Outspeed][WebSocket] Pong received. Sending offer...")
                                let offerMessagePayload = ["type": "offer", "sdp": localSdp]
                                guard let offerData = try? JSONSerialization.data(withJSONObject: offerMessagePayload),
                                      let offerString = String(data: offerData, encoding: .utf8) else {
                                    continuation.resume(throwing: NSError(domain: "WebRTCManager.fetchRemoteSDPOutspeed", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to serialize offer message to string"]))
                                    return
                                }
                                webSocket.send(.string(offerString)) { error in
                                    if let error {
                                        print("[Outspeed][WebSocket] Failed to send offer: \(error)")
                                        continuation.resume(throwing: error)
                                    } else {
                                        print("[Outspeed][WebSocket] Offer sent. Waiting for answer...")
                                        receiveMessage() 
                                    }
                                }
                            case "answer":
                                print("[Outspeed][WebSocket] Answer received.")
                                if let sdp = json["sdp"] as? String {
                                    Task { @MainActor [weak self] in
                                        await self?.setRemoteDescription(sdp)
                                        
                                        // Send any pending ICE candidates after answer is received
                                        self?.sendPendingIceCandidates()
                                        
                                        continuation.resume() 
                                    }
                                } else {
                                    continuation.resume(throwing: NSError(domain: "WebRTCManager.fetchRemoteSDPOutspeed", code: -1, userInfo: [NSLocalizedDescriptionKey: "Answer message missing SDP"]))
                                }
                            case "candidate":
                                print("[Outspeed][WebSocket] Candidate received.")
                                if let candidateString = json["candidate"] as? String,
                                   let sdpMid = json["sdpMid"] as? String,
                                   let sdpMLineIndex = json["sdpMLineIndex"] as? Int {
                                    let iceCandidate = RTCIceCandidate(
                                        sdp: candidateString,
                                        sdpMLineIndex: Int32(sdpMLineIndex),
                                        sdpMid: sdpMid
                                    )
                                    self.peerConnection?.add(iceCandidate) { error in
                                        if let error = error {
                                            print("[Outspeed][WebSocket] Failed to add ICE candidate: \(error)")
                                        }
                                    }
                                    receiveMessage() 
                                } else {
                                    print("[Outspeed][WebSocket] Malformed candidate received.")
                                    receiveMessage() 
                                }
                            case "error": 
                                let errorMessage = json["message"] as? String ?? "Unknown server error"
                                print("[Outspeed][WebSocket] Server error message: \(errorMessage)")
                                continuation.resume(throwing: NSError(
                                    domain: "WebRTCManager.fetchRemoteSDPOutspeed.ServerError",
                                    code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: errorMessage]
                                ))
                            default:
                                print("[Outspeed][WebSocket] Unknown message type received: \(type)")
                                receiveMessage() 
                            }
                        case .data(let data):
                            print("[Outspeed][WebSocket] Received binary data (unexpected): \(data as NSData)")
                            receiveMessage() 
                        @unknown default:
                            print("[Outspeed][WebSocket] Unknown message format received.")
                            receiveMessage() 
                        }
                    case .failure(let error):
                        print("[Outspeed][WebSocket] Receive operation failed: \(error)")
                        continuation.resume(throwing: error)
                    }
                }
            } 

            let pingMessagePayload = ["type": "ping"]
            guard let pingData = try? JSONSerialization.data(withJSONObject: pingMessagePayload),
                  let pingString = String(data: pingData, encoding: .utf8) else {
                continuation.resume(throwing: NSError(domain: "WebRTCManager.fetchRemoteSDPOutspeed", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to serialize ping message to string"]))
                return
            }
            
            print("[Outspeed][WebSocket] Sending initial ping as string: \(pingString)")
            webSocket.send(.string(pingString)) { error in
                if let error {
                    print("[Outspeed][WebSocket] Failed to send initial ping: \(error)")
                    continuation.resume(throwing: error)
                } else {
                    print("[Outspeed][WebSocket] Initial ping sent successfully. Waiting for pong...")
                    receiveMessage()
                }
            }
        }
    }
    
    @MainActor
    private func handleIncomingJSON(_ jsonString: String) {        
        // Create a local copy of callbacks to prevent data races
        let localCallbacks = self.callbacks
        
        guard let data = jsonString.data(using: .utf8),
              let rawEvent = try? JSONSerialization.jsonObject(with: data),
              let eventDict = rawEvent as? [String: Any],
              let eventType = eventDict["type"] as? String else {
            return
        }
        
        eventTypeStr = eventType
        
        // Set flag to batch UI updates
        isUpdatingUI = true
        defer { 
            // Ensure flag is reset even if processing throws an error
            isUpdatingUI = false
        }
        
        switch eventType {
        case "conversation.item.created":
            if let item = eventDict["item"] as? [String: Any],
               let itemId = item["id"] as? String,
               let role = item["role"] as? String
            {
                // If item contains "content", extract the text
                let text = (item["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
                
                let newItem = OutspeedSDK.ConversationItem(id: itemId, role: role, text: text)
                conversationMap[itemId] = newItem
                if role == "assistant" || role == "user" {
                    // Create a safe copy of the conversation array to prevent concurrent modification
                    var updatedConversation = conversation
                    updatedConversation.append(newItem)
                    conversation = updatedConversation
                }
            }
            
        case "response.audio_transcript.delta":
            // partial transcript for assistant's message
            if let itemId = eventDict["item_id"] as? String,
               let delta = eventDict["delta"] as? String
            {
                if var convItem = conversationMap[itemId] {
                    convItem.text += delta
                    conversationMap[itemId] = convItem
                    
                    // Safe update of the conversation array
                    if let idx = conversation.firstIndex(where: { $0.id == itemId }) {
                        var updatedConversation = conversation
                        updatedConversation[idx].text = convItem.text
                        conversation = updatedConversation
                    }
                }
            }
            
        case "response.audio_transcript.done":
            // final transcript for assistant's message
            if let itemId = eventDict["item_id"] as? String,
               let transcript = eventDict["transcript"] as? String
            {
                if var convItem = conversationMap[itemId] {
                    convItem.text = transcript
                    conversationMap[itemId] = convItem
                    
                    // Safe update of the conversation array
                    if let idx = conversation.firstIndex(where: { $0.id == itemId }) {
                        var updatedConversation = conversation
                        updatedConversation[idx].text = transcript
                        conversation = updatedConversation
                    }
                }
                localCallbacks.onMessage(transcript, .ai)
            }
            
        case "conversation.item.input_audio_transcription.completed":
            // final transcript for user's audio input
            if let itemId = eventDict["item_id"] as? String,
               let transcript = eventDict["transcript"] as? String
            {
                if var convItem = conversationMap[itemId] {
                    convItem.text = transcript
                    conversationMap[itemId] = convItem
                    
                    // Safe update of the conversation array
                    if let idx = conversation.firstIndex(where: { $0.id == itemId }) {
                        var updatedConversation = conversation
                        updatedConversation[idx].text = transcript
                        conversation = updatedConversation
                    }
                }
                localCallbacks.onMessage(transcript, .user)
            }
            
        default:
            break
        }
    }
    

    public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        if provider == .outspeed {
            if let webSocket = outspeedWebSocket, webSocket.state == .running {
                sendIceCandidate(candidate)
            } else {
                pendingIceCandidates.append(candidate)
            }
        }
    }
    
    // Helper method to send a single ICE candidate
    private func sendIceCandidate(_ candidate: RTCIceCandidate) {
        guard let webSocket = outspeedWebSocket, webSocket.state == .running else {
            logger.debug("[Outspeed] WebSocket not available, cannot send ICE candidate")
            return
        }
        
        // Create a local copy of callbacks to prevent data races
        let localCallbacks = self.callbacks
        
        // Format the ICE candidate message
        let candidateMessage: [String: Any] = [
            "type": "candidate",
            "candidate": candidate.sdp,
            "sdpMid": candidate.sdpMid ?? "",
            "sdpMLineIndex": Int(candidate.sdpMLineIndex)
        ]
        
        // Send to the WebSocket server
        guard let candidateData = try? JSONSerialization.data(withJSONObject: candidateMessage),
              let candidateString = String(data: candidateData, encoding: .utf8) else {
            logger.error("[Outspeed] Failed to serialize ICE candidate")
            return
        }
        
        webSocket.send(.string(candidateString)) { error in
            if let error {
                localCallbacks.onError("Failed to send ICE candidate: \(error)", nil)
                logger.error("[Outspeed] Failed to send ICE candidate: \(error)")
            }
        }
    }
    
    // Helper method to send all pending ICE candidates
    private func sendPendingIceCandidates() {
        logger.debug("[Outspeed] Sending buffered ICE candidates")
        guard !pendingIceCandidates.isEmpty else {
            return
        }
        
        for candidate in pendingIceCandidates {
            sendIceCandidate(candidate)
        }
        pendingIceCandidates.removeAll()
    }

    func getConnectionStatus() -> OutspeedSDK.Status {
        return connectionStatus
    }
}

// MARK: - RTCPeerConnectionDelegate
extension WebRTCManager: RTCPeerConnectionDelegate {
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    
    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        let stateName: String
        // Create a local copy of callbacks to prevent data races
        let localCallbacks = self.callbacks
        
        switch newState {
        case .new:
            stateName = "new"
        case .checking:
            stateName = "checking"
            localCallbacks.onStatusChange(.connecting)
        case .connected:
            stateName = "connected"
            localCallbacks.onConnect("")
            localCallbacks.onStatusChange(.connected)

        case .completed:
            stateName = "completed"
            localCallbacks.onStatusChange(.connected)

        case .failed:
            stateName = "failed"
            localCallbacks.onDisconnect()
            localCallbacks.onError("ICE Connection failed", nil)
            localCallbacks.onStatusChange(.disconnected)

        case .disconnected:
            stateName = "disconnected"
            localCallbacks.onDisconnect()
            localCallbacks.onStatusChange(.disconnected)

        case .closed:
            stateName = "closed"
            localCallbacks.onDisconnect()
            localCallbacks.onStatusChange(.disconnected)
        case .count:
            stateName = "count"
        @unknown default:
            stateName = "unknown"
        }
        logger.info("ICE Connection State changed to: \(stateName)")
    }
    
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    
    public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        // If the server creates the data channel on its side, handle it here
        dataChannel.delegate = self
    }
}

// MARK: - RTCDataChannelDelegate
extension WebRTCManager: RTCDataChannelDelegate {
    public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        logger.info("Data channel state changed: \(String(describing: dataChannel.readyState))")
        // Auto-send session.update after channel is open
        if dataChannel.readyState == .open {
            Task { @MainActor [weak self] in
                await self?.sendSessionUpdate()
            }
        }
    }
    
    public func dataChannel(_ dataChannel: RTCDataChannel,
                     didReceiveMessageWith buffer: RTCDataBuffer) {
        guard let message = String(data: buffer.data, encoding: .utf8) else {
            return
        }
        Task { @MainActor [weak self] in
            await self?.handleIncomingJSON(message)
        }
    }
}

// Provide Sendable conformance explicitly. WebRTCManager manages its own thread safety by confining mutable state to the main thread or through synchronization where needed.
extension WebRTCManager: @unchecked Sendable {}
