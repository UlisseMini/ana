import SwiftUI
import Foundation
import UserNotifications
import Starscream


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


// --------------- Main App UI ---------------


struct ChatMessage: Identifiable {
    let id = UUID()
    let user: String
    let message: String
}

// 


struct ChatView: View {
    @ObservedObject var chatHistory: ChatHistory
    @State private var currentMessage: String = ""
    @State private var ws: WebSocket
    private let encoder = JSONEncoder()

    init(chatHistory ch: ChatHistory) {
        ws = WebSocket(request: URLRequest(url: URL(string: "http://localhost:8000/ws")!))
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


    private func setupWebSocket() {
        var isConnected = false
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
                    self.ws.connect()
                }
            case .reconnectSuggested(let isSuggested):
                if isSuggested {
                    self.ws.connect()
                }
            default:
                print("Unhandled websocket event: \(event)")
            }
        }
        self.ws.connect()

        // Setup timer reconnecting every 1s if websocket is disconnected
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { timer in
            if !isConnected {
                print("Disconnected. attempting to reconnect...")
                // FIXME: This doesn't work. probably need to make a new websocket object
                self.ws.connect()
            }
        }

        // Setup timer sending activity info very frequently
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { timer in
            if let window = getActiveWindow() {
                let windowTitle = window["kCGWindowName"] as? String
                let app = window["kCGWindowOwnerName"] as? String
                let activityInfo = ActivityInfoMessage(
                    type: .activityInfo,
                    windowTitle: windowTitle,
                    app: app
                )
                self.sendMessage(activityInfo)
            }
        }
    }

    var body: some View {
        VStack {
            ScrollViewReader { scrollView in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(messages) { chatMessage in
                            HStack {
                                if chatMessage.user == "User1" {
                                    Spacer()
                                    Text(chatMessage.message)
                                        .padding()
                                        .background(Color.blue)
                                        .foregroundColor(.white)
                                        .cornerRadius(10)
                                } else {
                                    Text(chatMessage.message)
                                        .padding()
                                        .background(Color.green)
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
                }
            }

            HStack {
                TextField("Enter message...", text: $currentMessage, onCommit: {
                    addMessage(from: "User1", message: currentMessage)

                        let messageToSend = MsgMessage(type: .msg, role: "user", content: currentMessage, notifOpts: nil)
                        if let jsonData = try? encoder.encode(messageToSend),
                           let jsonString = String(data: jsonData, encoding: .utf8) {
                            ws.write(string: jsonString)
                        }



                    DispatchQueue.main.async {
                        currentMessage = ""
                    }
                })
                .textFieldStyle(RoundedBorderTextFieldStyle())
                Button("Send") {
                    addMessage(from: "User1", message: currentMessage)
                    currentMessage = ""
                }
            }
            .padding()
        }
        .onAppear {
            self.setupWebSocket()
        }
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
                .listStyle(SidebarListStyle())
                ChatView(chatHistory: chatHistory)
            }
        }
    }
}
