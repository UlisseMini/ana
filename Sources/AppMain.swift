import SwiftUI
import Foundation
import OpenAI

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

struct ContentView: View {
    @State private var activeWindow: [String: Any]? = nil
    @State private var openAI = OpenAI(apiToken: ProcessInfo.processInfo.environment["OPENAI_API_KEY"]!)

    var body: some View {
        VStack {
            Text((activeWindow != nil ? showWindow(activeWindow!) : "No window"))
            .onAppear {
                requestScreenRecordingPermission()
                Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                    activeWindow = getActiveWindow()
                }
            }
            .font(.system(size: 20))
        }
        .frame(width: 400, height: 200)
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

