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
        timezone: "EDT",  // An empty string, but you'd probably want to provide a real initial value
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

socket.onmessage = function (event) {
    console.log('Message from server:', event.data);
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

