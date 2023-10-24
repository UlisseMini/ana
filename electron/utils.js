const { exec: execCb } = require('child_process');
const util = require('util');

const exec = util.promisify(execCb);

// TODO: Fix this so it actually gets all visible windows
// (currently just output of wmctrl -lx - more like all active.)
async function getVisibleWindows() {
    try {
        const { stdout } = await exec('wmctrl -lx');
        const lines = stdout.split('\n').filter(line => line);
        const windows = lines.map(line => {
            const parts = line.split(/\s+/);
            const rawClass = parts[2];
            const rawName = rawClass.split('.')[0];

            // Prettify the window name by capitalizing the first letter
            const app = rawName.charAt(0).toUpperCase() + rawName.slice(1);

            // The window title is the last field, but can contain spaces
            const title = parts.slice(4).join(' ');

            return { app, title };
        });

        return windows;
    } catch (error) {
        throw new Error(`Error fetching window info: ${error.message}`);
    }
}

async function getActivity() {
    return { visibleWindows: await getVisibleWindows() }
}

module.exports = { getActivity }
