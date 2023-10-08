console.log('preload.js loaded')

const { contextBridge } = require('electron');
const { getActivity } = require('./utils')

contextBridge.exposeInMainWorld('native', {
    getActivity: getActivity,
});
