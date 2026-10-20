// Touchpad pans on Windows reach the page through the relay — see
// assets/chat_webview/bridge/scroll_relay.js. The embedder hands them over once
// a frame with the pad's sample jitter in them, and nothing after the fingers
// leave, so the page evens the stream out and carries a flick on the way a
// Flutter list does. These drive the real bridge in the real page.
import { test, expect } from '@playwright/test';

const PAGE = '/assets/chat_webview/index.html';
const CURSOR = { x: 300, y: 300 };

async function openChat(page) {
  await page.goto(PAGE);
  await page.waitForFunction(() => !!window.bridge);
  await page.evaluate(() => {
    const msgs = [];
    for (let i = 0; i < 60; i++) {
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
  // Start at the very end, as an opened chat does.
  await page.evaluate(() => {
    const c = document.getElementById('chat-container');
    c.scrollTop = c.scrollHeight;
  });
  await page.waitForTimeout(100);
}

const scrollTop = (page) =>
  page.evaluate(() => document.getElementById('chat-container').scrollTop);

const settled = (page, target) =>
  expect.poll(async () => Math.abs((await scrollTop(page)) - target) < 0.6, {
    timeout: 3000,
  }).toBe(true);

/**
 * Feeds one pan per frame, the way Flutter's relay does, then keeps watching
 * until the chat has stood still for ten frames. Resolves with how far the
 * chat moved in each frame, zeros at the end trimmed.
 */
const drag = (page, deltas) =>
  page.evaluate(
    ([list, at]) => new Promise((resolve) => {
      const c = document.getElementById('chat-container');
      const moves = [];
      let last = c.scrollTop;
      let fed = 0;
      let still = 0;
      const frame = () => {
        const move = c.scrollTop - last;
        last = c.scrollTop;
        moves.push(move);
        still = move === 0 ? still + 1 : 0;
        if (fed < list.length) {
          window.bridge.trackpadScroll(0, list[fed++], at.x, at.y);
        } else if (still >= 10 || moves.length > 300) {
          while (moves.length && moves[moves.length - 1] === 0) moves.pop();
          resolve(moves);
          return;
        }
        requestAnimationFrame(frame);
      };
      requestAnimationFrame(frame);
    }),
    [deltas, CURSOR],
  );

test('a jittery pan stream comes out even, and nothing of it is lost', async ({ page }) => {
  await openChat(page);
  const start = await scrollTop(page);

  // What the embedder hands over under a steady finger: two pixels one
  // frame, twelve the next.
  const deltas = [];
  for (let i = 0; i < 15; i++) deltas.push(-2, -12);
  const moves = await drag(page, deltas);

  // Once the filter has settled, the frames move by much the same amount:
  // the spread of the output, relative to its mean, is well under half the
  // input's (0.71) — about a tenth of it on a quiet machine, with room for a
  // frame or two that come late when the suite's other workers are busy.
  const spread = (list) => {
    const mean = list.reduce((a, b) => a + b, 0) / list.length;
    const variance = list.reduce((a, b) => a + (b - mean) ** 2, 0) / list.length;
    return Math.sqrt(variance) / Math.abs(mean);
  };
  const steady = moves.slice(8, 28);
  expect(spread(steady)).toBeLessThan(spread(deltas) / 2);
  // And the whole distance arrives.
  const total = deltas.reduce((a, b) => a + b, 0);
  expect(Math.abs((await scrollTop(page)) - (start + total))).toBeLessThan(0.6);
});

test('a flick keeps the chat gliding after the fingers leave, then dies away', async ({ page }) => {
  await openChat(page);
  const start = await scrollTop(page);

  await drag(page, [-40, -40, -40]);
  const lifted = await scrollTop(page);
  await page.evaluate(([at]) => window.bridge.trackpadScrollEnd(0, -2000, at.x, at.y), [CURSOR]);

  // Still moving a few frames later, and well past where the fingers left.
  await page.waitForTimeout(150);
  const gliding = await scrollTop(page);
  expect(gliding).toBeLessThan(lifted - 100);
  await page.waitForTimeout(150);
  expect(await scrollTop(page)).toBeLessThan(gliding);

  // Comes to rest: 2 px/ms dying with a 350 ms constant travels about 700 px
  // — less when the suite's other workers hold frames back, since a frame
  // more than 100 ms late is not made up for.
  await expect.poll(async () => {
    const a = await scrollTop(page);
    await page.waitForTimeout(100);
    return a === (await scrollTop(page));
  }, { timeout: 4000 }).toBe(true);
  const travelled = lifted - (await scrollTop(page));
  expect(travelled).toBeGreaterThan(350);
  expect(travelled).toBeLessThan(900);
  expect(start - lifted).toBeGreaterThan(0);
});

test('touching the pad stops the glide where it is', async ({ page }) => {
  await openChat(page);
  await page.evaluate(([at]) => {
    window.bridge.trackpadScroll(0, -20, at.x, at.y);
    window.bridge.trackpadScrollEnd(0, -3000);
  }, [CURSOR]);
  await page.waitForTimeout(120);

  await page.evaluate(() => window.bridge.trackpadScrollStart());
  await page.waitForTimeout(50);
  const stopped = await scrollTop(page);
  await page.waitForTimeout(250);
  expect(await scrollTop(page)).toBe(stopped);
});

test('a glide past the end of the chat is dropped, not saved for the way back', async ({ page }) => {
  await openChat(page);
  const end = await scrollTop(page);

  // Already at the end: a flick downwards has nowhere to go.
  await page.evaluate(([at]) => {
    window.bridge.trackpadScroll(0, 30, at.x, at.y);
    window.bridge.trackpadScrollEnd(0, 3000);
  }, [CURSOR]);
  await page.waitForTimeout(300);
  expect(await scrollTop(page)).toBe(end);

  await page.evaluate(([at]) => window.bridge.wheelScroll(0, -100, at.x, at.y), [CURSOR]);
  await settled(page, end - 100);
});

test('reduced motion follows the finger at once and does not glide', async ({ page }) => {
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await openChat(page);
  const start = await scrollTop(page);

  const after = await page.evaluate(([at]) => {
    window.bridge.trackpadScroll(0, -50, at.x, at.y);
    return document.getElementById('chat-container').scrollTop;
  }, [CURSOR]);
  expect(after).toBe(start - 50);

  await page.evaluate(() => window.bridge.trackpadScrollEnd(0, -3000));
  await page.waitForTimeout(300);
  expect(await scrollTop(page)).toBe(start - 50);
});
