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
        visibleWindows: [{ app: 'Google Chrome', title: 'YouTube - 37 cutest cat videos of 2020' }]
    }
};


// never mutate appState directly. only through the setAppState function.
// this means appState updates will always be sent to the server.
// this can be designed better but shrug works for now
function setAppState(newAppState) {
    // never manually set activity

    window.native.getActivity().then((activity) => {
        console.log("activity", activity)
        appState = ({ ...newAppState, activity: activity });

        socket.send(JSON.stringify({
            type: 'state',
            data: appState,
        }));
    }).catch((e) => console.error(e))
}


function updateActivity() {
    window.native.getActivity().then((activity) => {
        console.log("activity", activity)
        setAppState({ ...appState, activity: activity });
    }).catch((e) => console.error(e))
}


socket.onopen = function (event) {
    socket.send(JSON.stringify({
        type: 'state',
        data: initialAppState
    }));
    console.log("Socket connected")
};

socket.onmessage = function (event) {
    const msg = JSON.parse(event.data)
    console.log("Socket sent message of type: ", msg.type)

    switch (msg["type"]) {
        case "state":
            appState = msg.data;
            updateMessagesUI();
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

function h(tag, attributes, children) {
    const element = document.createElement(tag)
    for (const [key, value] of Object.entries(attributes)) {
        element.setAttribute(key, value)
    }
    for (const child of children) {
        element.append(child)
    }
    return element
}

function updateMessagesUI() {
    const messagesContainer = document.querySelector("#messages-container")

    // Render messages
    const messages = appState.messages
    let children = []
    for (const message of messages) {
        const { role, content } = message;
        children.push(h("p", { class: `message ${role}` }, [content]))
    }
    messagesContainer.replaceChildren(...children)

    scrollToBottom();
}

function createTextbox() {
    const inputContainer = document.getElementById("input-container");
    const input = document.createElement("textarea")
    input.className = "input"
    input.rows = 1;
    input.placeholder = "Message"
    input.addEventListener("keydown", function (event) {
        if (event.key === "Enter" && !event.shiftKey) {
            event.preventDefault();

            if (!input.value) return;

            const newMessage = {
                "role": "user",
                "content": input.value,
                "function_call": null,
            }

            // Update UI right away with new message
            document.querySelector("#messages-container").appendChild(
                h("p", { class: "message user" }, [input.value])
            )
            scrollToBottom();

            setAppState({ ...appState, messages: [...appState.messages, newMessage] })
            input.value = "";
        }
    });
    inputContainer.appendChild(input)
}

function scrollToBottom() {
    var docElement = document.documentElement;
    docElement.scrollTop = docElement.scrollHeight;
}

function showNotification(notification) {
    const { title, body } = notification

    // First, check for permission
    if (Notification.permission === "granted") {
        // If it's okay, let's create a notification
        new Notification(title, {
            body: body,
            // icon: 'path_to_icon.png'
        });
    } else if (Notification.permission !== "denied") {
        // If permissions haven't been granted or denied yet, request them
        Notification.requestPermission().then(permission => {
            if (permission === "granted") {
                new Notification(title, {
                    body: body,
                    // icon: 'path_to_icon.png'
                });
            }
        });
    }
}


function init() {
    appState = initialAppState;
    createTextbox();
    setInterval(() => updateActivity(), 10 * 1000);
}

// when the page loads, run the init function
window.onload = init;