console.log("jeez")

const WebSocket = require('ws');

console.log("wtf is wrong with you")

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

console.log("boopie")

socket.onopen = function (event) {
    socket.send(JSON.stringify({
        type: 'state',
        data: initialAppState
    }));
    document.getElementById('status').textContent = 'Connected';
};

let appState = initialAppState;

socket.onmessage = function (event) {
    updateUI(JSON.parse(event.data))
};

socket.onclose = function (event) {
    if (event.wasClean) {
        document.getElementById('status').textContent = 'Connection closed cleanly';
    } else {
        document.getElementById('status').textContent = 'Connection died';
    }
};

socket.onerror = function (error) {
    document.getElementById('status').textContent = 'Error: ' + error.message;
};

function updateUI(appState) {
    const messages = appState.data.messages
    let innerHTML = ""
    for (const message of messages) {
        const { role, content } = message;
        innerHTML += (
            `<p>${content}</p>`
        )
    }
    document.querySelector("#root").innerHTML = innerHTML;
}