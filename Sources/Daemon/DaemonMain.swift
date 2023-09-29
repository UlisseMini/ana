import AppKit
import Vision
import SQLite


func getWindows() -> [[String: Any]] {
    let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionOnScreenOnly)
    let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as! [[String: Any]]

    let excludeOwners = ["Window Server"]
    return windows.filter { window in
        guard let owner = window[kCGWindowOwnerName as String] as? String else { return false }
        return !excludeOwners.contains(owner)
    }
}


func captureScreenshot() -> NSImage? {
    guard let image = CGWindowListCreateImage(.null, .optionOnScreenOnly, kCGNullWindowID, .boundsIgnoreFraming) else {
        return nil
    }
    return NSImage(cgImage: image, size: .zero)
}


func performOCR(image: NSImage) async -> [String] {
    return await withCheckedContinuation { continuation in
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let cgImage = bitmap.cgImage else { 
                  continuation.resume(returning: [])
                  return
              }
        
        let request = VNRecognizeTextRequest { (request, error) in
            guard let observations = request.results as? [VNRecognizedTextObservation] else { 
                continuation.resume(returning: [])
                return 
            }
            let texts = observations.compactMap { $0.topCandidates(1).first?.string }
            continuation.resume(returning: texts)
        }
        
        let requests = [request]
        let imageRequestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? imageRequestHandler.perform(requests)
    }
}


let db = try? Connection("activity.db")
let screenshots = Table("screenshots")
let id = Expression<Int64>("id")
let createdAt = Expression<Date>("created_at")
let imageColumn = Expression<Data>("image")
let textColumn = Expression<String>("text")

let windows = Table("windows")
let windowJSON = Expression<String>("window_json")

func createTables() throws {
    try db?.run(screenshots.create(ifNotExists: true) { t in
        t.column(id, primaryKey: .autoincrement)
        t.column(createdAt, defaultValue: Date())
        t.column(imageColumn)
        t.column(textColumn)
    })

    try db?.run(windows.create(ifNotExists: true) { t in
        t.column(id, primaryKey: .autoincrement)
        t.column(createdAt, defaultValue: Date())
        t.column(windowJSON, defaultValue: "[]") // json 
    })
}


func saveToDatabase(image: NSImage, text: String) -> Int64?{ 
    guard let tiffData = image.tiffRepresentation else {
        print("Failed to get tiff representation")
        return nil
    }
    print("Saving to database")
    
    return try? db?.run(screenshots.insert(imageColumn <- tiffData, textColumn <- text))
}


@main
struct DaemonApp {
    static func main() async throws {
        try createTables()

        while true {
            // save windows to json
            let json = try JSONSerialization.data(withJSONObject: getWindows(), options: [])
            let jsonString = String(data: json, encoding: .utf8)!
            try db?.run(windows.insert(windowJSON <- jsonString))

            if let screenshot = captureScreenshot() {
                let recognizedTextBlocks = await performOCR(image: screenshot)
                _ = saveToDatabase(image: screenshot, text: recognizedTextBlocks.joined(separator: "│"))
            } else {
                print("Failed to capture screenshot")
            }
            
            try await Task.sleep(nanoseconds: 300 * 1000_000_000)
        }
    }
}
