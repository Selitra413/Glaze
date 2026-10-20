// A mouse-wheel notch on Windows reaches the page through the relay — see
// assets/chat_webview/bridge/scroll_relay.js — and has to scroll the way one
// does in a browser: the whole distance, spread over a few frames, notches in a
// row adding up, and nothing saved up past the end of the chat. These drive the
// real bridge in the real page.
import { test, expect } from '@playwright/test';

const PAGE = '/assets/chat_webview/index.html';
const CURSOR = { x: 300, y: 300 };

async function openChat(page) {
  await page.goto(PAGE);
  await page.waitForFunction(() => !!window.bridge);
  await page.evaluate(() => {
    const msgs = [];
    for (let i = 0; i < 40; i++) {
      msgs.push({
        id: 'm' + i,
        role: i % 2 ? 'user' : 'assistant',
        text: 'message number ' + i + ' ' + 'lorem ipsum '.repeat(40),
        timestamp: 1767225600000,
        isUser: i % 2 === 1,
        isAssistant: i % 2 === 0,
        isSystem: false,
        isError: false,
        isHidden: false,
        isGenerating: false,
        isPostGenRunning: false,
      });
    }
    window.bridge.setMessages(JSON.stringify(msgs));
    window.bridge.setBottomPadding(130, 0);
  });
  await page.waitForTimeout(500);
  // Text laid out in a fallback face reflows when the real one arrives, and
  // every row changes height with it.
  await page.evaluate(() => document.fonts.ready);
  // Start at the very end, as an opened chat does.
  await page.evaluate(() => {
    const c = document.getElementById('chat-container');
    c.scrollTop = c.scrollHeight;
  });
  // And let the list come to rest, in height as well as position: a row
  // measured late grows the list and the anchor correction moves the
  // position with it, and a start read before that is not the start the
  // scrolls below add to.
  const layout = () =>
    page.evaluate(() => {
      const c = document.getElementById('chat-container');
      return c.scrollTop + ':' + c.scrollHeight;
    });
  await expect.poll(async () => {
    const a = await layout();
    await page.waitForTimeout(300);
    return a === (await layout());
  }, { timeout: 8000 }).toBe(true);
}

const scrollTop = (page) =>
  page.evaluate(() => document.getElementById('chat-container').scrollTop);

const wheel = (page, dy) =>
  page.evaluate(
    ([d, at]) => window.bridge.wheelScroll(0, d, at.x, at.y),
    [dy, CURSOR],
  );

// Within two pixels: the virtual list may nudge the position by one as a
// row re-measures, and a busy runner can hold a frame back.
const settled = (page, target) =>
  expect.poll(async () => Math.abs((await scrollTop(page)) - target) < 2, {
    timeout: 5000,
  }).toBe(true);

test('a notch scrolls its whole distance over several frames, not in one jump', async ({ page }) => {
  await openChat(page);
  await page.evaluate(() => window.bridge.relayNativeWheel(true));
  const start = await scrollTop(page);
  expect(start).toBeGreaterThan(1000);

  // Nothing moves in the call itself: the whole notch is owed to the frames
  // that follow, and every position the chat passes through is recorded.
  const owed = await page.evaluate(([d, at]) => {
    const c = document.getElementById('chat-container');
    window.bridge.wheelScroll(0, d, at.x, at.y);
    const positions = [c.scrollTop];
    window.__positions = positions;
    const until = performance.now() + 3000;
    const sample = () => {
      const st = c.scrollTop;
      if (st !== positions[positions.length - 1]) positions.push(st);
      if (performance.now() < until) requestAnimationFrame(sample);
    };
    requestAnimationFrame(sample);
    return { moved: c.scrollTop, pending: window.bridge._scrollRelay.pendingWheel.dy };
  }, [-300, CURSOR]);
  expect(owed.moved).toBe(start);
  expect(owed.pending).toBe(-300);

  await settled(page, start - 300);
  // Several stops on the way — a frame can be late and carry a bigger share,
  // but never the whole distance at once.
  const positions = await page.evaluate(() => window.__positions);
  const onTheWay = positions.filter((p) => p < start && p > start - 300);
  expect(onTheWay.length).toBeGreaterThanOrEqual(3);
});

test('notches in a row add up', async ({ page }) => {
  await openChat(page);
  await page.evaluate(() => window.bridge.relayNativeWheel(true));
  const start = await scrollTop(page);

  await wheel(page, -100);
  await wheel(page, -100);
  await wheel(page, -100);

  await settled(page, start - 300);
});

test('a notch past the end of the chat is dropped, not saved for the way back', async ({ page }) => {
  await openChat(page);
  await page.evaluate(() => window.bridge.relayNativeWheel(true));
  const end = await scrollTop(page);

  // Already at the end: nothing to scroll, nothing to remember.
  await wheel(page, 500);
  await page.waitForTimeout(300);
  expect(await scrollTop(page)).toBe(end);

  await wheel(page, -100);
  await settled(page, end - 100);
});

test('the trusted wheel is kept until the relay is on, then dropped', async ({ page }) => {
  await openChat(page);
  const start = await scrollTop(page);
  await page.mouse.move(CURSOR.x, CURSOR.y);

  // Without the relay the page scrolls its own wheel, as every other platform
  // does.
  await page.mouse.wheel(0, -100);
  await settled(page, start - 100);

  // With it, the trusted event is the plugin's duplicate of a notch Flutter
  // already relayed.
  await page.evaluate(() => window.bridge.relayNativeWheel(true));
  await page.mouse.wheel(0, -100);
  await page.waitForTimeout(300);
  expect(Math.abs((await scrollTop(page)) - (start - 100))).toBeLessThan(0.6);
});

test('reduced motion scrolls a notch at once', async ({ page }) => {
  await openChat(page);
  await page.evaluate(() => window.bridge.relayNativeWheel(true));
  // Emulated once the page is up, and checked: on a busy CI runner the
  // emulation set before the load reached the document late, and the notch
  // animated.
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await expect.poll(() =>
    page.evaluate(() => matchMedia('(prefers-reduced-motion: reduce)').matches),
  ).toBe(true);
  const start = await scrollTop(page);

  // Read in the same breath as the call: nothing is left for a later frame.
  const after = await page.evaluate(([d, at]) => {
    window.bridge.wheelScroll(0, d, at.x, at.y);
    return document.getElementById('chat-container').scrollTop;
  }, [-300, CURSOR]);

  expect(Math.abs(after - (start - 300))).toBeLessThan(0.6);
});
