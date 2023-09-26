import Foundation

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
