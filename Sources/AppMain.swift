import SwiftUI
import Foundation
import OpenAI
import UserNotifications
import UserNotificationsUI
import Starscream


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

let getTitle = { (window: [String: Any]) -> String in
    return window["kCGWindowName"] as? String ?? "No window"
}
let getApp = { (window: [String: Any]) -> String in
    return window["kCGWindowOwnerName"] as? String ?? "No app"
}

let showWindow = { (window: [String: Any]) -> String in
    return "App: \(getApp(window)), with title: \(getTitle(window))"
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
        // content.categoryIdentifier = "chat_msg_click" // TODO

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


// MVP Psudocode:
// - Move window to center and hide. perhaps add opacity.
// - Notification every so often with msg from ai bot
//   - should only notify if they've been on the same window-concept for a while
// - Clicking notification opens chat window
// - Chat window is 1-1 with your AI. notifications for window-changes are paused
//   while you chat.


// TODO: System prompt good enough to ignore docs / see docs as good.

let systemPrompt = """
You are a productivity assistant. Every few minutes you will be asked to evaluate what the user is doing,
If the user is doing something they said they didn't want to do, you should ask them why they are doing it,
and nicely try to motivate them to work. Otherwise you should simply reply with "Great work!" and nothing else.
Try to understand the user's preferences and motivations, they might have a good reason to add an exception.
Write in an informal texting style, as if you were a friend. Include cute faces :D. Send short messages.
""".trimmingCharacters(in: .whitespacesAndNewlines)

let trim = { (s: String) -> String in
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}

func nextCheckInIn(_ checkInInterval: Double, _ lastCheckInTime: Int) -> Int {
    return  Int(checkInInterval) + lastCheckInTime - Int(Date().timeIntervalSince1970)
}


struct ContentView: View {
    @State private var activeWindow: [String: Any]? = nil
    @State private var openAI = OpenAI(apiToken: ProcessInfo.processInfo.environment["OPENAI_API_KEY"]!)
    @State private var chatText = "Loading chat text..."
    @State private var preferences = "I want to be focused coding right now"
    @State private var checkInInterval: Double = 60
    @State private var encourageEvery: Double = 10
    @State private var lastCheckInTime: Int = -1
    @State private var message: String = ""
    @State private var messages: [Chat] = []

    func sendMessage() {
        print("sent message")
        // Append the user message to the messages array
        messages.append(Chat(role: .user, content: message))
    }

    var body: some View {
        VStack {
            Text((activeWindow != nil ? "\(showWindow(activeWindow!))" : "No window"))
            .onAppear {
                requestScreenRecordingPermission()
                Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                    activeWindow = getActiveWindow()
                }
            }
            Text("BossGPT: \(chatText.count > 0 ? chatText : "Nothing to say, keep it up! :D")")
            .onAppear {
                // TODO: Make sure this is only spawned once.
                Task {
                    while true {
                        try await Task.sleep(nanoseconds: 1 * 1_000_000_000)
                        if activeWindow == nil || preferences == "" {
                            print("activeWindow is null or unchanged")
                            continue
                        }
                        lastCheckInTime = Int(Date().timeIntervalSince1970)

                        var chatMessages = [
                            Chat(role: .system, content: systemPrompt),
                            Chat(role: .user, content: "My preferences are \(preferences)")
                        ]
                        
                        // Concatenate the messages array with chatMessages
                        chatMessages += messages

                        chatMessages += [
                            Chat(role: .user, content: "The user is currently on \(showWindow(activeWindow!))"),
                        ]

                        print(chatMessages)

                        let query = ChatQuery(
                            model: "gpt-3.5-turbo",
                            messages: chatMessages,
                            maxTokens: 100
                        )

                        chatText = ""
                        for try await result in openAI.chatsStream(query: query) {
                            chatText += result.choices[0].delta.content ?? ""
                        }

                        messages.append(Chat(role: .assistant, content: chatText))

                        if chatText.starts(with: "Great work") {
                            // randomly show notification in 1/encourageEvery cases
                            if Int.random(in: 0...Int(encourageEvery)) == 0 {
                                // TODO: Check that this doesn't make a sound, make sure the badge disappears without interaction quickly.
                                showNotification(title: "BossGPT", body: chatText, options: [.badge])
                            }
                        } else {
                            showNotification(title: "BossGPT", body: chatText)
                        }

                        print("chatText: \(chatText)")

                        // TODO: This would be cleaner with helper functions or better libraries
                        // we do this so adjusting the slider works immediately.
                        while nextCheckInIn(checkInInterval, lastCheckInTime) > 0 {
                            try await Task.sleep(nanoseconds: 100 * 1_000_000) // 100ms
                        }
                    }
                }
            }
            Divider()
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())]) {
                Text("What do you want to be doing?")
                TextField("Preferences", text: $preferences)

                // New TextField for "message"
                Text("Message:")
                TextField("Enter your message", text: $message, onCommit: {
                    sendMessage() // Call the function when "Enter" is pressed
                    DispatchQueue.main.async {
                        message = ""
                    }
                })

                // TODO: show next-check-in time
                Text("I'll check what you're doing every \(Int(checkInInterval)) seconds, next in \(nextCheckInIn(checkInInterval, lastCheckInTime))s :D")
                Slider(value: $checkInInterval, in: 5...500, step: 1).padding()

                Text("And I'll encourage you every \(Int(encourageEvery)) check-ins while you're working!")
                Slider(value: $encourageEvery, in: 1...100, step: 1).padding()
            }


        }
        .padding()
    }

}


class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        print("foreground notification")
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {

        print(response)
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            print("Default action!")
        }
        if response.actionIdentifier == "CLICK_ACTION" {
            print("They clicked our special button!")
        }
        completionHandler()
    }
}



@main
struct bossgptApp: App {
    init() {
        // Register delegate to handle notification actions
        UNUserNotificationCenter.current().delegate = NotificationDelegate()

        // TODO (once I fix handlers): Create click action category
        /*
        let clickAction = UNNotificationAction(identifier: "CLICK_ACTION", title: "Click Me", options: [])
        let category = UNNotificationCategory(identifier: "chat_msg_click", actions: [clickAction], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
        */
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

