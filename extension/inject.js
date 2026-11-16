// Runs inside every page (and every frame), in the page's own JavaScript world.
// Replaces the Fullscreen API with a version that makes the element fill the browser
// window instead of the screen. A maximized window keeps the real fullscreen: it already
// has the whole screen.
(() => {
  if (window.__zoneFullscreen) return;
  window.__zoneFullscreen = true;

  const ELEMENT = 'zf-fullwindow';
  const ANCESTOR = 'zf-fullwindow-ancestor';
  const ROOT = 'zf-fullwindow-root';
  const isTop = window === window.top;

  const nativeRequest = Element.prototype.requestFullscreen;
  const nativeWebkitRequest = Element.prototype.webkitRequestFullscreen;
  const nativeExit = Document.prototype.exitFullscreen;
  const nativeElementGetter =
    Object.getOwnPropertyDescriptor(Document.prototype, 'fullscreenElement')?.get;

  let current = null;      // element currently filling the window
  let marked = [];         // ancestors we tagged, so we untag exactly those

  // outerWidth/outerHeight describe the browser window even from inside a frame.
  function windowIsMaximized() {
    return window.outerWidth >= screen.availWidth && window.outerHeight >= screen.availHeight;
  }

  function fire(target) {
    for (const type of ['fullscreenchange', 'webkitfullscreenchange']) {
      target.dispatchEvent(new Event(type, { bubbles: true, composed: true }));
    }
  }

  function mark(el) {
    el.classList.add(ELEMENT);
    marked = [];
    // Walk up through shadow roots too, so players built from web components work.
    let node = el.parentNode;
    while (node && node !== document) {
      if (node instanceof ShadowRoot) { node = node.host; continue; }
      if (node instanceof Element && node !== document.documentElement) {
        node.classList.add(ANCESTOR);
        marked.push(node);
      }
      node = node.parentNode;
    }
    document.documentElement.classList.add(ROOT);
  }

  function unmark(el) {
    el.classList.remove(ELEMENT);
    for (const node of marked) node.classList.remove(ANCESTOR);
    marked = [];
    document.documentElement.classList.remove(ROOT);
  }

  // Tell the outside: the top page talks to the extension, a frame talks to its parent page.
  function announce(entering) {
    if (isTop) {
      document.dispatchEvent(new CustomEvent('zf-popout', { detail: entering ? 'enter' : 'exit' }));
    } else {
      window.parent.postMessage({ zoneFullscreen: entering ? 'frame-enter' : 'frame-exit' }, '*');
    }
  }

  function enter(el) {
    if (current === el) return;
    const wasActive = current !== null;
    if (current) unmark(current);
    current = el;
    mark(el);
    if (!wasActive) announce(true);
    fire(el);
    window.dispatchEvent(new Event('resize'));
  }

  function leave(tellOutside = true) {
    if (!current) return;
    const el = current;
    current = null;
    unmark(el);
    // If the element is a frame, the page inside it must leave too.
    if (el instanceof HTMLIFrameElement && el.contentWindow) {
      el.contentWindow.postMessage({ zoneFullscreen: 'exit-from-parent' }, '*');
    }
    if (tellOutside) announce(false);
    fire(el.isConnected ? el : document);
    window.dispatchEvent(new Event('resize'));
  }

  // The browser only grants fullscreen right after a click or key press, and only where the
  // document is allowed to use it. We replace its API, so we must keep both rules ourselves:
  // otherwise any page or ad frame could take over the window (and have the tab popped out)
  // without the user doing anything.
  function userJustActed() {
    return !navigator.userActivation || navigator.userActivation.isActive;
  }
  function mayGoFullscreen() {
    return document.fullscreenEnabled !== false && userJustActed();
  }
  function refuse(el) {
    for (const type of ['fullscreenerror', 'webkitfullscreenerror']) {
      el.dispatchEvent(new Event(type, { bubbles: true, composed: true }));
    }
  }

  function frameAllowsFullscreen(frame) {
    return frame.allowFullscreen || /(^|[;\s])fullscreen/.test(frame.getAttribute('allow') || '');
  }

  window.addEventListener('message', (e) => {
    const kind = e.data && e.data.zoneFullscreen;
    if (!kind) return;
    if (kind === 'exit-from-parent') {
      if (e.source === window.parent) leave(false);
      return;
    }
    // A child frame entered or left: grow or shrink the <iframe> that contains it.
    const frame = [...document.querySelectorAll('iframe')].find((f) => f.contentWindow === e.source);
    if (!frame) return;
    // A click inside the frame counts as the user acting on this page too.
    if (kind === 'frame-enter' && frameAllowsFullscreen(frame) && userJustActed()) enter(frame);
    else if (kind === 'frame-exit' && current === frame) leave();
  });

  window.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && current) leave();
  }, true);

  // The extension put the tab back in its window (F11, toolbar button, shortcut).
  if (isTop) document.addEventListener('zf-leave', () => leave(false));

  // The page navigated away inside the same tab (single-page apps keep running, so this is rare).
  window.addEventListener('pagehide', () => leave());

  // ---- the replaced API ----

  Element.prototype.requestFullscreen = function (options) {
    if (!current && windowIsMaximized()) return nativeRequest.call(this, options);
    if (!mayGoFullscreen()) {
      refuse(this);
      return Promise.reject(new TypeError('Fullscreen request denied'));
    }
    enter(this);
    return Promise.resolve();
  };
  if (nativeWebkitRequest) {
    const webkitRequest = function () {
      if (!current && windowIsMaximized()) return nativeWebkitRequest.call(this);
      if (!mayGoFullscreen()) { refuse(this); return; }
      enter(this);
    };
    Element.prototype.webkitRequestFullscreen = webkitRequest;
    Element.prototype.webkitRequestFullScreen = webkitRequest;
  }

  const exit = function () {
    if (current) { leave(); return Promise.resolve(); }
    return nativeExit.call(this);
  };
  Document.prototype.exitFullscreen = exit;
  Document.prototype.webkitExitFullscreen = exit;
  Document.prototype.webkitCancelFullScreen = exit;

  const elementGetter = function () {
    return current || (nativeElementGetter ? nativeElementGetter.call(this) : null);
  };
  const flagGetter = function () { return elementGetter.call(this) !== null; };
  for (const name of ['fullscreenElement', 'webkitFullscreenElement', 'webkitCurrentFullScreenElement']) {
    Object.defineProperty(Document.prototype, name, { get: elementGetter, configurable: true, enumerable: true });
  }
  for (const name of ['fullscreen', 'webkitIsFullScreen']) {
    Object.defineProperty(Document.prototype, name, { get: flagGetter, configurable: true, enumerable: true });
  }
})();
