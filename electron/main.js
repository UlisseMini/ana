const { app, BrowserWindow } = require('electron');
const { ipcMain } = require('electron');
const { getActivity } = require('./utils')


ipcMain.on('get-activity', (event, cmd) => {
	event.reply('activity', getActivity());
});


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

