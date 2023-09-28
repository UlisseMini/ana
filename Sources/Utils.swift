import Foundation
import CoreGraphics

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
