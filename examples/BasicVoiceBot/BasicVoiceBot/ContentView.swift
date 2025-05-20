import SwiftUI
import AVFoundation

let OPENAI_API_KEY = ""
let OUTSPEED_API_KEY = ""

struct ContentView: View {
    @StateObject private var webrtcManager = WebRTCManager()
    
    @State private var showOptionsSheet = false
    @FocusState private var isTextFieldFocused: Bool
    
    // AppStorage properties
    @AppStorage("openaiApiKey") private var openaiApiKey = OPENAI_API_KEY
    @AppStorage("outspeedApiKey") private var outspeedApiKey = OUTSPEED_API_KEY
    @AppStorage("systemMessage") private var systemMessage = Provider.outspeed.defaultSystemMessage
    @AppStorage("selectedModel") private var selectedModel = Provider.outspeed.defaultModel
    @AppStorage("selectedVoice") private var selectedVoice = Provider.outspeed.defaultVoice
    @AppStorage("selectedProvider") private var selectedProvider = Provider.outspeed.rawValue
    
    // Computed properties
    private var currentProvider: Provider {
        Provider(rawValue: selectedProvider) ?? .openai
    }
    
    private var currentApiKey: String {
        switch currentProvider {
        case .openai:
            return openaiApiKey
        case .outspeed:
            return outspeedApiKey
        }
    }
    
    private var modelOptions: [String] {
        currentProvider.modelOptions
    }
    
    private var voiceOptions: [String] {
        currentProvider.voiceOptions
    }
    
    var body: some View {
        VStack(spacing: 12) {
            HeaderView()
            ConnectionControls()
            Divider().padding(.vertical, 6)
            
            ConversationView()
            
            MessageInputView()
        }
        .onAppear(perform: requestMicrophonePermission)
        .sheet(isPresented: $showOptionsSheet) {
            OptionsView(
                openaiApiKey: $openaiApiKey,
                outspeedApiKey: $outspeedApiKey,
                systemMessage: $systemMessage,
                selectedModel: $selectedModel,
                selectedVoice: $selectedVoice,
                selectedProvider: $selectedProvider,
                modelOptions: modelOptions,
                voiceOptions: voiceOptions
            )
        }
    }
    
    private func requestMicrophonePermission() {
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            print("Microphone permission granted: \(granted)")
        }
        if currentApiKey.isEmpty {
            showOptionsSheet = true
        }
    }
    
    @ViewBuilder
    private func HeaderView() -> some View {
        VStack(spacing: 2) {
            Text("Advanced Voice Mode")
                .font(.system(size: 24, weight: .bold))
                .padding(.top, 12)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text("In Swift with WebRTC")
                .font(.system(size: 15, weight: .light))
                .padding(.bottom, 10)
        }
    }
    
    @ViewBuilder
    private func ConnectionControls() -> some View {
        HStack {
            // Connection status indicator
            Circle()
                .frame(width: 12, height: 12)
                .foregroundColor(webrtcManager.connectionStatus.color)
            Text(webrtcManager.connectionStatus.description)
                .foregroundColor(webrtcManager.connectionStatus.color)
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.3), value: webrtcManager.connectionStatus)
                .onChange(of: webrtcManager.connectionStatus) { _ in
                    switch webrtcManager.connectionStatus {
                    case .connecting:
                        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    case .connected:
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    case .disconnected:
                        webrtcManager.eventTypeStr = ""
                    }
                }
            
            Spacer()
            
            // Connection Button
            if webrtcManager.connectionStatus == .connected {
                Button("Stop Connection") {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    webrtcManager.stopConnection()
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Start Connection") {
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    webrtcManager.connectionStatus = .connecting
                    webrtcManager.startConnection(
                        apiKey: currentApiKey,
                        modelName: selectedModel,
                        systemMessage: systemMessage,
                        voice: selectedVoice,
                        provider: currentProvider
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(webrtcManager.connectionStatus == .connecting)
                Button {
                    showOptionsSheet.toggle()
                } label: {
                    Image(systemName: "gearshape")
                }
                .padding(.leading, 10)
            }
        }
        .padding(.horizontal)
    }
    
    // MARK: - Conversation View
    @ViewBuilder
    private func ConversationView() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Conversation")
                    .font(.headline)
                Spacer()
                Text(webrtcManager.eventTypeStr)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.leading, 16)
            }
            .padding(.horizontal)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(webrtcManager.conversation) { msg in
                        MessageRow(msg: msg)
                    }
                }
                .padding()
            }
        }
    }
    
    // MARK: - Message Row
    @ViewBuilder
    private func MessageRow(msg: ConversationItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: msg.roleSymbol)
                .foregroundColor(msg.roleColor)
                .padding(.top, 4)
            Text(msg.text.trimmingCharacters(in: .whitespacesAndNewlines))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.1), value: msg.text)
        }
        .contextMenu {
            Button("Copy") {
                UIPasteboard.general.string = msg.text
            }
        }
        .padding(.bottom, msg.role == "assistant" ? 24 : 8)
    }
    
    // MARK: - Message Input
    @ViewBuilder
    private func MessageInputView() -> some View {
        HStack {
            TextField("Insert message...", text: $webrtcManager.outgoingMessage, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .focused($isTextFieldFocused)
            Button("Send") {
                webrtcManager.sendMessage()
                isTextFieldFocused = false
            }
            .disabled(webrtcManager.connectionStatus != .connected)
            .buttonStyle(.bordered)
        }
        .padding([.horizontal, .bottom])
    }
}

