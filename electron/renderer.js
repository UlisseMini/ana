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

socket.onopen = function (event) {
    socket.send(JSON.stringify({
        type: 'state',
        data: initialAppState
    }));
    console.log("Socket connected")
};

let appState = initialAppState;

socket.onmessage = function (event) {
    console.log("Socket sent message")
    updateUI(JSON.parse(event.data))
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

function updateUI(msg) {
    if (msg['type'] != 'state') throw new Error("bad msg type: ", msg["type"])
    appState = msg['data']

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
    const messageContainer = document.createElement("div")
    messageContainer.className = "message-container"
    messageContainer.innerHTML = innerHTML
    root.appendChild(messageContainer);

    // Render chatbox
    const input = document.createElement("textarea")
    input.className = "chatbox"
    input.rows = 1;
    input.addEventListener("keydown", function (event) {
        if (event.key === "Enter" && !event.shiftKey) {
            event.preventDefault();
            const newMessage = {
                "role": "user",
                "content": input.value,
                "function_call": null,
            }

            appState.messages.push(newMessage)

            socket.send(JSON.stringify({
                type: 'state',
                data: appState,
            }));
        }
    });



    root.appendChild(input)

}
