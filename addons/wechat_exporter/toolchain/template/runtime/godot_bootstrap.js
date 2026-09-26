import { installWxGodotAdapter } from './wx_adapter';
import { trace } from './trace';

const root = typeof GameGlobal !== 'undefined' ? GameGlobal : globalThis;
const subpackagePromises = new Map();

function errorDetail(error) {
  return error && error.stack ? error.stack : String(error);
}

function loadSubpackage(name) {
  if (subpackagePromises.has(name)) return subpackagePromises.get(name);
  const promise = new Promise((resolve, reject) => {
    const task = wx.loadSubpackage({ name, success: resolve, fail: reject });
    if (task && typeof task.onProgressUpdate === 'function') {
      task.onProgressUpdate((progress) => {
        console.log(`[wx-godot] ${name} download`, progress.progress);
      });
    }
  }).catch((error) => {
    subpackagePromises.delete(name);
    throw error;
  });
  subpackagePromises.set(name, promise);
  return promise;
}

function unpackProject() {
  const fs = wx.getFileSystemManager();
  const targetPath = `${wx.env.USER_DATA_PATH}/wx-godot-project`;
  try { fs.rmdirSync(targetPath, true); } catch (error) {}
  try { fs.mkdirSync(targetPath, true); } catch (error) {}
  trace('project_unpack_begin');
  return new Promise((resolve, reject) => {
    fs.unzip({
      zipFilePath: '/data/project.zip',
      targetPath,
      success: () => {
        trace('project_unpack_resolved');
        resolve(`${targetPath}/project.bin`);
      },
      fail: (error) => reject(new Error(`project unzip failed: ${error.errMsg || error}`)),
    });
  });
}

async function bootGodotOnce() {
  trace('boot_enter');
  const { canvas, info } = installWxGodotAdapter();
  trace('adapter_ready', {
    width: canvas.width,
    height: canvas.height,
    pixelRatio: info.pixelRatio || 1,
  });

  await Promise.all([loadSubpackage('engine'), loadSubpackage('data')]);
  trace('subpackages_loaded');
  const projectPack = await unpackProject();

  const Engine = root.Engine;
  if (typeof Engine !== 'function') {
    throw new Error('Godot Engine constructor was not exposed by engine subpackage');
  }

  const engine = new Engine({
    executable: 'engine/godot',
    mainPack: projectPack,
    canvas,
    canvasResizePolicy: 0,
    persistentPaths: ['/userfs'],
    focusCanvas: false,
    experimentalVK: false,
    serviceWorker: '',
    onPrint: (...args) => console.log('[Godot]', ...args),
    onPrintError: (...args) => console.error('[Godot]', ...args),
    onProgress: (current, total) => {
      console.log('[wx-godot] project preload', current, total);
    },
  });

  root.godotEngine = engine;
  trace('start_game_begin');
  await engine.startGame();
  trace('start_game_resolved');
  console.log('[wx-godot] Godot startGame resolved');
  return engine;
}

export function bootGodot() {
  if (root.__wxGodotBootPromise) return root.__wxGodotBootPromise;
  root.__wxGodotBootPromise = bootGodotOnce().catch((error) => {
    trace('boot_failed', errorDetail(error));
    root.__wxGodotBootPromise = null;
    throw error;
  });
  return root.__wxGodotBootPromise;
}
