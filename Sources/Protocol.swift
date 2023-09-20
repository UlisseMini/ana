import Foundation

enum NotificationOptions: String, Codable {
    case badge, alert, sound
}

enum MessageType: String, Codable {
    case register, activityInfo = "activity_info", msg
}

struct BaseMessage: Codable {
    let type: MessageType
}

struct User: Codable {
    let userID: Int
    // Add other fields
}

struct RegisterMessage: Codable {
    let type: MessageType
    let user: User
}

struct ActivityInfoMessage: Codable {
    let type: MessageType
    let windowTitle: String?
    let app: String?
    let time: Int?
}

struct MsgMessage: Codable {
    let type: MessageType
    let role: String
    let content: String
enum NotificationOptions: String, Codable {
    case badge, alert, sound
}

enum MessageType: String, Codable {
    case register, activityInfo = "activity_info", msg
}

struct BaseMessage: Codable {
    let type: MessageType
}

struct User: Codable {
    let userID: Int
    // Add other fields
}

struct RegisterMessage: Codable {
    let type: MessageType
    let user: User
}

struct ActivityInfoMessage: Codable {
    let type: MessageType
    let windowTitle: String?
    let app: String?
}

struct MsgMessage: Codable {
    let type: MessageType
    let role: String
    let content: String
    let notifOpts: [NotificationOptions]?
}

    let notifOpts: [NotificationOptions]?
}