struct OptionsView: View {
    @Binding var openaiApiKey: String
    @Binding var outspeedApiKey: String
    @Binding var systemMessage: String
    @Binding var selectedModel: String
    @Binding var selectedVoice: String
    @Binding var selectedProvider: String
    
    let modelOptions: [String]
    let voiceOptions: [String]
    
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Provider")) {
                    Picker("Provider", selection: $selectedProvider) {
                        Text("OpenAI").tag(Provider.openai.rawValue)
                        Text("Outspeed").tag(Provider.outspeed.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: selectedProvider) { newValue in
                        let newProvider = Provider(rawValue: newValue) ?? .openai
                        selectedModel = newProvider.defaultModel
                        selectedVoice = newProvider.defaultVoice
                    }
                }
                
                Section(header: Text("API Keys")) {
                    TextField("OpenAI API Key", text: $openaiApiKey)
                        .autocapitalization(.none)
                    TextField("Outspeed API Key", text: $outspeedApiKey)
                        .autocapitalization(.none)
                }
                
                Section(header: Text("System Message")) {
                    TextEditor(text: $systemMessage)
                        .frame(minHeight: 100)
                        .cornerRadius(5)
                }
                
                Section(header: Text("Model")) {
                    Picker("Model", selection: $selectedModel) {
                        ForEach(modelOptions, id: \.self) {
                            Text($0)
                        }
                    }
                    .pickerStyle(.menu)
                }
                
                Section(header: Text("Voice")) {
                    Picker("Voice", selection: $selectedVoice) {
                        ForEach(voiceOptions, id: \.self) {
                            Text($0.capitalized)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            .navigationTitle("Options")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Models and Enums

struct ConversationItem: Identifiable {
    let id: String       // item_id from the JSON
    let role: String     // "user" / "assistant"
    var text: String     // transcript
    
    var roleSymbol: String {
        role.lowercased() == "user" ? "person.fill" : "sparkles"
    }
    
    var roleColor: Color {
        role.lowercased() == "user" ? .blue : .purple
    }
}

enum ConnectionStatus: String {
    case connected
    case connecting
    case disconnected
    
    var color: Color {
        switch self {
        case .connected:
            return .green
        case .connecting:
            return .yellow
        case .disconnected:
            return .red
        }
    }
    
    var description: String {
        switch self {
        case .connected:
            return "Connected"
        case .connecting:
            return "Connecting"
        case .disconnected:
            return "Not Connected"
        }
    }
}

// MARK: - Preview

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
