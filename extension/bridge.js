// Runs in the top page only, in the extension's isolated world: relays between inject.js
// (in the page's world) and the background worker, which moves the tab between windows.
function send(action) {
  try {
    chrome.runtime.sendMessage({ action }).catch(() => {});
  } catch (e) {
    // The extension was reloaded or removed while this page stayed open: nothing to do.
  }
}

document.addEventListener('zf-popout', (e) => {
  // The page can fire this event itself, so 'enter' is checked again here, out of its reach:
  // the tab is only popped out right after a click or key press.
  if (e.detail === 'enter' && navigator.userActivation && !navigator.userActivation.isActive) return;
  if (e.detail === 'enter' || e.detail === 'exit') send(e.detail);
});

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (!message) return;
  // The background put the tab back (F11, button, shortcut): the page must drop its full-window element.
  if (message.action === 'leave') document.dispatchEvent(new CustomEvent('zf-leave'));
  // The window really went fullscreen and the background is about to undo that. If an element
  // caused it (a <video controls> button), inject.js keeps it full-window, or drops it if it
  // already was. This world sees the browser's own fullscreenElement, not the replaced one.
  if (message.action === 'adopt') {
    if (!document.fullscreenElement) { sendResponse('none'); return; }
    document.dispatchEvent(new CustomEvent('zf-adopt'));
    sendResponse(document.documentElement.classList.contains('zf-fullwindow-root') ? 'entered' : 'left');
  }
});

// A freshly loaded page shows no element full-window: if this tab was popped out for one
// (reload, navigation), put it back where it came from.
send('page-loaded');
