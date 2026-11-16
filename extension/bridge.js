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

// The background put the tab back (F11, button, shortcut): the page must drop its full-window element.
chrome.runtime.onMessage.addListener((message) => {
  if (message && message.action === 'leave') document.dispatchEvent(new CustomEvent('zf-leave'));
});

// A freshly loaded page is never in window-fullscreen: if this tab was left popped out
// (reload, navigation), put it back where it came from.
send('page-loaded');
