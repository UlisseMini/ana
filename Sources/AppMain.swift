import SwiftUI
import Foundation
import UserNotifications
import Starscream
import IOKit
import HotKey



// Hides outline around textbox
extension NSTextField { 
    open override var focusRingType: NSFocusRingType {
        get { .none }
        set { }
    }
}


// --------------- Utility Functions ---------------


func getUniqueMachineID() -> String? {
    let platformExpert = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
    
    if platformExpert == IO_OBJECT_NULL {
        return nil
    }
    
    guard let serialNumberAsCFString = IORegistryEntryCreateCFProperty(platformExpert, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0) else {
        IOObjectRelease(platformExpert)
        return nil
    }

    let serialNumber = serialNumberAsCFString.takeRetainedValue() as? String
    
    IOObjectRelease(platformExpert)
    
    return serialNumber
}


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

func checkIfAppIsActiveWindow() -> Bool{
    let appName = Bundle.main.infoDictionary![kCFBundleNameKey as String] as! String
    if let window = getActiveWindow() {
        let app = window["kCGWindowOwnerName"] as? String
        if app == appName {
            return true
        } else {
            return false
        }
    } else {
        return false
    }
}

func showNotification(
    title: String,
    body: String,
    options: UNAuthorizationOptions = [.alert, .sound]
) {
    if checkIfAppIsActiveWindow() {
        return
    }
    
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

var initialized = false

struct ChatView: View {
    @ObservedObject var chatHistory: ChatHistory
    @State private var currentMessage: String = ""
    @State private var ws: WebSocket
    @State private var isConnected: Bool = false
    @FocusState private var isTextFieldFocused: Bool

    @ObservedObject var settings: Settings

    private let encoder = JSONEncoder()
    private var hotKey: HotKey

    init(chatHistory ch: ChatHistory, settings: Settings, hotKey: HotKey) {
        ws = WebSocket(request: URLRequest(url: wsURL()))
        chatHistory = ch
        encoder.keyEncodingStrategy = .convertToSnakeCase
        self.settings = settings
        self.hotKey = hotKey
    }

    var messages: [ChatMessage] {
        chatHistory.messages
    }

    private func handleMessage(data: Data) throws {
        let message = try JSONDecoder().decode(BaseMessage.self, from: data)
        switch message.type {
            case .msg:
                let message = try JSONDecoder().decode(MsgMessage.self, from: data)

                if let options = message.notifOpts {
                    let notifOpts: UNAuthorizationOptions = options.reduce([]) { $0.union($1.toUNAuthorizationOptions) }
                    addMessage(from: message.role, message: message.content, notifOpts: notifOpts)
                } else {
                    addMessage(from: message.role, message: message.content)
                }
            case .activityInfo:
                // print error; server shouldn't send us activity info
                print("ERROR: Received activity info from server")
            case .settings:
                let message = try JSONDecoder().decode(SettingsMessage.self, from: data)
                settings.endorsedActivities = message.endorsed_activities
                settings.timesinks = message.timesinks

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
        self.hotKey.keyDownHandler = {
            print("Hotkey pressed, sending: \(self.isConnected)")
            // send {"type": "debug", "cmd": "checkin"} if connected
            if self.isConnected {
                let debugMessage = DebugMessage(type: .debug, cmd: "checkin")
                self.sendMessage(debugMessage)
            }
        }

        self.ws.onEvent = { event in
            switch event {
            case .connected(let headers):
                print("connected, headers: \(headers)")
                isConnected = true

                // clear messages, server will send us the history
                chatHistory.messages = []


                // send registration message
                let registerMessage = RegisterMessage(
                    type: .register,
                    user: User(machine_id: getUniqueMachineID()!)
                )
                self.sendMessage(registerMessage)
            case .disconnected(_, _):
                isConnected = false
            case .peerClosed:
                isConnected = false
            case .cancelled:
                isConnected = false
            case .text(let text):
                // parse text as json 
                if let jsonData = text.data(using: .utf8) {
                    do {
                        try handleMessage(data: jsonData)
                    } catch {
                        print("Error handling message \(text): \(error)")
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
                self.reconnect()
            }
        }

        var lastWindowTitle: String?
        var last_timesinks: String?
        var last_endorsedActivities: String?

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
                if settings.timesinks != last_timesinks || settings.endorsedActivities != last_endorsedActivities {
                    print("Sending timesinks: \(settings.timesinks)")
                    let set_msg = SettingsMessage(
                        type: .settings,
                        timesinks: settings.timesinks,
                        endorsed_activities: settings.endorsedActivities
                    )
                    self.sendMessage(set_msg)
                    last_timesinks = settings.timesinks
                    last_endorsedActivities = settings.endorsedActivities
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
                                    // blue
                                    Spacer()
                                    Text(chatMessage.message)
                                    .padding(.vertical, 5)
                                    .padding(.horizontal, 10)
                                    .background(Color.blue)
                                    .foregroundColor(.white)
                                    .cornerRadius(10)
                                } else if chatMessage.user == "special" {
                                    // green
                                    Spacer()
                                    Text(chatMessage.message)
                                    .padding(.vertical, 5)
                                    .padding(.horizontal, 10)
                                    .background(Color.green)
                                    .foregroundColor(.white)
                                    .cornerRadius(10)
                                } else {
                                    // gray
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
            guard !initialized else { return }
            initialized = true

            requestScreenRecordingPermission()
            self.setupWebSocket()
            self.setupWebSocketTimers()

            DispatchQueue.main.async {
                isTextFieldFocused = true
            }
        }
        .navigationTitle("Chat")
    }

    func addMessage(from user: String, message: String, notifOpts: UNAuthorizationOptions? = nil) {
        chatHistory.addMsg(from: user, message: message)
        if user != "user", let options = notifOpts {
            showNotification(title: user, body: message, options: options)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings: Settings

    var body: some View {
        HStack {
            VStack(spacing: 20) {
                Text("Timesinks")
                    .font(.title)
                TextEditor(text: $settings.timesinks)
                    .frame(minHeight: 100)
                    .background(Color.gray)
                    .cornerRadius(10)
                    .padding()
            }
            VStack(spacing: 20) {
                Text("Endorsed Activities")
                    .font(.title)
                TextEditor(text: $settings.endorsedActivities)
                    .frame(minHeight: 100)
                    .background(Color.gray)
                    .cornerRadius(10)
                    .padding()
            }
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

class Settings: ObservableObject {
    @Published var timesinks: String = ""
    @Published var endorsedActivities: String = ""
}


@main
struct bossgptApp: App {
    @StateObject var chatHistory = ChatHistory()
    @StateObject var settings = Settings() // <-- add this

    let hotKey = HotKey(key: .c, modifiers: [.command, .option])

    var body: some Scene {
        WindowGroup {
            NavigationView {
                List {
                    NavigationLink(destination: ChatView(chatHistory: chatHistory, settings: settings, hotKey: hotKey)) {
                        Label("Chat", systemImage: "message")
                    }
                    NavigationLink(destination: SettingsView(settings: settings)) { // <-- add this
                        Label("Settings", systemImage: "gearshape")
                    }
                }
                ChatView(chatHistory: chatHistory, settings: settings, hotKey: hotKey) // <-- add this
            }
            .environmentObject(settings) // <-- add this
        }
    }
}
