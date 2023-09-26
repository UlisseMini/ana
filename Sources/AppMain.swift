import SwiftUI

// Model Definitions
struct AppState: Codable, Identifiable {
    var id = UUID()
    var user: User
    var messages: [Message]
}

struct User: Codable {
    var username: String
}

struct Message: Codable, Identifiable {
    var id = UUID()
    let text: String
}

// Save & Load AppState Array
func saveStates(appStates: [AppState]) {
    if let encoded = try? JSONEncoder().encode(appStates) {
        UserDefaults.standard.set(encoded, forKey: "AppStates")
    }
}

func loadStates() -> [AppState]? {
    if let data = UserDefaults.standard.data(forKey: "AppStates"),
    let appStates = try? JSONDecoder().decode([AppState].self, from: data) {
        return appStates
    }
    return nil
}

// SwiftUI Views
struct ChatView: View {
    @Binding var appStates: [AppState]
    @Binding var currentStateIndex: Int
    @State var newMessage: String = ""

    var body: some View {
        VStack {
            List(appStates[currentStateIndex].messages) { message in
                Text(message.text)
            }

            HStack {
                TextField("New message", text: $newMessage)
                .textFieldStyle(RoundedBorderTextFieldStyle())

                Button("Send") {
                    let newState = AppState(user: appStates[currentStateIndex].user,
                                            messages: appStates[currentStateIndex].messages + [Message(text: newMessage)])
                    appStates.append(newState)
                    currentStateIndex = appStates.count - 1
                    newMessage = ""
                    saveStates(appStates: appStates)
                }
            }
            .padding()
        }
        .onAppear {
            saveStates(appStates: appStates)
        }
        .onDisappear {
            saveStates(appStates: appStates)
        }
    }
}


@main
struct MyApp: App {
    @State var appStates: [AppState] = loadStates() ?? [AppState(user: User(username: "default"), messages: [])]
    @State var currentStateIndex: Int = (loadStates()?.count ?? 1) - 1

    var body: some Scene {
        WindowGroup {
            ChatView(appStates: $appStates, currentStateIndex: $currentStateIndex)
            .onAppear {
                NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
                    return self.handleKeyEvent(with: $0)
                }
            }
        }
    }

    private func handleKeyEvent(with event: NSEvent) -> NSEvent? {
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "z":
                if currentStateIndex > 0 {
                    currentStateIndex -= 1
                    return nil
                }
            case "r":
                if currentStateIndex < appStates.count - 1 {
                    currentStateIndex += 1
                    return nil
                }
            default: break
            }
        }
        return event
    }
}

