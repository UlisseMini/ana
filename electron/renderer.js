const socket = new WebSocket('ws://localhost:8000/ws');


const initialAppState = {
    machineId: "mid", // An empty string, but you'd probably want to provide a real initial value
    username: "uid",  // An empty string, but you'd probably want to provide a real initial value
    messages: [],
    settings: {
        prompts: [],
        checkInInterval: 600,  // An initial value, you'd want to set this to something meaningful
        timezone: "America/New_York",  // An empty string, but you'd probably want to provide a real initial value
        debug: false
    },
    activity: {
        visibleWindows: []
    }
};


// never mutate appState directly. only through the setAppState function.
// this means appState updates will always be sent to the server.
// this can be designed better but shrug works for now
let appState = initialAppState;

function setAppState(newAppState) {
    appState = newAppState;
    socket.send(JSON.stringify({
        type: 'state',
        data: newAppState,
    }));
}


socket.onopen = function (event) {
    socket.send(JSON.stringify({
        type: 'state',
        data: initialAppState
    }));
    console.log("Socket connected")
};

socket.onmessage = function (event) {
    console.log("Socket sent message")

    const msg = JSON.parse(event.data)
    switch (msg["type"]) {
        case "state":
            appState = msg.data;
            updateUI();
            break;

        case "notification":
            showNotification(msg.data);
            break;

        default:
            console.warn("Invalid msg type received from socket: ", msg["type"])
            break;

    }
};

socket.onclose = function (event) {
    if (event.wasClean) {
        console.log('Socket connection closed cleanly');
    } else {
        console.log('Socket connection died');
    }
};

socket.onerror = function (error) {
    console.log("Socket error: ", error.message)
};

function updateUI() {
    const root = document.querySelector("#root")
    root.innerHTML = "";

    // Render messages
    const messages = appState.messages
    let innerHTML = ""
    for (const message of messages) {
        const { role, content } = message;
        innerHTML += (
            `<p class="message ${role}">${content}</p>`
        )
    }
    const messagesContainer = document.createElement("div")
    messagesContainer.innerHTML = innerHTML
    messagesContainer.id = "messages-container"

    const chatContainer = document.createElement("div")
    chatContainer.className = "chat-container"
    chatContainer.appendChild(messagesContainer)

    // Render chatbox
    const input = document.createElement("textarea")
    input.className = "chatbox"
    input.rows = 1;
    input.placeholder = "Message"
    input.addEventListener("keydown", function (event) {
        if (event.key === "Enter" && !event.shiftKey) {
            event.preventDefault();

            const newMessage = {
                "role": "user",
                "content": input.value,
                "function_call": null,
            }

            // Update UI right away with new message
            document.querySelector("#messages-container").innerHTML += (
                `<p class="message user">${input.value}</p>`
            )

            setAppState({ ...appState, messages: [...appState.messages, newMessage] })
        }
    });
    chatContainer.appendChild(input);

    root.appendChild(chatContainer);

}

function showNotification(notification) {
    const { title, body } = notification
    console.log(title, body)
}