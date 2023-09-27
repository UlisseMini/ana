import Foundation
import CoreGraphics

func getVisibleWindows() -> [[String: Any]] {
    var visibleWindows: [[String: Any]] = []

    let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionOnScreenOnly)
    let windowListInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as! [[String: Any]]

    let excludeOwners = ["Window Server"]

    for window in windowListInfo {
        if let isOnScreen = window[kCGWindowIsOnscreen as String] as? Bool,
        let layer = window[kCGWindowLayer as String] as? Int,
        let title = window[kCGWindowName as String] as? String,
        let owner = window[kCGWindowOwnerName as String] as? String,
        isOnScreen && layer == 0 && !title.isEmpty && !excludeOwners.contains(owner) {
            visibleWindows.append(window)
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
