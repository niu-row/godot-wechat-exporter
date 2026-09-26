function noop() {}

function setIfMissing(target, key, value) {
  try {
    const current = target[key];
    if (current !== undefined && current !== null) return current;
  } catch (error) {}
  try {
    target[key] = value;
    return target[key];
  } catch (error) {}
  try {
    Object.defineProperty(target, key, { value, writable: true, configurable: true });
    return value;
  } catch (error) {
    return undefined;
  }
}

function patchDocumentCanvasLookup(document, canvas) {
  const originalQuerySelector = typeof document.querySelector === 'function'
    ? document.querySelector.bind(document)
    : null;
  const originalQuerySelectorAll = typeof document.querySelectorAll === 'function'
    ? document.querySelectorAll.bind(document)
    : null;
  const originalGetElementById = typeof document.getElementById === 'function'
    ? document.getElementById.bind(document)
    : null;

  try {
    document.querySelector = (selector) => {
      if (selector === '#canvas' || selector === 'canvas') return canvas;
      return originalQuerySelector ? originalQuerySelector(selector) : null;
    };
  } catch (error) {}

  try {
    document.querySelectorAll = (selector) => {
      if (selector === '#canvas' || selector === 'canvas') return [canvas];
      return originalQuerySelectorAll ? originalQuerySelectorAll(selector) : [];
    };
  } catch (error) {}

  try {
    document.getElementById = (id) => {
      if (id === 'canvas' || id === canvas.id) return canvas;
      return originalGetElementById ? originalGetElementById(id) : null;
    };
  } catch (error) {}
}

function makeEventTarget() {
  const listeners = new Map();
  return {
    addEventListener(type, callback) {
      if (!listeners.has(type)) listeners.set(type, new Set());
      listeners.get(type).add(callback);
    },
    removeEventListener(type, callback) {
      listeners.get(type)?.delete(callback);
    },
    dispatchEvent(event) {
      for (const callback of listeners.get(event.type) || []) {
        callback(event);
      }
      return true;
    },
  };
}

function makeElement(tagName) {
  const target = makeEventTarget();
  return Object.assign(target, {
    tagName: String(tagName || '').toUpperCase(),
    style: {},
    children: [],
    appendChild(child) {
      this.children.push(child);
      child.parentElement = this;
      return child;
    },
    removeChild(child) {
      this.children = this.children.filter((item) => item !== child);
    },
    insertAdjacentElement: noop,
    setAttribute: noop,
    remove: noop,
    focus: noop,
    blur: noop,
    parentElement: null,
    value: '',
    textContent: '',
  });
}

function normalizeTouchEvent(event) {
  if (typeof event.preventDefault !== 'function') event.preventDefault = noop;
  if (typeof event.stopPropagation !== 'function') event.stopPropagation = noop;
  if (typeof event.cancelable !== 'boolean') event.cancelable = false;
  if (!event.changedTouches) event.changedTouches = event.touches || [];
  return event;
}
function installCanvasMethods(canvas, document, info) {
  const events = makeEventTarget();
  const dpr = info.pixelRatio || 1;
  let logicalWidth = info.windowWidth || info.screenWidth || canvas.width / dpr;
  let logicalHeight = info.windowHeight || info.screenHeight || canvas.height / dpr;

  canvas.id = canvas.id || 'canvas';
  canvas.style = canvas.style || {};
  canvas.tabIndex = 0;
  canvas.focus = () => { document.activeElement = canvas; };
  canvas.blur = () => { document.activeElement = null; };
  canvas.insertAdjacentElement = noop;
  canvas.getBoundingClientRect = () => ({
    x: 0,
    y: 0,
    left: 0,
    top: 0,
    right: logicalWidth,
    bottom: logicalHeight,
    width: logicalWidth,
    height: logicalHeight,
  });
  canvas.__wxSetLogicalSize = (width, height) => {
    logicalWidth = Math.max(1, Number(width) || logicalWidth);
    logicalHeight = Math.max(1, Number(height) || logicalHeight);
  };

  canvas.addEventListener = events.addEventListener;
  canvas.removeEventListener = events.removeEventListener;
  canvas.dispatchEvent = events.dispatchEvent;

  const forward = (type, event) => {
    event.type = type;
    canvas.dispatchEvent(normalizeTouchEvent(event));
  };
  if (typeof wx.onTouchStart === 'function') {
    wx.onTouchStart((event) => forward('touchstart', event));
    wx.onTouchMove((event) => forward('touchmove', event));
    wx.onTouchEnd((event) => forward('touchend', event));
    wx.onTouchCancel((event) => forward('touchcancel', event));
  }
}

