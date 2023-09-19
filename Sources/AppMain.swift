import SwiftUI
import Foundation
import OpenAI
import UserNotifications
import UserNotificationsUI

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
    return "\(getApp(window)): \(getTitle(window))"
}

func loop(chatText: String) async {
    while true {
        let activeWindow = getActiveWindow()
        if activeWindow != nil {
            print(showWindow(activeWindow!))
        }
        await Task.sleep(1 * 1_000_000_000)
    }
}


func centerWindow(window: NSWindow) {
    let screen = window.screen ?? NSScreen.main!
    let screenRect = screen.visibleFrame
    let windowRect = window.frame

    let x = (screenRect.width - windowRect.width) / 2
    let y = (screenRect.height - windowRect.height) / 2

    window.setFrameOrigin(NSPoint(x: x + screenRect.minX, y: y + screenRect.minY))
}

func showNotification() {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
        print("Permission granted: \(granted)")
        guard granted else { return }

        // Create notification content
        let content = UNMutableNotificationContent()
        content.title = "Title"
        content.body = "Body"

        // Create trigger and request
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: "someID", content: content, trigger: trigger)

        // Schedule the notification
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}


// MVP Psudocode:
// - Move window to center and hide. perhaps add opacity.
// - Notification



struct ContentView: View {
    @State private var activeWindow: [String: Any]? = nil
    @State private var openAI = OpenAI(apiToken: ProcessInfo.processInfo.environment["OPENAI_API_KEY"]!)
    @State private var chatText = "Loading chat text..."

    var body: some View {
        VStack {
            Text((activeWindow != nil ? showWindow(activeWindow!) : "No window"))
            .onAppear {
                // requestScreenRecordingPermission()
                // Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                //     activeWindow = getActiveWindow()
                // }
            }
            .font(.system(size: 20))
            Text(chatText)
            .onAppear {
                Task {
                    // has possible race condition but who the fuck cares
                    while NSApp.windows.isEmpty {
                        await try Task.sleep(nanoseconds: 100 * 1_000_000)
                    }
                    let window = NSApp.windows[0]
                    centerWindow(window: window)
                    // window.miniaturize(nil)
                    // NSApp.hide(nil)
                }


                // TODO: Make sure this is only spawned once.
                Task {
                    while true {
                        await try Task.sleep(nanoseconds: 5 * 1_000_000_000)
                        if activeWindow == nil {
                            print("activeWindow is null or unchanged")
                            continue;
                        }
                        continue
                        NSApp.unhide(nil)

                        let query = ChatQuery(
                            model: "gpt-3.5-turbo",
                            messages: [
                                Chat(role: .system, content: "Is the window titled \(showWindow(activeWindow!)) useful for coding?"),
                            ],
                            maxTokens: 64
                        )

                        chatText = ""
                        for try await result in openAI.chatsStream(query: query) {
                            print(result)
                            chatText += result.choices[0].delta.content ?? ""
                        }

                        await try Task.sleep(nanoseconds: 3 * 1_000_000_000)
                        NSApp.hide(nil)
                    }
                }
            }
            Button("Show notification") {
                showNotification()
            }
        }
        .frame(width: 200, height: 100)
        .padding()
    }

}

@main
struct bossgptApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

