import Foundation
import CoreGraphics
import UserNotifications
import SwiftUI

struct WindowBounds: Codable, Equatable {
    let height: Int
    let width: Int
    let x: Int
    let y: Int
}

struct Window: Codable, Equatable {
    // let kCGWindowOwnerPID: Int
    // let kCGWindowStoreType: Int
    // let kCGWindowIsOnscreen: Int
    // let kCGWindowNumber: Int
    let kCGWindowName: String
    // let kCGWindowBounds: WindowBounds
    // let kCGWindowLayer: Int
    // let kCGWindowMemoryUsage: Int
    // let kCGWindowAlpha: Int
    let kCGWindowOwnerName: String
    // let kCGWindowSharingState: Int
}

func getVisibleWindows() -> [Window] {
    var visibleWindows: [Window] = []

    let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionOnScreenOnly)
    let windowListInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as! [[String: Any]]

    let excludeOwners = ["Window Server"]

    for window in windowListInfo {
        if let isOnScreen = window[kCGWindowIsOnscreen as String] as? Bool,
        let layer = window[kCGWindowLayer as String] as? Int,
        let title = window[kCGWindowName as String] as? String,
        let owner = window[kCGWindowOwnerName as String] as? String,
        isOnScreen && layer == 0 && !title.isEmpty && !excludeOwners.contains(owner) {
            visibleWindows.append(Window(kCGWindowName: title, kCGWindowOwnerName: owner))
        }
    }

    return visibleWindows
}

func getSerialNumber() -> String? {
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

func getMachineId() -> String {
    let serialNumber = getSerialNumber()
    return serialNumber ?? UUID(uuidString: NSUserName() + NSFullUserName())!.uuidString
}


func requestScreenRecordingPermission() {
    let screenBounds = CGRect(x: 0, y: 0, width: 1, height: 1)
    let _ = CGWindowListCreateImage(screenBounds, .optionOnScreenBelowWindow, kCGNullWindowID, .bestResolution)
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


func appIsActiveWindow() -> Bool{
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
    if appIsActiveWindow() {
        print("App is active, not showing notification")
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

func popup() {
    if let window = NSApplication.shared.windows.first {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
