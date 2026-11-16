// Keeps "fullscreen" inside the browser window's own place on screen.
//
// Instead of real fullscreen, the tab is moved into a bare "popup" window (title bar only)
// with the same position and size as the window it came from, and moved back afterwards.
// Three things trigger it:
//   - a page asks for fullscreen (video players): inject.js reports 'enter' / 'exit'
//   - F11: the window really goes fullscreen for a moment; we undo that and pop the tab out
//   - the toolbar button or the keyboard shortcut
//
// A tab popped out by the page goes back when the page leaves fullscreen or navigates away; one
// popped out by the user (F11, button, shortcut) stays out until the user puts it back.
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

// by: 'page' or 'user', whoever asked.
async function popOut(tab, by) {
  if (await read(originKey(tab.id))) return; // already popped out
  const win = await chrome.windows.get(tab.windowId);
  if (win.type !== 'normal' || win.state === 'fullscreen') return;

  await store.set({
    [originKey(tab.id)]: { windowId: win.id, index: tab.index, bounds: boundsOf(win), by },
  });
  try {
    // Same place and size as the window it leaves, so it stays in the same screen zone.
    await chrome.windows.create({ tabId: tab.id, type: 'popup', focused: true, ...boundsOf(win) });
  } catch (e) {
    await store.remove(originKey(tab.id));
    throw e;
  }
}

// onlyBy: put back only a tab that was popped out by that party.
async function putBack(tab, onlyBy) {
  const origin = await read(originKey(tab.id));
  if (!origin || (onlyBy && origin.by !== onlyBy)) return;
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
    await popOut(tab, 'user');
  }
}

// One thing at a time: a page message and a window event often arrive together for the same
// tab, and two moves of one tab at once would leave it in the wrong window.
let queue = Promise.resolve();
function serial(what, work) {
  queue = queue.then(work).catch((e) => console.warn('ZoneFullscreen:', what, e));
}

chrome.runtime.onMessage.addListener((message, sender) => {
  const tab = sender.tab;
  if (!tab || sender.frameId !== 0) return;
  if (message.action === 'enter') {
    if (tab.active) serial('enter', () => popOut(tab, 'page')); // never pull a background tab forward
  } else if (message.action === 'exit' || message.action === 'page-loaded') {
    serial(message.action, () => putBack(tab, 'page'));
  }
});

chrome.action.onClicked.addListener((tab) => serial('button', () => toggle(tab)));

chrome.commands.onCommand.addListener((command, tab) => {
  if (command === 'toggle' && tab) serial('shortcut', () => toggle(tab));
});

// ---- F11, and fullscreen buttons the page has no say in ----
// Extensions cannot intercept F11, so we watch for a window becoming fullscreen, undo it,
// and pop the active tab out instead. A window that was maximized keeps its real fullscreen:
// it had the whole screen already.
// The fullscreen button of a <video controls> player ends up here too, because it bypasses the
// API that inject.js replaces. In that case the page keeps the video full-window.

async function rememberState(win) {
  if (win.state !== 'fullscreen') await store.set({ [windowKey(win.id)]: win.state });
}

async function onBoundsChanged(event) {
  if (event.state !== 'fullscreen') return rememberState(event);
  // Several events arrive for one change: by now an earlier one may have dealt with it.
  const win = await chrome.windows.get(event.id);
  if (win.state !== 'fullscreen') return;
  if ((await read(windowKey(win.id))) === 'maximized') return;

  const [tab] = await chrome.tabs.query({ windowId: win.id, active: true });
  if (!tab) return;
  const poppedOut = Boolean(await read(originKey(tab.id)));
  if (win.type !== 'normal' && !poppedOut) return; // someone else's popup or app window

  // Ask the page before undoing: afterwards the browser has forgotten the element.
  const element = await chrome.tabs.sendMessage(tab.id, { action: 'adopt' }, { frameId: 0 }).catch(() => null);
  await chrome.windows.update(win.id, { state: 'normal' });
  if (element === 'entered') await popOut(tab, 'page');
  else if (element === 'left') await putBack(tab, 'page');
  else await toggle(tab); // F11, or a page this extension is not running in
}

chrome.windows.onBoundsChanged.addListener((win) => serial('F11', () => onBoundsChanged(win)));
chrome.windows.onCreated.addListener((win) => serial('created', () => rememberState(win)));
chrome.windows.onRemoved.addListener((windowId) => store.remove(windowKey(windowId)));
chrome.tabs.onRemoved.addListener((tabId) => store.remove(originKey(tabId)));

// Windows that were already open when this worker (re)started.
serial('startup', async () => Promise.all((await chrome.windows.getAll()).map(rememberState)));
