const { app, BrowserWindow } = require('electron');

app.disableHardwareAcceleration();

app.on('ready', () => {
	let win = new BrowserWindow({
		width: 800,
		height: 600,
		nodeIntegration: true,
		contextIsolation: false,
		devTools: true,
	});
	win.loadFile('index.html');
});

