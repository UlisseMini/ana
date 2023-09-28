import SwiftUI
import Starscream


// Model Definitions
struct AppState: Codable, Equatable {
    var machineId: String
    var username: String

    var messages: [Message]
    var settings: Settings
    var activity: Activity
}

struct Message: Codable, Equatable {
    let content: String
    let role: String // user, assistant, or system
}

struct PromptPair: Codable, Equatable {
    var trigger: String
    var response: String
}

struct Activity: Codable, Equatable {
    var visibleWindows: [Window]
}

struct Settings: Codable, Equatable {
    var prompts: [PromptPair]
    var checkInInterval: Int
}


// WebSocket Definitions
struct WebSocketMessage: Codable, Equatable {
    let type: String
    let state: AppState
}


// SwiftUI Views

struct ChatView: View {
    @Binding var appState: AppState
    @State var newMessage: String = "" // TODO: Move into AppState for telemetry
    var sync: StateSyncManager

    func send() {
        guard !newMessage.isEmpty else { return }
        appState.messages.append(Message(content: newMessage, role: "user"))
        sync.syncState(appState)
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


struct SettingsView: View {
    // maybe passing a copy & a callback from the parent is cleaner?
    @Binding var settings: Settings

    var body: some View {
        VStack {
            HStack {
                Text("Trigger Prompt")
                    .frame(maxWidth: .infinity)
                Text("Response Prompt")
                    .frame(maxWidth: .infinity)
            }
            .font(.headline)
            .padding([.top, .horizontal])
            
            List {
                ForEach(settings.prompts.indices, id: \.self) { index in
                    HStack {
                        TextEditor(text: $settings.prompts[index].trigger)
                            .frame(minHeight: 100)
                            .padding(4)
                            .background(RoundedRectangle(cornerRadius: 4).stroke(Color.gray))
                        
                        TextEditor(text: $settings.prompts[index].response)
                            .frame(minHeight: 100)
                            .padding(4)
                            .background(RoundedRectangle(cornerRadius: 4).stroke(Color.gray))
                    }
                    .padding([.vertical], 8)
                }
                .onDelete(perform: deleteItem) // TODO: Better delete
                .onMove(perform: moveItem)
            }
        }
        .padding()
        .toolbar(content: {
            HStack {
                Button(action: addItem) {
                    Label("Add", systemImage: "plus")
                }
            }
        })
    }

    private func addItem() {
        let newItem = PromptPair(trigger: "", response: "")
        settings.prompts.append(newItem)
    }

    private func deleteItem(at offsets: IndexSet) {
        settings.prompts.remove(atOffsets: offsets)
    }

    private func moveItem(from source: IndexSet, to destination: Int) {
        settings.prompts.move(fromOffsets: source, toOffset: destination)
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
    public var onConnectCallback: () -> Void = { }

    init() {
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

        // Call onConnectCallback
        onConnectCallback()
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
            print("Not handling \(event)")
            break
        }
    }
}


// Keeps app state in sync with server through an onChange callback handler.
class StateSyncManager {
    public var conn: ConnectionManager

    // keep state up to date.
    private var lastUpdate: Int // last update in epoch time
    private let updateFreq: Int // send updated state every n seconds (if state changed)
    private var timer: Timer?

    init(conn: ConnectionManager, updateFreq: Int = 2) {
        self.conn = conn
        self.updateFreq = updateFreq
        self.lastUpdate = 0
    }

    func timeSinceLastUpdate() -> Int {
        return Int(Date().timeIntervalSince1970) - lastUpdate
    }

    func onStateChange(_ appState: AppState) {
        let timeSince = timeSinceLastUpdate()
        if timeSince >= updateFreq {
            print("Last update was \(timeSince) seconds ago. Syncing state...")
            syncState(appState)
        } else {
            print("Last update was \(timeSince) seconds ago. Scheduling sync in \(updateFreq - timeSince) seconds...")
            trySyncAfter(appState, timeToWait: updateFreq - timeSince)
        }
    }

    // NOTE: Probably too clever for its own good. This exists to avoid
    // cases where appState changes multiple times in quick succession, then
    // the app is closed before the state can be synced. This would result in
    // lost data. At least this is isolated from the rest of the app...
    func trySyncAfter(_ appState: AppState, timeToWait: Int) {
        // cancel any existing timer; we want to sync the most recent state change
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Double(timeToWait), repeats: false) { _ in
            // we didn't handle the previous state change, so we push it again
            // to handle it now.
            self.onStateChange(appState)
            self.timer = nil
        }
    }

    func syncState(_ appState: AppState) {
        conn.send(WebSocketMessage(type: "state", state: appState))
        lastUpdate = Int(Date().timeIntervalSince1970)
    }
}


@main
struct MyApp: App {
    @State var appState: AppState = AppState(
        machineId: getMachineId(),
        username: NSUserName(),
        messages: [],
        settings: Settings(prompts: [], checkInInterval: 300), // TODO: make checkInInterval configurable
        activity: Activity(visibleWindows: getVisibleWindows())
    )
    var conn: ConnectionManager
    var sync: StateSyncManager
    @State var timer: Timer? // TODO: check no weird update properties

    init() {
        conn = ConnectionManager()
        sync = StateSyncManager(conn: conn)
    }

    var body: some Scene {
        WindowGroup {
            NavigationView {
                List {
                    NavigationLink(destination: ChatView(appState: $appState, sync: sync)) {
                        Text("Chat")
                    }
                    NavigationLink(destination: SettingsView(settings: $appState.settings)) {
                        Text("Settings")
                    }
                }
                ChatView(appState: $appState, sync: sync)
            }
            .onAppear {
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
                conn.onConnectCallback = { sync.syncState(appState) }


                // update activity information frequently
                timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
                    appState.activity = Activity(visibleWindows: getVisibleWindows())
                }
            }
            .onDisappear {
                // NOTE: probably not needed if the app is closing
                timer?.invalidate()
            }
            .onChange(of: appState) { newState in
                sync.onStateChange(newState)
            }
        }
    }
}
