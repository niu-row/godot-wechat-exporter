const TRACE_KEY = '__wx_godot_trace';
const CONSOLE_KEY = '__wx_godot_console';
let traceEnabled = false;

export function configureTrace(enabled) {
  traceEnabled = Boolean(enabled);
}

function serializeValue(value) {
  if (value instanceof Error) return value.stack || value.message || String(value);
  if (typeof value === 'string') return value;
  try { return JSON.stringify(value); } catch (error) { return String(value); }
}

function persistConsole(level, args, source = 'console') {
  try {
    const history = wx.getStorageSync(CONSOLE_KEY) || [];
    history.push({ time: Date.now(), level, source, args: Array.from(args).map(serializeValue) });
    wx.setStorageSync(CONSOLE_KEY, history.slice(-100));
  } catch (error) {}
}

export function installConsoleCapture() {
  if (!traceEnabled) return;
  const root = typeof GameGlobal !== 'undefined' ? GameGlobal : globalThis;
  if (root.__wxGodotConsoleCapture) return;
  root.__wxGodotConsoleCapture = true;
  for (const level of ['warn', 'error']) {
    const original = console[level].bind(console);
    console[level] = (...args) => {
      persistConsole(level, args);
      original(...args);
    };
  }
  if (typeof wx.onError === 'function') {
    wx.onError((message) => persistConsole('error', [message], 'wx.onError'));
  }
  if (typeof wx.onUnhandledRejection === 'function') {
    wx.onUnhandledRejection((event) => persistConsole('error', [event?.reason || event], 'wx.onUnhandledRejection'));
  }
}

export function trace(stage, detail = null) {
  const entry = {
    time: Date.now(),
    stage,
    detail,
  };
  if (!traceEnabled) return entry;
  console.log('[wx-godot-trace]', stage, detail || '');
  try {
    const history = wx.getStorageSync(TRACE_KEY) || [];
    history.push(entry);
    wx.setStorageSync(TRACE_KEY, history.slice(-50));
  } catch (error) {
    console.warn('[wx-godot-trace] persist failed', error);
  }
  return entry;
}

export function traceError(stage, error) {
  const detail = error && error.stack
    ? error.stack
    : String(error);
  return trace(stage, detail);
}
