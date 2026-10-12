// Standalone JS-only smoke test: node test/manual/translation_bridge_smoke.mjs
// No Flutter SDK needed. Checks the actual methods extracted from Bridge.
import fs from 'node:fs';

const code = fs.readFileSync('assets/chat_webview/bridge/chat_bridge_controller.js', 'utf8');
const start = code.indexOf('  /* ---------- Ephemeral, visual-only translated overlays ---------- */');
const end = code.indexOf('  /* ---------- Message list API ---------- */', start);
if (start < 0 || end < 0) throw Error('Translation overlay methods not found');
const Fixture = new Function(`return class Fixture { ${code.slice(start, end)} };`)();
const element = {
  dataset: { messageId: 'id-001', rawText: 'Hello' },
  classList: { contains: () => false },
};
globalThis.document = { querySelectorAll: () => [element] };
const rendered = [];
const bridge = new Fixture();
bridge._visualTranslations = new Map();
bridge.renderer = { updateMessageContent: (_, text) => rendered.push(text) };
bridge.setVisualTranslation(JSON.stringify({id: 'id-001', original: 'Hello', text: 'Привет'}));
if (rendered.at(-1) !== 'Привет' || element.dataset.rawText !== 'Hello') {
  throw Error('Visual translation must not overwrite the original text');
}
bridge.clearVisualTranslation('id-001');
if (rendered.at(-1) !== 'Hello') throw Error('Original was not restored');
bridge.setVisualTranslation(JSON.stringify({id: 'id-001', original: 'Hello', text: 'Привет'}));
element.dataset.rawText = 'Another swipe';
bridge._applyVisualTranslation(element);
if (bridge._visualTranslations.has('id-001')) throw Error('Stale swipe translation survived');
console.log('PASS: visual overlay, original restoration, swipe invalidation');
