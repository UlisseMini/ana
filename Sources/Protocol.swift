// TODO: Better types. this is essentially c code, yuck
import Foundation
import UserNotifications

enum NotificationOptions: String, Codable {
    case badge, alert, sound
}

extension NotificationOptions {
    var toUNAuthorizationOptions: UNAuthorizationOptions {
        switch self {
        case .badge:
            return .badge
        case .alert:
            return .alert
        case .sound:
            return .sound
        }
    }
}

enum MessageType: String, Codable {
    case register, activityInfo = "activity_info", msg, settings, debug
}

struct BaseMessage: Codable {
    let type: MessageType
}

struct User: Codable {
    let machine_id: String
}

struct RegisterMessage: Codable {
    let type: MessageType
    let user: User
}

struct DebugMessage: Codable {
    let type: MessageType
    let cmd: String
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