function installRandom(root) {
  if (root.crypto?.getRandomValues) return;
  root.crypto = root.crypto || {};
  root.crypto.getRandomValues = (array) => {
    for (let i = 0; i < array.length; i += 1) {
      array[i] = Math.floor(Math.random() * 256);
    }
    return array;
  };
}
export function installWxGodotAdapter() {
  const root = typeof GameGlobal !== 'undefined' ? GameGlobal : globalThis;
  if (root.__wxGodotAdapter) return root.__wxGodotAdapter;

  const info = typeof wx.getWindowInfo === 'function'
    ? wx.getWindowInfo()
    : wx.getSystemInfoSync();
  const dpr = info.pixelRatio || 1;
  const logicalWidth = info.windowWidth || info.screenWidth || 375;
  const logicalHeight = info.windowHeight || info.screenHeight || 667;
  const canvas = wx.createCanvas();
  canvas.width = Math.max(1, Math.floor(logicalWidth * dpr));
  canvas.height = Math.max(1, Math.floor(logicalHeight * dpr));

  const documentEvents = makeEventTarget();
  const document = Object.assign(documentEvents, {
    activeElement: canvas,
    body: makeElement('body'),
    head: makeElement('head'),
    currentScript: null,
    hidden: false,
    visibilityState: 'visible',
    fullscreenElement: null,
    pointerLockElement: null,
    fullscreenEnabled: false,

    title: '',
    exitFullscreen: () => Promise.resolve(),
    exitPointerLock: noop,
    createElement(tagName) {
      const tag = String(tagName || '').toLowerCase();
      if (tag === 'canvas') return wx.createCanvas();
      if (tag === 'img' || tag === 'image') return wx.createImage();
      return makeElement(tagName);
    },
    getElementsByTagName(tagName) {
      return String(tagName).toLowerCase() === 'canvas' ? [canvas] : [];
    },
    getElementById(id) {
      return id === 'canvas' ? canvas : null;
    },
    querySelector(selector) {
      return selector === '#canvas' || selector === 'canvas' ? canvas : null;
    },
    querySelectorAll(selector) {
      return selector === '#canvas' || selector === 'canvas' ? [canvas] : [];
    },
  });

  installCanvasMethods(canvas, document, info);

  const windowEvents = makeEventTarget();
  setIfMissing(root, 'window', root);
  setIfMissing(root, 'self', root);
  const hostDocument = setIfMissing(root, 'document', document) || document;
  setIfMissing(hostDocument, 'createElement', document.createElement.bind(document));
  setIfMissing(hostDocument, 'getElementsByTagName', document.getElementsByTagName.bind(document));
  setIfMissing(hostDocument, 'getElementById', document.getElementById.bind(document));
  setIfMissing(hostDocument, 'querySelector', document.querySelector.bind(document));
  setIfMissing(hostDocument, 'querySelectorAll', document.querySelectorAll.bind(document));
  setIfMissing(hostDocument, 'addEventListener', document.addEventListener.bind(document));
  setIfMissing(hostDocument, 'removeEventListener', document.removeEventListener.bind(document));
  patchDocumentCanvasLookup(hostDocument, canvas);
  setIfMissing(root, 'canvas', canvas);
  setIfMissing(root, 'innerWidth', logicalWidth);
  setIfMissing(root, 'innerHeight', logicalHeight);
  setIfMissing(root, 'devicePixelRatio', dpr);
  const screen = setIfMissing(root, 'screen', {}) || {};
  setIfMissing(screen, 'width', logicalWidth);
  setIfMissing(screen, 'height', logicalHeight);
  setIfMissing(screen, 'availWidth', logicalWidth);
  setIfMissing(screen, 'availHeight', logicalHeight);
  setIfMissing(root, 'addEventListener', windowEvents.addEventListener);
  setIfMissing(root, 'removeEventListener', windowEvents.removeEventListener);
  setIfMissing(root, 'dispatchEvent', windowEvents.dispatchEvent);
  setIfMissing(root, 'alert', (...args) => {
    console.warn('[window.alert]', ...args);
  });
  setIfMissing(root, 'open', () => null);
  const location = setIfMissing(root, 'location', {
    href: 'game:///',
    origin: 'game://',
    pathname: '/',
  });
  document.location = location;

  const language = info.language || 'en';
  const navigator = setIfMissing(root, 'navigator', {}) || {};
  setIfMissing(navigator, 'userAgent', `WeChatMiniGame/${info.SDKVersion || ''}`);
  setIfMissing(navigator, 'platform', info.platform || 'wechat');
  setIfMissing(navigator, 'language', language);
  setIfMissing(navigator, 'languages', [language]);
  setIfMissing(navigator, 'hardwareConcurrency', 4);
  setIfMissing(navigator, 'getGamepads', () => []);

  setIfMissing(root, 'Image', function Image() {
    return wx.createImage();
  });
  setIfMissing(root, 'HTMLCanvasElement', canvas.constructor);
  setIfMissing(root, 'performance', { now: () => Date.now() });
  installRandom(root);

  if (typeof root.WebAssembly === 'undefined') {
    root.WebAssembly = WXWebAssembly;
    try {
      if (!root.WebAssembly.RuntimeError) root.WebAssembly.RuntimeError = Error;
    } catch (error) {
      console.warn('[wx-godot] WebAssembly.RuntimeError shim unavailable', error);
    }
  }

  function lifecycleRecord(stage, source) {
    const runtime = root.godotEngine?.rtenv;
    const item = {
      time: Date.now(),
      stage,
      source,
      audioState: runtime?.wxAudioState ? runtime.wxAudioState() : 'unavailable',
    };
    console.log('[wx-godot-lifecycle]', item);
    return item;
  }

  async function hideRuntime(source = 'manual') {
    document.hidden = true;
    document.visibilityState = 'hidden';
    document.dispatchEvent({ type: 'visibilitychange' });
    canvas.dispatchEvent({ type: 'blur' });
    const runtime = root.godotEngine?.rtenv;
    lifecycleRecord('hide_begin', source);
    await Promise.resolve(runtime?.wxFSSync?.());
    await Promise.resolve(runtime?.wxAudioSuspend?.());
    return lifecycleRecord('hide_complete', source);
  }

  async function showRuntime(source = 'manual') {
    document.hidden = false;
    document.visibilityState = 'visible';
    document.dispatchEvent({ type: 'visibilitychange' });
    const runtime = root.godotEngine?.rtenv;
    lifecycleRecord('show_begin', source);
    await Promise.resolve(runtime?.wxAudioResume?.());
    canvas.dispatchEvent({ type: 'focus' });
    return lifecycleRecord('show_complete', source);
  }

  root.__wxGodotLifecycle = {
    hide: () => hideRuntime('manual'),
    show: () => showRuntime('manual'),
    snapshot: () => lifecycleRecord('snapshot', 'manual'),
  };
  if (typeof wx.onHide === 'function') wx.onHide(() => hideRuntime('wx').catch(console.error));
  if (typeof wx.onShow === 'function') wx.onShow(() => showRuntime('wx').catch(console.error));
  if (typeof wx.onWindowResize === 'function') {
    wx.onWindowResize((event) => {
      root.innerWidth = event.windowWidth || root.innerWidth;
      root.innerHeight = event.windowHeight || root.innerHeight;
      root.screen.width = root.innerWidth;
      root.screen.height = root.innerHeight;
      root.screen.availWidth = root.innerWidth;
      root.screen.availHeight = root.innerHeight;
      info.windowWidth = root.innerWidth;
      info.windowHeight = root.innerHeight;
      canvas.__wxSetLogicalSize?.(root.innerWidth, root.innerHeight);
      root.dispatchEvent({ type: 'resize' });
    });
  }

  const adapter = { root, canvas, document, info };
  root.__wxGodotAdapter = adapter;
  return adapter;
}
