import SwiftUI
import Foundation
import UserNotifications
import Starscream


// Hides outline around textbox
extension NSTextField { 
    open override var focusRingType: NSFocusRingType {
        get { .none }
        set { }
    }
}


// --------------- Utility Functions ---------------

 
func getActiveWindow() -> [String: Any]? {
    if let frontmostApp = NSWorkspace.shared.frontmostApplication {
        let frontmostAppPID = frontmostApp.processIdentifier

        let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionOnScreenOnly)
        let windowListInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as! [[String: Any]]

        for window in windowListInfo {
            if let ownerPID = window[kCGWindowOwnerPID as String] as? Int, ownerPID == frontmostAppPID {
                return window
            }
        }
    }
    return nil
}

func requestScreenRecordingPermission() {
    let screenBounds = CGRect(x: 0, y: 0, width: 1, height: 1)
    let _ = CGWindowListCreateImage(screenBounds, .optionOnScreenBelowWindow, kCGNullWindowID, .bestResolution)
}

func showNotification(
    title: String,
    body: String,
    options: UNAuthorizationOptions = [.alert, .sound]
) {
    UNUserNotificationCenter.current().requestAuthorization(options: options) { granted, _ in
        print("Permission granted: \(granted)")
        guard granted else { return }

        // Create notification content
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // content.categoryIdentifier = "chat_msg_click" // TODO: handle clicks

        // Create trigger and request
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: "someID", content: content, trigger: trigger)

        // Schedule the notification
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Error scheduling notification: \(error)")
            }
        }
    }
}

let trim = { (str: String) -> String in
    return str.trimmingCharacters(in: .whitespacesAndNewlines)
}

// --------------- Main App UI ---------------


struct ChatMessage: Identifiable {
    let id = UUID()
    let user: String
    let message: String
}

func wsURL() -> URL {
    return URL(string: ProcessInfo.processInfo.environment["WS_URL"]!)!
}

struct ChatView: View {
    @ObservedObject var chatHistory: ChatHistory
    @State private var currentMessage: String = ""
    @State private var ws: WebSocket
    @State private var isConnected: Bool = false
    @FocusState private var isTextFieldFocused: Bool

    private let encoder = JSONEncoder()

    init(chatHistory ch: ChatHistory) {
        ws = WebSocket(request: URLRequest(url: wsURL()))
        chatHistory = ch
        encoder.keyEncodingStrategy = .convertToSnakeCase // interop with python
    }


    var messages: [ChatMessage] {
        chatHistory.messages
    }

    private func handleMessage(message: MsgMessage) {
        switch message.type {
        case .msg:
            addMessage(from: message.role, message: message.content)
        case .activityInfo:
            // print error; server shouldn't send us activity info
            print("ERROR: Received activity info from server")
        default:
            print("Unknown message type: \(message.type)")
        }
    }

