import SwiftUI
import Starscream


// Model Definitions
struct AppState: Codable {
    var machineId: String
    var username: String
    var messages: [Message]
}

struct Message: Codable {
    let content: String
    let role: String // user, assistant, or system
}


// WebSocket Definitions
struct WebSocketMessage: Codable {
    let type: String
    let state: AppState
}




// SwiftUI Views

struct ChatView: View {
    @Binding var appState: AppState
    @State var newMessage: String = ""
    var conn: ConnectionManager

    func saveState(appState: AppState) {
        conn.send(WebSocketMessage(type: "state", state: appState))
    }

    func send() {
        guard !newMessage.isEmpty else { return }
        appState.messages.append(Message(content: newMessage, role: "user"))
        self.saveState(appState: appState)
        DispatchQueue.main.async { newMessage = "" }
    }

    var body: some View {
        VStack {
            List(0..<appState.messages.count, id: \.self) { i in
                MessageView(message: appState.messages[i])
            }

            HStack {
                TextField("New message", text: $newMessage)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .onSubmit { self.send() }

                Button("Send") { self.send() }
            }
            .padding()
        }
        .onAppear {
            self.saveState(appState: appState)
            conn.onMessageCallback = { msg in
                switch msg.type {
                case "state":
                    print("Received state: \(msg.state)")
                    // TODO: Check creation time and only update if newer
                    self.appState = msg.state
                default:
                    print("Unknown message type: \(msg.type)")
                }
            }
        }
        .onDisappear {
            self.saveState(appState: appState)
        }
    }
}

struct MessageView: View {
    let message: Message

    var body: some View {
        HStack {
            Spacer()
            Text(message.content)
                .padding(.vertical, 5)
                .padding(.horizontal, 10)
                .foregroundColor(.white)
                .background(
                    message.role == "user" ? Color.blue
                    : message.role == "assistant" ? Color.gray
                    : Color.red
                )
                .cornerRadius(10)
        }
    }
}

// WebSocket Implementation that automatically buffers messages and reconnects 
class ConnectionManager {
    private var bufferedMessages: [String] = []
    private var isConnected: Bool = false
    private var reconnectionTimer: Timer?
    private var ws: WebSocket!
    private var url = URL(string: "http://localhost:8000/ws")!
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public var onMessageCallback: (WebSocketMessage) -> Void = { _ in }

    init() {
        // should have compromised and used snake_case in the model, but I didn't,
        // and now that I figured out how to do this, I'm not changing it ;)
        encoder.keyEncodingStrategy = .convertToSnakeCase
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.attemptReconnect()
    }

    func send(_ msg: WebSocketMessage) {
        if let data = try? encoder.encode(msg),
            let text = String(data: data, encoding: .utf8) {
            self.write(string: text)
        }
    }

    private func write(string: String) {
        if isConnected {
            print("Sending: \(string)")
            ws.write(string: string)
        } else {
            print("Buffering: \(string)")
            bufferedMessages.append(string)
        }
    }

    private func connect() {
        self.ws = WebSocket(request: URLRequest(url: url))
        self.ws.onEvent = { event in
            self.didReceive(event: event, client: self.ws)
        }
        self.ws.connect()
    }

    private func attemptReconnect() {
        guard reconnectionTimer == nil else { return }
        reconnectionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            print("Attempting reconnect...")
            self.connect()
        }
    }

    private func disconnected() {
        self.isConnected = false
        self.ws.disconnect()
        self.attemptReconnect()
    }

    private func connected() {
        print("Connected!")
        isConnected = true
        if let timer = reconnectionTimer {
            timer.invalidate()
            reconnectionTimer = nil
        }

        // Flush buffered messages
        for message in bufferedMessages {
            self.write(string: message)
        }
        bufferedMessages.removeAll()
    }

    func didReceive(event: WebSocketEvent, client: WebSocket) {
        switch event {
        case .connected:
            self.connected()
        case .disconnected(_, _):
            self.disconnected()
        case .peerClosed:
            self.disconnected()
        case .cancelled:
            self.disconnected()
        case .viabilityChanged(let isViable):
            if !isViable { self.disconnected() }
        case .reconnectSuggested(let isSuggested):
            if isSuggested { self.disconnected() }
        case .error(_):
            print("WebSocket error: \(event)")
            self.disconnected()
        case .text(let text):
            // attempt to decode as WebSocketMessage
            let jsonData = Data(text.utf8)
            do {
                let msg = try decoder.decode(WebSocketMessage.self, from: jsonData)
                self.onMessageCallback(msg)
            } catch {
                print("Error decoding WebSocketMessage: \(error)")
                print("Error message json: \(text)")
            }
        default:
            // TODO: Handle other disconnection events
            print("Not handling \(event)")
            break
        }
    }
}


@main
struct MyApp: App {
    @State var appState = AppState(
        machineId: getMachineId(),
        username: NSUserName(),
        messages: []
    )
    var conn = ConnectionManager()

    var body: some Scene {
        WindowGroup {
            ChatView(appState: $appState, conn: conn)
        }
    }
}
