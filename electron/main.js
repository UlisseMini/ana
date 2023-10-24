const { app, BrowserWindow } = require('electron');
const path = require('path')
// const { ipcMain } = require('electron');
// const { getActivity } = require('./utils')


// ipcMain.on('get-activity', (event, cmd) => {
// 	event.reply('activity', getActivity());
// });


app.disableHardwareAcceleration();

app.on('ready', () => {
	let win = new BrowserWindow({
		width: 800,
		height: 600,
		webPreferences: {
			nodeIntegration: true,
			contextIsolation: true,
			preload: path.join(__dirname, 'preload.js')
		}
	});
	win.loadFile('index.html');
});

