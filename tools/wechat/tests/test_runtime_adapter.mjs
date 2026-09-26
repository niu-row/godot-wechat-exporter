import assert from 'node:assert/strict';
import fs from 'node:fs';

const adapterUrl = new URL(
  '../../../addons/wechat_exporter/toolchain/template/runtime/wx_adapter.js',
  import.meta.url,
);
const adapterSource = fs.readFileSync(adapterUrl, 'utf8');

let resizeHandler = null;
globalThis.wx = {
  getWindowInfo: () => ({
    windowWidth: 375,
    windowHeight: 667,
    screenWidth: 375,
    screenHeight: 667,
    pixelRatio: 2,
    language: 'en',
    platform: 'test',
    SDKVersion: 'test',
  }),
  createCanvas: () => ({}),
  createImage: () => ({}),
  onWindowResize: (callback) => { resizeHandler = callback; },
};

const dataUrl = `data:text/javascript;base64,${Buffer
  .from(adapterSource)
  .toString('base64')}`;
const { installWxGodotAdapter } = await import(dataUrl);
const adapter = installWxGodotAdapter();

assert.equal(adapter.canvas.getBoundingClientRect().width, 375);
assert.equal(adapter.canvas.getBoundingClientRect().height, 667);
assert.equal(adapter.canvas.width, 750);
assert.equal(adapter.canvas.height, 1334);
assert.equal(typeof resizeHandler, 'function');

resizeHandler({ windowWidth: 812, windowHeight: 375 });

assert.equal(adapter.canvas.getBoundingClientRect().width, 812);
assert.equal(adapter.canvas.getBoundingClientRect().height, 375);
assert.equal(globalThis.innerWidth, 812);
assert.equal(globalThis.innerHeight, 375);
assert.equal(globalThis.screen.width, 812);
assert.equal(globalThis.screen.height, 375);
assert.equal(globalThis.screen.availWidth, 812);
assert.equal(globalThis.screen.availHeight, 375);
assert.equal(adapter.info.windowWidth, 812);
assert.equal(adapter.info.windowHeight, 375);

const gameSource = fs.readFileSync(
  new URL('../../../addons/wechat_exporter/toolchain/template/game.js', import.meta.url),
  'utf8',
);
assert.equal(gameSource.includes('removeStorageSync'), false);
assert.equal(gameSource.includes("trace('session_begin'"), true);
console.log('RUNTIME_ADAPTER_TESTS_OK');
