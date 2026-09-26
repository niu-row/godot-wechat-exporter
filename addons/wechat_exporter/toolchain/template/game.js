import { bootGodot } from './runtime/godot_bootstrap';
import { configureTrace, installConsoleCapture, trace } from './runtime/trace';
import { runtimeConfig } from './runtime/build_config';

configureTrace(runtimeConfig.diagnostics);
if (runtimeConfig.diagnostics) {
  installConsoleCapture();
  trace('session_begin', { startedAt: Date.now() });
}

bootGodot().catch((error) => {
  console.error('[wx-godot] boot failed', error);
});
