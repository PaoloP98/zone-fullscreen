// Keeps "fullscreen" inside the browser window's own place on screen.
//
// Instead of real fullscreen, the tab is moved into a bare "popup" window (title bar only)
// with the same position and size as the window it came from, and moved back afterwards.
// Three things trigger it:
//   - a page asks for fullscreen (video players): inject.js reports 'enter' / 'exit'
//   - F11: the window really goes fullscreen for a moment; we undo that and pop the tab out
//   - the toolbar button or the keyboard shortcut
//
// State lives in chrome.storage.session because this worker is unloaded when idle.

const store = chrome.storage.session;
const originKey = (tabId) => `popout:${tabId}`;
const windowKey = (windowId) => `window:${windowId}`;

async function read(key) {
  return (await store.get(key))[key] || null;
}

function boundsOf(win) {
  // A maximized window reports bounds that hang off the screen; keep the state instead.
  if (win.state === 'maximized') return { state: 'maximized' };
  return { left: win.left, top: win.top, width: win.width, height: win.height };
}

async function popOut(tab) {
  if (await read(originKey(tab.id))) return; // already popped out
  const win = await chrome.windows.get(tab.windowId);
  if (win.type !== 'normal' || win.state === 'fullscreen') return;

  await store.set({
    [originKey(tab.id)]: { windowId: win.id, index: tab.index, bounds: boundsOf(win) },
  });
  try {
    // Same place and size as the window it leaves, so it stays in the same screen zone.
    await chrome.windows.create({ tabId: tab.id, type: 'popup', focused: true, ...boundsOf(win) });
  } catch (e) {
    await store.remove(originKey(tab.id));
    throw e;
  }
}

async function putBack(tab) {
  const origin = await read(originKey(tab.id));
  if (!origin) return;
  await store.remove(originKey(tab.id));

  let home = null;
  try {
    home = await chrome.windows.get(origin.windowId);
  } catch (e) {
    // The original window is gone (the tab was its only one).
  }

  if (home && home.type === 'normal') {
    await chrome.tabs.move(tab.id, { windowId: home.id, index: origin.index });
    await chrome.tabs.update(tab.id, { active: true });
    await chrome.windows.update(home.id, { focused: true });
  } else {
    await chrome.windows.create({ tabId: tab.id, type: 'normal', focused: true, ...origin.bounds });
  }
}

// Button, shortcut and F11 all toggle. When putting back, the page may still be showing an
// element full-window (a video): tell it to stop.
async function toggle(tab) {
  if (await read(originKey(tab.id))) {
    chrome.tabs.sendMessage(tab.id, { action: 'leave' }).catch(() => {});
    await putBack(tab);
  } else {
    await popOut(tab);
  }
}

const report = (what) => (e) => console.warn('ZoneFullscreen:', what, e);

chrome.runtime.onMessage.addListener((message, sender) => {
  const tab = sender.tab;
  if (!tab || sender.frameId !== 0) return;
  const work =
    message.action === 'enter' ? (tab.active ? popOut(tab) : null) // never pull a background tab forward
    : message.action === 'exit' || message.action === 'page-loaded' ? putBack(tab)
    : null;
  if (work) work.catch(report(message.action));
});

chrome.action.onClicked.addListener((tab) => toggle(tab).catch(report('button')));

chrome.commands.onCommand.addListener((command, tab) => {
  if (command === 'toggle' && tab) toggle(tab).catch(report('shortcut'));
});

// ---- F11 ----
// Extensions cannot intercept F11, so we watch for a window becoming fullscreen, undo it,
// and pop the active tab out instead. A window that was maximized keeps its real fullscreen:
// it had the whole screen already.

async function rememberState(win) {
  if (win.state !== 'fullscreen') await store.set({ [windowKey(win.id)]: win.state });
}

async function onBoundsChanged(win) {
  if (win.state !== 'fullscreen') return rememberState(win);
  if ((await read(windowKey(win.id))) === 'maximized') return;

  const [tab] = await chrome.tabs.query({ windowId: win.id, active: true });
  if (!tab) return;
  const poppedOut = Boolean(await read(originKey(tab.id)));
  if (win.type !== 'normal' && !poppedOut) return; // someone else's popup or app window

  await chrome.windows.update(win.id, { state: 'normal' });
  await toggle(tab);
}

chrome.windows.onBoundsChanged.addListener((win) => onBoundsChanged(win).catch(report('F11')));
chrome.windows.onCreated.addListener((win) => rememberState(win).catch(report('created')));
chrome.windows.onRemoved.addListener((windowId) => store.remove(windowKey(windowId)));
chrome.tabs.onRemoved.addListener((tabId) => store.remove(originKey(tabId)));

// Windows that were already open when this worker (re)started.
chrome.windows.getAll().then((all) => Promise.all(all.map(rememberState))).catch(report('startup'));
