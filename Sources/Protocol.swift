import Foundation

enum NotificationOptions: String, Codable {
    case badge, alert, sound
}

enum MessageType: String, Codable {
    case register, activityInfo = "activity_info", msg, settings
}

struct BaseMessage: Codable {
    let type: MessageType
}

struct User: Codable {
    let username: String
    let fullname: String
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
    let notifOpts: [NotificationOptions]?
}

struct SettingsMessage: Codable {
    let type: MessageType
    let timesinks: String
    let endorsed_activities: String
}