    private func sendMessage(_ message: Codable) {
        if let jsonData = try? encoder.encode(message) {
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                ws.write(string: jsonString) // TODO: handle errors & retry
            }
        }
    }

    private func reconnect() {
        self.ws = WebSocket(request: URLRequest(url: wsURL()))
        self.setupWebSocket()
    }


    private func setupWebSocket() {
        self.ws.onEvent = { event in
            switch event {
            case .connected(let headers):
                print("connected, headers: \(headers)")
                isConnected = true
            case .disconnected(_, _):
                isConnected = false
            case .text(let text):
                // parse text as json 
                if let jsonData = text.data(using: .utf8) {
                    do {
                        let message = try JSONDecoder().decode(MsgMessage.self, from: jsonData)
                        handleMessage(message: message)
                    } catch {
                        print("Error decoding JSON: \(error)")
                    }
                }

            case .error(let error):
                if let error = error {
                    print("error: \(error)")
                }
            case .viabilityChanged(let isViable):
                if !isViable {
                    print("websocket is not viable, attempting to reconnect...")
                    self.reconnect()
                }
            case .reconnectSuggested(let isSuggested):
                if isSuggested {
                    self.reconnect()
                }
            default:
                print("Unhandled websocket event: \(event)")
            }
        }
        self.ws.connect()
    }


    private func setupWebSocketTimers() {
        // Setup timer reconnecting every 1s if websocket is disconnected
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { timer in
            if !isConnected {
                print("Disconnected. attempting to reconnect...")
                // FIXME: This doesn't work. probably need to make a new websocket object
                self.reconnect()
            }
        }

        var lastWindowTitle: String?

        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { timer in
            if let window = getActiveWindow() {
                let windowTitle = window["kCGWindowName"] as? String
                let app = window["kCGWindowOwnerName"] as? String
                if windowTitle != lastWindowTitle {
                    let activityInfo = ActivityInfoMessage(
                        type: .activityInfo,
                        windowTitle: windowTitle,
                        app: app,
                        time: Int(Date().timeIntervalSince1970)
                    )
                    self.sendMessage(activityInfo)
                    lastWindowTitle = windowTitle
                }
            }
        }
    }

    var body: some View {
        VStack {
            ScrollViewReader { scrollView in
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(messages) { chatMessage in
                            HStack {
                                if chatMessage.user == "user" {
                                    Spacer()
                                    Text(chatMessage.message)
                                    .padding(.vertical, 5)
                                    .padding(.horizontal, 10)
                                    .background(Color.blue)
                                    .foregroundColor(.white)
                                    .cornerRadius(10)
                                } else {
                                    Text(chatMessage.message)
                                    .padding(.vertical, 5)
                                    .padding(.horizontal, 10)
                                    .background(Color.gray)
                                    .foregroundColor(.white)
                                    .cornerRadius(10)
                                    Spacer()
                                }

                            }
                            .id(chatMessage.id)
                        }
                    }
                    .onChange(of: messages.count) { _ in
                        if let lastMessage = messages.last {
                            scrollView.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                    .padding()
                }
            }

            HStack {
                TextField("Enter message...", text: $currentMessage, onCommit: {
                    if trim(currentMessage) == "" {
                        return
                    }
                    // TODO: This should be gone & we wait till python sends our msg back to us
                    addMessage(from: "user", message: currentMessage)
                    let messageToSend = MsgMessage(type: .msg, role: "user", content: currentMessage, notifOpts: nil)
                    self.sendMessage(messageToSend)

                    DispatchQueue.main.async {
                        currentMessage = ""
                    }
                })
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .padding()
                .focused($isTextFieldFocused)
            }
        }
        .onAppear {
            requestScreenRecordingPermission()
            self.setupWebSocket()
            self.setupWebSocketTimers()
            DispatchQueue.main.async {
                isTextFieldFocused = true
            }
        }
        .navigationTitle("Chat")
    }

    func addMessage(from user: String, message: String) {
        chatHistory.addMsg(from: user, message: message)
    }
}

struct SettingsView: View {
    var body: some View {
        VStack(spacing: 20) {
            Text("Settings Pane")
                .font(.largeTitle)
            Text("Placeholder Text for Settings")
                .font(.body)
        }
        .padding()
    }
}


class ChatHistory: ObservableObject {
    @Published var messages: [ChatMessage] = []
    
    func addMsg(from user: String, message: String) {
        let chatMessage = ChatMessage(user: user, message: message)
        messages.append(chatMessage)
    }
}



@main
struct bossgptApp: App {
    @StateObject var chatHistory = ChatHistory()
    
    var body: some Scene {
        WindowGroup {
            NavigationView {
                List {
                    NavigationLink(destination: ChatView(chatHistory: chatHistory)) {
                        Label("Chat", systemImage: "message")
                    }
                    NavigationLink(destination: SettingsView()) {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
                ChatView(chatHistory: chatHistory)
            }
        }
    }
}
